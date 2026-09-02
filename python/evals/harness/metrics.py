"""Retrieval metrics, computed through a chunking-independent matcher.

Recall@5 is the headline number and everything else is diagnostic. The reason
is structural: if the chunk that answers the question is not in what we send,
no generator -- however good, however large -- can produce a correct grounded
answer. Every other quality problem is recoverable; a retrieval miss is not.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .spans import CaseMatcher


def recall_at_k(ranked: list[str], matcher: CaseMatcher, k: int) -> float:
    """Fraction of gold spans covered by the top ``k`` results."""
    if not matcher.n_gold:
        return 1.0
    return matcher.gold_found(ranked, k) / matcher.n_gold


def hit_at_k(ranked: list[str], matcher: CaseMatcher, k: int) -> float:
    """1.0 if any gold span is covered in the top ``k``, else 0.0."""
    if not matcher.n_gold:
        return 1.0
    return 1.0 if matcher.gold_found(ranked, k) else 0.0


def precision_at_k(ranked: list[str], matcher: CaseMatcher, k: int) -> float:
    """Fraction of the top ``k`` results that are gold or partially relevant."""
    top = ranked[:k]
    if not top:
        return 0.0
    return sum(1 for c in top if matcher.relevance(c) > 0) / len(top)


def reciprocal_rank(ranked: list[str], matcher: CaseMatcher) -> float:
    """1/rank of the first gold result, or 0.0 if none was retrieved."""
    rank = matcher.first_gold_rank(ranked)
    return 1.0 / rank if rank else 0.0


def ndcg_at_k(ranked: list[str], matcher: CaseMatcher, k: int) -> float:
    """Normalised discounted cumulative gain over graded relevance.

    nDCG tracks end-to-end answer quality most closely, because it rewards
    putting the *best* chunk first rather than merely somewhere in the window.
    """
    gains = [matcher.relevance(c) for c in ranked[:k]]
    dcg = sum(g / math.log2(i + 2) for i, g in enumerate(gains) if g)
    ideal = sorted(
        [2] * len(matcher.gold_spans) + [1] * len(matcher.partial_spans), reverse=True
    )[:k]
    idcg = sum(g / math.log2(i + 2) for i, g in enumerate(ideal) if g)
    return dcg / idcg if idcg else 0.0


def topic_hit(ranked: list[str], matcher: CaseMatcher) -> float:
    """1.0 if the top result comes from the expected guide."""
    topic = matcher.case.topic
    if not topic or not ranked:
        return 0.0
    return 1.0 if ranked[0].split("#", 1)[0] == topic else 0.0


@dataclass(frozen=True, slots=True)
class CaseResult:
    """Per-case metric values, retained so the report can list the failures."""

    case_id: str
    query: str
    slices: tuple[str, ...]
    ranked: tuple[str, ...]
    recall_at_5: float
    recall_at_20: float
    hit_at_1: float
    hit_at_5: float
    precision_at_5: float
    mrr: float
    ndcg_at_5: float
    topic_hit: float
    cite_recall_at_5: float = 0.0
    cite_mrr: float = 0.0

    @property
    def failed(self) -> bool:
        """True when no gold chunk reached the top 5 -- the generator's floor."""
        return self.recall_at_5 == 0.0


def evaluate_case(
    ranked: list[str], matcher: CaseMatcher, cited: list[str] | None = None
) -> CaseResult:
    """Compute every metric for one case.

    Args:
        ranked: Retrieved unit ids, best first -- what the model reads.
        matcher: The case bound to its resolved gold spans.
        cited: Child ids the results cite, best first. Defaults to ``ranked``,
            which is correct when retrieval already runs at child granularity.

    Returns:
        A populated :class:`CaseResult`.
    """
    case = matcher.case
    cited = ranked if cited is None else cited
    return CaseResult(
        case_id=case.case_id,
        query=case.query,
        slices=case.slices,
        ranked=tuple(ranked[:20]),
        recall_at_5=recall_at_k(ranked, matcher, 5),
        recall_at_20=recall_at_k(ranked, matcher, 20),
        hit_at_1=hit_at_k(ranked, matcher, 1),
        hit_at_5=hit_at_k(ranked, matcher, 5),
        precision_at_5=precision_at_k(ranked, matcher, 5),
        mrr=reciprocal_rank(ranked, matcher),
        ndcg_at_5=ndcg_at_k(ranked, matcher, 5),
        topic_hit=topic_hit(ranked, matcher),
        cite_recall_at_5=recall_at_k(cited, matcher, 5),
        cite_mrr=reciprocal_rank(cited, matcher),
    )


METRIC_FIELDS: tuple[str, ...] = (
    "recall_at_5",
    "recall_at_20",
    "hit_at_1",
    "hit_at_5",
    "precision_at_5",
    "mrr",
    "ndcg_at_5",
    "topic_hit",
    "cite_recall_at_5",
    "cite_mrr",
)


def aggregate(results: list[CaseResult]) -> dict[str, float]:
    """Mean each metric across ``results``; empty input yields all zeros."""
    if not results:
        return {name: 0.0 for name in METRIC_FIELDS}
    return {
        name: sum(getattr(r, name) for r in results) / len(results)
        for name in METRIC_FIELDS
    }
