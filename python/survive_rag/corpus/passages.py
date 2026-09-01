"""The retrieval view: overlapping windows of children.

The corpus is chunked once but read at three different granularities, because
three different consumers want three different sizes:

    * **child**   -- what a citation points at. Small and sharp, ~90 tokens,
      because the user is scrolled to it and must recognise the answer.
    * **passage** -- what retrieval scores. Built here.
    * **parent**  -- what the model reads. A whole ``## Part N`` section.

Scoring at citation granularity was a mistake: a 30-token prohibition holds
too few terms for BM25 to match and too little meaning for an embedding to
place well. A passage is a sliding window of consecutive children inside one
parent, so it is big enough to retrieve and still maps back to exact children
for the citation and to the parent for generation.

Windows **overlap**. Without overlap a concept split across a boundary is half
represented in two neighbours and fully represented in neither -- which costs
little for BM25 (a term is present or it is not) and a lot for embeddings.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .models import ChildChunk, ParentChunk
from .slugify import content_sha

PASSAGE_SEP = "::"


@dataclass(frozen=True, slots=True)
class PassageConfig:
    """Window sizing for the retrieval view; every field is an eval knob.

    Attributes:
        target_tokens: Stop growing a window once it reaches this size.
        max_tokens: Never exceed this by adding a further child.
        overlap_tokens: Roughly this many tokens are repeated between
            consecutive windows. Zero disables overlap.
        enabled: When False the retrieval view is the child view unchanged.
    """

    target_tokens: int = 256
    max_tokens: int = 384
    overlap_tokens: int = 64
    enabled: bool = True


@dataclass(frozen=True, slots=True)
class Passage:
    """One retrieval unit: consecutive children of a single parent."""

    passage_id: str
    parent_id: str
    topic: str
    heading_path: str
    text: str
    child_ids: tuple[str, ...]
    line_start: int
    line_end: int
    token_estimate: int
    content_sha: str
    block_kind: str = "passage"
    is_prohibition: bool = False

    @property
    def chunk_id(self) -> str:
        """Alias so a passage is interchangeable with a child downstream."""
        return self.passage_id

    @property
    def head_child_id(self) -> str:
        """The child a citation defaults to when this passage is the hit."""
        return self.child_ids[0]

    def to_json(self) -> dict[str, Any]:
        """Serialise to a plain dict for the shipped index artifact."""
        return {
            "passage_id": self.passage_id,
            "parent_id": self.parent_id,
            "topic": self.topic,
            "heading_path": self.heading_path,
            "text": self.text,
            "child_ids": list(self.child_ids),
            "line_start": self.line_start,
            "line_end": self.line_end,
            "token_estimate": self.token_estimate,
            "content_sha": self.content_sha,
        }


def _window_from(
    kids: list[ChildChunk], start: int, cfg: PassageConfig
) -> tuple[list[ChildChunk], int]:
    """Grow a window from ``start``, returning it and the index after it.

    A window always contains at least one child, even when that child alone
    exceeds ``max_tokens`` -- dropping content is never the right answer.
    """
    window: list[ChildChunk] = []
    tokens = 0
    cursor = start
    while cursor < len(kids):
        child = kids[cursor]
        if window and tokens + child.token_estimate > cfg.max_tokens:
            break
        window.append(child)
        tokens += child.token_estimate
        cursor += 1
        if tokens >= cfg.target_tokens:
            break
    return window, cursor


def _step_back(window: list[ChildChunk], cfg: PassageConfig) -> int:
    """How many trailing children of ``window`` the next window repeats."""
    if cfg.overlap_tokens <= 0 or len(window) < 2:
        return 0
    repeated = 0
    tokens = 0
    for child in reversed(window[:-1] if len(window) > 1 else window):
        if tokens + child.token_estimate > cfg.overlap_tokens:
            break
        tokens += child.token_estimate
        repeated += 1
    return min(repeated, len(window) - 1)


def _passage(
    window: list[ChildChunk], parent: ParentChunk, ordinal: int
) -> Passage:
    """Materialise one :class:`Passage` from a window of children."""
    text = "\n".join(c.text for c in window).strip()
    return Passage(
        passage_id=f"{parent.parent_id}{PASSAGE_SEP}w{ordinal}",
        parent_id=parent.parent_id,
        topic=parent.topic,
        heading_path=parent.heading_path,
        text=text,
        child_ids=tuple(c.chunk_id for c in window),
        line_start=window[0].line_start,
        line_end=window[-1].line_end,
        token_estimate=sum(c.token_estimate for c in window),
        content_sha=content_sha(text),
        is_prohibition=any(c.is_prohibition for c in window),
    )


def build_passages(
    parents: list[ParentChunk],
    children: list[ChildChunk],
    cfg: PassageConfig | None = None,
) -> list[Passage]:
    """Build the overlapping retrieval view over an already-chunked corpus.

    Windows never straddle a parent, so a passage always has exactly one
    section of context to hand the model.

    Args:
        parents: Parent sections, in document order.
        children: Child chunks, in document order.
        cfg: Window sizing; defaults to :class:`PassageConfig`.

    Returns:
        Passages in document order.
    """
    cfg = cfg or PassageConfig()
    by_parent: dict[str, list[ChildChunk]] = {}
    for child in children:
        by_parent.setdefault(child.parent_id, []).append(child)

    out: list[Passage] = []
    for parent in parents:
        kids = by_parent.get(parent.parent_id, [])
        if not kids:
            continue
        start = 0
        ordinal = 0
        while start < len(kids):
            window, cursor = _window_from(kids, start, cfg)
            out.append(_passage(window, parent, ordinal))
            ordinal += 1
            if cursor >= len(kids):
                break
            # Always advance, or an overlap wider than a window would loop.
            start = max(start + 1, cursor - _step_back(window, cfg))
    return out
