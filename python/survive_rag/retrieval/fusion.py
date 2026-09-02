"""Reciprocal Rank Fusion for combining heterogeneous retrieval legs.

RRF is used rather than score normalisation because BM25 scores from different
legs are not commensurable -- an exact-match leg and a synonym-expanded leg
produce different score scales for the same query. RRF discards magnitudes and
keeps only ranks, which is why it needs no per-corpus tuning.
"""

from __future__ import annotations

RRF_K = 60


def reciprocal_rank_fusion(
    rankings: list[list[str]],
    *,
    k: int = RRF_K,
    weights: list[float] | None = None,
) -> list[tuple[str, float]]:
    """Fuse several ranked id lists into one.

    Each list contributes ``weight / (k + rank)`` to every document it ranks,
    with ``rank`` 1-based. The constant ``k`` damps the influence of the very
    top positions so that a document ranked well by two legs beats a document
    ranked first by one.

    Args:
        rankings: One ranked list of document ids per retrieval leg.
        k: Damping constant; 60 is the value from the original RRF paper.
        weights: Optional per-leg weights, defaulting to 1.0 each.

    Returns:
        ``(doc_id, fused_score)`` sorted best first, ties broken by id.

    Raises:
        ValueError: If ``weights`` is given and its length differs from
            ``rankings``.
    """
    if weights is not None and len(weights) != len(rankings):
        raise ValueError("weights must have one entry per ranking")
    weights = weights or [1.0] * len(rankings)

    fused: dict[str, float] = {}
    for ranking, weight in zip(rankings, weights, strict=True):
        for rank, doc_id in enumerate(ranking, start=1):
            fused[doc_id] = fused.get(doc_id, 0.0) + weight / (k + rank)
    return sorted(fused.items(), key=lambda kv: (-kv[1], kv[0]))
