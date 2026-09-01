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
from typing import Any


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
    """The full chunked corpus, indexed for O(1) lookup by id."""

    children: list[ChildChunk] = field(default_factory=list)
    parents: list[ParentChunk] = field(default_factory=list)
    _by_child: dict[str, ChildChunk] = field(
        default_factory=dict, init=False, repr=False, compare=False
    )
    _by_parent: dict[str, ParentChunk] = field(
        default_factory=dict, init=False, repr=False, compare=False
    )

    def __post_init__(self) -> None:
        self._by_child = {c.chunk_id: c for c in self.children}
        self._by_parent = {p.parent_id: p for p in self.parents}

    def child(self, chunk_id: str) -> ChildChunk | None:
        """Return the child with ``chunk_id``, or None."""
        return self._by_child.get(chunk_id)

    def parent(self, parent_id: str) -> ParentChunk | None:
        """Return the parent with ``parent_id``, or None."""
        return self._by_parent.get(parent_id)

    def parent_of(self, chunk_id: str) -> ParentChunk | None:
        """Return the parent enclosing ``chunk_id``, or None."""
        child = self.child(chunk_id)
        return self._by_parent.get(child.parent_id) if child else None

    def topics(self) -> list[str]:
        """Return the sorted set of topic keys present in the corpus."""
        return sorted({c.topic for c in self.children})

    def __len__(self) -> int:
        return len(self.children)
