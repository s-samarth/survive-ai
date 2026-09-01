"""Named configuration sweeps.

Each sweep answers one question with an A/B, rather than changing several
knobs at once and leaving the result uninterpretable.
"""

from __future__ import annotations

from .config import RetrievalConfig
from .corpus.chunker import ChunkConfig

BASELINE = RetrievalConfig(name="baseline")


def legs() -> list[RetrievalConfig]:
    """Question: what does each retrieval leg actually contribute?"""
    return [
        BASELINE,
        BASELINE.with_(name="literal-only", use_expanded_leg=False),
        BASELINE.with_(name="expanded-only", use_literal_leg=False),
    ]


def reranking() -> list[RetrievalConfig]:
    """Question: is the heuristic reranker earning its place?"""
    return [
        BASELINE,
        BASELINE.with_(name="no-rerank", rerank=False),
        BASELINE.with_(name="no-mmr", mmr_lambda=1.0),
        BASELINE.with_(name="deep-rerank", rerank_depth=50),
    ]


def chunking() -> list[RetrievalConfig]:
    """Question: does the parent/child sizing policy matter, and how much?

    ``coarse`` approximates the app's original flat chunker: no list
    explosion, no anchor flush, one big block per heading.
    """
    return [
        BASELINE,
        BASELINE.with_(
            name="coarse",
            chunking=ChunkConfig(
                min_tokens=200, target_tokens=300, max_tokens=400,
                explode_lists=False, anchor_flush=False,
            ),
        ),
        BASELINE.with_(
            name="fine",
            chunking=ChunkConfig(min_tokens=20, target_tokens=80, max_tokens=140),
        ),
        BASELINE.with_(
            name="no-anchors",
            chunking=ChunkConfig(anchor_flush=False),
        ),
    ]


def granularity() -> list[RetrievalConfig]:
    """Question: can a child chunk borrow its parent's vocabulary and keep
    small-chunk citation precision while matching coarse-chunk recall?"""
    return [
        BASELINE,
        BASELINE.with_(name="parent-terms", index_parent_terms=True),
        BASELINE.with_(
            name="parent-terms-h1", index_parent_terms=True, heading_boost=1
        ),
        BASELINE.with_(
            name="coarse",
            chunking=ChunkConfig(
                min_tokens=200, target_tokens=300, max_tokens=400,
                explode_lists=False, anchor_flush=False,
            ),
        ),
    ]


def expansion() -> list[RetrievalConfig]:
    """Question: where is the sweet spot for query expansion breadth?"""
    return [
        BASELINE.with_(name=f"expand-{n}", max_expansions=n)
        for n in (0, 4, 10, 20)
    ]


def headings() -> list[RetrievalConfig]:
    """Question: how much should a heading match count?"""
    return [
        BASELINE.with_(name=f"heading-x{n}", heading_boost=n) for n in (0, 1, 2, 4)
    ]


SWEEPS: dict[str, callable] = {
    "legs": legs,
    "rerank": reranking,
    "chunking": chunking,
    "granularity": granularity,
    "expansion": expansion,
    "headings": headings,
    "all": lambda: [
        BASELINE,
        *legs()[1:],
        *reranking()[1:],
        *chunking()[1:],
        *granularity()[1:-1],
        *expansion(),
        *headings(),
    ],
}
