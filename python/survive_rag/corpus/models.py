"""Data classes for the parent/child chunked corpus.

The chunker produces a two-level tree per guide:

    Guide (one markdown file, one ``DocTopic``)
      └── ParentChunk   -- one ``## Part N`` section; what the LLM reads
            └── ChildChunk -- one addressable block; what retrieval scores
                              and what a citation points at

Every chunk carries a human-readable stable id so that golden-set entries and
in-app citations survive edits elsewhere in the file.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # pragma: no cover - import cycle guard
    from .passages import Passage

CHILD, PASSAGE, PARENT = "child", "passage", "parent"


@dataclass(frozen=True, slots=True)
class ChildChunk:
    """A single addressable block of guidance -- the unit of retrieval.

    Attributes:
        chunk_id: Stable ``topic#parent_slug#child_slug`` identifier.
        parent_id: Stable id of the enclosing :class:`ParentChunk`.
        topic: Guide key, e.g. ``"bites"``.
        heading_path: Human breadcrumb, e.g. ``"Snakebite > Part 3: What NOT To Do"``.
        text: Verbatim markdown of the block.
        block_kind: ``paragraph`` | ``list`` | ``table`` | ``callout``.
        ordinal: Zero-based position of this child within its parent.
        line_start: 1-based first source line, for deep-linking the reader.
        line_end: 1-based last source line, inclusive.
        content_sha: Short hash of ``text``; detects silent content drift.
        token_estimate: Rough token count used for budgeting.
        is_prohibition: True when the block states something the reader must NOT do.
    """

    chunk_id: str
    parent_id: str
    topic: str
    heading_path: str
    text: str
    block_kind: str
    ordinal: int
    line_start: int
    line_end: int
    content_sha: str
    token_estimate: int
    is_prohibition: bool = False

    def to_json(self) -> dict[str, Any]:
        """Serialise to a plain dict for the shipped index artifact."""
        return {
            "chunk_id": self.chunk_id,
            "parent_id": self.parent_id,
            "topic": self.topic,
            "heading_path": self.heading_path,
            "text": self.text,
            "block_kind": self.block_kind,
            "ordinal": self.ordinal,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "content_sha": self.content_sha,
            "token_estimate": self.token_estimate,
            "is_prohibition": self.is_prohibition,
        }


@dataclass(frozen=True, slots=True)
class ParentChunk:
    """A ``## Part N`` section -- the unit of context handed to the model."""

    parent_id: str
    topic: str
    title: str
    heading_path: str
    text: str
    line_start: int
    line_end: int
    token_estimate: int
    child_ids: tuple[str, ...] = ()
    block_kind: str = "parent"
    is_prohibition: bool = False

    @property
    def chunk_id(self) -> str:
        """Alias so a parent is interchangeable with a child downstream."""
        return self.parent_id

    def to_json(self) -> dict[str, Any]:
        """Serialise to a plain dict for the shipped index artifact."""
        return {
            "parent_id": self.parent_id,
            "topic": self.topic,
            "title": self.title,
            "heading_path": self.heading_path,
            "text": self.text,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "token_estimate": self.token_estimate,
            "child_ids": list(self.child_ids),
        }


@dataclass(slots=True)
class Corpus:
    """The full chunked corpus at three granularities, indexed for lookup.

    ``children`` are citation targets, ``passages`` are the retrieval view
    (see :mod:`survive_rag.corpus.passages`), and ``parents`` are what the
    model reads. Lookup by id works across all three, so the eval can score
    any granularity against the same span-resolved labels.
    """

    children: list[ChildChunk] = field(default_factory=list)
    parents: list[ParentChunk] = field(default_factory=list)
    passages: list[Passage] = field(default_factory=list)
    _by_child: dict[str, ChildChunk] = field(
        default_factory=dict, init=False, repr=False, compare=False
    )
    _by_parent: dict[str, ParentChunk] = field(
        default_factory=dict, init=False, repr=False, compare=False
    )
    _by_passage: dict[str, Passage] = field(
        default_factory=dict, init=False, repr=False, compare=False
    )

    def __post_init__(self) -> None:
        self._by_child = {c.chunk_id: c for c in self.children}
        self._by_parent = {p.parent_id: p for p in self.parents}
        self._by_passage = {p.passage_id: p for p in self.passages}

    def child(self, chunk_id: str) -> ChildChunk | None:
        """Return the child with ``chunk_id``, or None."""
        return self._by_child.get(chunk_id)

    def parent(self, parent_id: str) -> ParentChunk | None:
        """Return the parent with ``parent_id``, or None."""
        return self._by_parent.get(parent_id)

    def passage(self, passage_id: str) -> Passage | None:
        """Return the passage with ``passage_id``, or None."""
        return self._by_passage.get(passage_id)

    def parent_of(self, chunk_id: str) -> ParentChunk | None:
        """Return the parent enclosing any unit id, or None."""
        unit = self.unit(chunk_id)
        pid = getattr(unit, "parent_id", None) if unit else None
        return self._by_parent.get(pid) if pid else None

    def unit(self, unit_id: str) -> ChildChunk | Passage | ParentChunk | None:
        """Look an id up at whichever granularity owns it.

        Ids are disjoint across the three views, so one accessor serves all
        of them and callers never need to know which view produced a result.
        """
        return (
            self._by_child.get(unit_id)
            or self._by_passage.get(unit_id)
            or self._by_parent.get(unit_id)
        )

    def units(self, granularity: str) -> list[ChildChunk | Passage | ParentChunk]:
        """Return every unit at ``granularity``: child, passage, or parent.

        Raises:
            ValueError: If ``granularity`` is not one of the three views.
        """
        if granularity == CHILD:
            return list(self.children)
        if granularity == PASSAGE:
            return list(self.passages) if self.passages else list(self.children)
        if granularity == PARENT:
            return list(self.parents)
        raise ValueError(f"unknown granularity {granularity!r}")

    def citation_for(self, unit_id: str) -> str | None:
        """Map any retrieved unit back to the child a citation should link to.

        A passage cites its first child and a parent cites its first child,
        because the user must land on a paragraph, never on a whole section.
        """
        if unit_id in self._by_child:
            return unit_id
        unit = self.unit(unit_id)
        kids = getattr(unit, "child_ids", ()) if unit else ()
        return kids[0] if kids else None

    def topics(self) -> list[str]:
        """Every topic key present in the corpus, sorted."""
        return sorted({c.topic for c in self.children})

    def __len__(self) -> int:
        """Number of children -- the corpus size quoted in reports."""
        return len(self.children)
