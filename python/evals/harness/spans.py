"""Chunking-independent label resolution.

A golden-set label names a chunk id, because that is what a human can read and
audit. But chunk ids are a function of the chunking policy, so a set labelled
under one policy cannot score another -- which would make the single most
interesting sweep (does chunking matter?) impossible to run.

The fix: resolve each label once, against a **reference** corpus, down to the
markdown source lines it covers. Matching afterwards is by line overlap, so
any chunking policy *and any granularity* can be scored against the same
labels -- a passage that contains the gold child is credited for it. Under the
reference policy at child granularity this reduces exactly to id equality.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import NamedTuple

from survive_rag.corpus.models import Corpus

from .goldset import GOLD_RELEVANCE, PARTIAL_RELEVANCE, GoldCase, GoldSet

# A retrieved chunk covers a gold span when it contains at least this much of
# it, or when it lies almost entirely inside it (a finer policy splitting one
# gold chunk into three should still be credited).
COVERAGE_OF_GOLD = 0.5
CONTAINED_IN_GOLD = 0.9


class Span(NamedTuple):
    """A half-open-free, inclusive line range within one guide."""

    topic: str
    start: int
    end: int

    @property
    def length(self) -> int:
        """Number of source lines covered."""
        return self.end - self.start + 1

    def overlap(self, other: Span) -> int:
        """Lines shared with ``other``; zero across different topics."""
        if self.topic != other.topic:
            return 0
        return max(0, min(self.end, other.end) - max(self.start, other.start) + 1)


def _spans_for(chunk_ids: tuple[str, ...], corpus: Corpus) -> tuple[Span, ...]:
    """Resolve chunk ids to source spans, skipping ids not in ``corpus``."""
    out = []
    for chunk_id in chunk_ids:
        chunk = corpus.unit(chunk_id)
        if chunk is not None:
            out.append(Span(chunk.topic, chunk.line_start, chunk.line_end))
    return tuple(out)


@dataclass(frozen=True, slots=True)
class CaseMatcher:
    """Scores retrieved chunk ids against one case's resolved spans."""

    case: GoldCase
    gold_spans: tuple[Span, ...]
    partial_spans: tuple[Span, ...]
    corpus: Corpus

    @property
    def n_gold(self) -> int:
        """How many distinct gold spans this case expects."""
        return len(self.gold_spans)

    def _span_of(self, chunk_id: str) -> Span | None:
        """Source span of a retrieved chunk, or None if it is unknown."""
        chunk = self.corpus.unit(chunk_id)
        if chunk is None:
            return None
        return Span(chunk.topic, chunk.line_start, chunk.line_end)

    @staticmethod
    def _covers(retrieved: Span, target: Span) -> bool:
        """True when ``retrieved`` should be credited for ``target``."""
        shared = retrieved.overlap(target)
        if not shared:
            return False
        return (
            shared >= COVERAGE_OF_GOLD * target.length
            or shared >= CONTAINED_IN_GOLD * retrieved.length
        )

    def relevance(self, chunk_id: str) -> int:
        """Graded relevance of one retrieved chunk: 2, 1, or 0."""
        span = self._span_of(chunk_id)
        if span is None:
            return 0
        if any(self._covers(span, g) for g in self.gold_spans):
            return GOLD_RELEVANCE
        if any(self._covers(span, p) for p in self.partial_spans):
            return PARTIAL_RELEVANCE
        return 0

    def gold_found(self, ranked: list[str], k: int) -> int:
        """Number of distinct gold spans covered within the top ``k``."""
        spans = [s for s in (self._span_of(c) for c in ranked[:k]) if s]
        return sum(1 for g in self.gold_spans if any(self._covers(s, g) for s in spans))

    def first_gold_rank(self, ranked: list[str]) -> int | None:
        """1-based rank of the first chunk covering any gold span."""
        for rank, chunk_id in enumerate(ranked, start=1):
            span = self._span_of(chunk_id)
            if span and any(self._covers(span, g) for g in self.gold_spans):
                return rank
        return None


def resolve(
    goldset: GoldSet, reference: Corpus, evaluated: Corpus | None = None
) -> list[CaseMatcher]:
    """Bind every case to its source spans and the corpus being scored.

    Args:
        goldset: The loaded golden set.
        reference: Corpus the labels were authored against; supplies the spans.
        evaluated: Corpus actually being retrieved from. Defaults to
            ``reference``, which is the ordinary case.

    Returns:
        One :class:`CaseMatcher` per case, in golden-set order.
    """
    target = evaluated or reference
    return [
        CaseMatcher(
            case=case,
            gold_spans=_spans_for(case.gold, reference),
            partial_spans=_spans_for(case.also_relevant, reference),
            corpus=target,
        )
        for case in goldset.cases
    ]


def unresolved(matchers: list[CaseMatcher]) -> list[GoldCase]:
    """Cases whose gold labels resolved to nothing -- i.e. stale labels."""
    return [m.case for m in matchers if not m.case.is_out_of_corpus and not m.gold_spans]
