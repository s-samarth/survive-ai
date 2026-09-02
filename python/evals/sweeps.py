"""Named configuration sweeps.

Each sweep answers one question with an A/B, rather than changing several
knobs at once and leaving the result uninterpretable.
"""

from __future__ import annotations

from survive_rag.config import RetrievalConfig
from survive_rag.corpus.chunker import ChunkConfig
from survive_rag.corpus.passages import PassageConfig

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
    """Question: which of the three views should retrieval actually score?

    ``cite_recall_at_5`` is the honest column here -- a coarse unit wins
    span-overlap recall simply by covering more lines, but still has to pick
    the right child to cite.
    """
    return [
        BASELINE.with_(name="child", granularity="child"),
        BASELINE.with_(name="passage"),
        BASELINE.with_(name="parent", granularity="parent"),
        BASELINE.with_(name="passage+parent-terms", index_parent_terms=True),
    ]


def windows() -> list[RetrievalConfig]:
    """Question: how big should a retrieval window be, and does overlap pay?"""
    return [
        BASELINE.with_(
            name=f"w{t}-ov{o}",
            passages=PassageConfig(
                target_tokens=t, max_tokens=int(t * 1.5), overlap_tokens=o
            ),
        )
        for t, o in [(128, 32), (192, 48), (256, 0), (256, 64), (320, 0),
                     (320, 80), (384, 96)]
    ]


def models() -> list[RetrievalConfig]:
    """Question: which embedding model earns its size on this corpus?

    Requires the ``dense`` extra. Each row also reports the parameter cost,
    which matters more than the score on a 6 GB device.
    """
    return [
        BASELINE.with_(name="lexical-only"),
        *[
            BASELINE.with_(name=f"hybrid-{m}", use_dense_leg=True, embed_model=m)
            for m in ("minilm", "bge-small", "e5-small", "e5-base", "embeddinggemma")
        ],
    ]


def routing() -> list[RetrievalConfig]:
    """Question: should romanised-Hindi queries skip the dense leg?

    They should. Embedding models are trained on Devanagari Hindi, not Latin
    transliteration, so the dense leg costs 14 points of Hinglish recall.
    Routing those queries to the lexical legs recovers all of it and costs
    nothing on English.
    """
    return [
        BASELINE.with_(name="lexical-only"),
        BASELINE.with_(name="hybrid", use_dense_leg=True, transliterated_dense_weight=1.0),
        *[
            BASELINE.with_(
                name=f"routed-{w}", use_dense_leg=True, transliterated_dense_weight=w
            )
            for w in (0.0, 0.25, 0.5)
        ],
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
    "windows": windows,
    "models": models,
    "routing": routing,
    "expansion": expansion,
    "headings": headings,
    "all": lambda: [
        BASELINE,
        *legs()[1:],
        *reranking()[1:],
        *chunking()[1:],
        *granularity()[1:],
        *windows(),
        *expansion(),
        *headings(),
    ],
}
