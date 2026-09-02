"""Turning ranked units into results the caller can use.

A retrieved unit is not yet an answer. It has to carry three things:

    * the **context** the model reads -- the enclosing ``## Part N`` section,
      so no step arrives without the steps around it, subject to a token
      budget that falls back to the unit's own text rather than overflowing;
    * the **citation** the user clicks, which is always a child;
    * the rank and score, so a report can explain why it was chosen.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from ..corpus.models import Corpus, ParentChunk
from .citations import CitationPicker


@dataclass(frozen=True, slots=True)
class RetrievedChunk:
    """One result: the matched unit plus the context handed to the model."""

    unit: Any
    rank: int
    score: float
    context: str
    citation: str
    parent: ParentChunk | None = None

    @property
    def unit_id(self) -> str:
        """Id of the retrieved unit, at whatever granularity was scored."""
        return self.unit.chunk_id


def materialise(
    units: list,
    scores: list[float],
    query: str,
    *,
    corpus: Corpus,
    config: Any,
    picker: CitationPicker,
) -> list[RetrievedChunk]:
    """Attach parent context, a token-budget fallback, and a citation.

    Args:
        units: Selected units, best first.
        scores: Their scores, in the same order.
        query: The original query, used to choose each citation.
        corpus: The chunked corpus.
        config: A :class:`~survive_rag.config.RetrievalConfig`.
        picker: Maps each unit back to the child it should cite.

    Returns:
        One :class:`RetrievedChunk` per unit.
    """
    out: list[RetrievedChunk] = []
    for i, (unit, score) in enumerate(zip(units, scores, strict=True), start=1):
        parent = corpus.parent_of(unit.chunk_id)
        fits = (
            config.expand_to_parents
            and parent is not None
            and parent.token_estimate <= config.max_parent_tokens
        )
        out.append(
            RetrievedChunk(
                unit=unit,
                rank=i,
                score=score,
                context=parent.text if fits and parent else unit.text,
                citation=picker.for_unit(unit, query),
                parent=parent,
            )
        )
    return out
