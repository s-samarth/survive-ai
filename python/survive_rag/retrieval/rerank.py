"""Heuristic reranking and MMR diversification.

A cross-encoder reranker is the textbook answer and the wrong one here: the
smallest useful ones are 100 MB+ of extra resident model on a 6 GB phone that
is already holding a generator. These features are free, run in microseconds,
and capture most of what a reranker would: does the chunk actually contain the
words the user typed, does its heading match, is it actionable.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache

from ..corpus.models import ChildChunk
from .tokenizer import stem_candidates, tokenize

_ASKING_PERMISSION = re.compile(
    r"\b(should i|can i|is it (ok|safe)|shall i|do i|kya main|safe hai)\b", re.IGNORECASE
)
_IMPERATIVE_HINT = re.compile(r"(^|\n)\s*(?:\d{1,2}[.)]|[-*])\s+\*{0,2}[A-Z]")


@dataclass(frozen=True, slots=True)
class RerankWeights:
    """Feature weights, exposed so the eval harness can sweep them."""

    coverage: float = 1.0
    heading: float = 0.45
    topic_prior: float = 0.35
    prohibition: float = 0.30
    imperative: float = 0.15
    base_rank: float = 0.60


@lru_cache(maxsize=4096)
def _token_set(text: str) -> frozenset[str]:
    """Memoised tokenisation; chunk bodies are re-scored on every query."""
    return frozenset(tokenize(text))


def _coverage(terms: frozenset[str], text: str) -> float:
    """Fraction of query terms (or their stems) present in ``text``."""
    if not terms:
        return 0.0
    haystack = _token_set(text)
    hits = sum(
        1 for t in terms if any(c in haystack for c in stem_candidates(t))
    )
    return hits / len(terms)


def score_chunk(
    chunk: ChildChunk,
    *,
    query: str,
    fused_rank: int,
    topic_hint: str | None,
    weights: RerankWeights,
) -> float:
    """Score one candidate chunk for reranking.

    Args:
        chunk: Candidate child chunk.
        query: The original user query, pre-expansion.
        fused_rank: 1-based rank from RRF; carried forward so the reranker
            refines the fused order rather than discarding it.
        topic_hint: Topic key to prefer, if the caller classified the query.
        weights: Feature weights.

    Returns:
        A relevance score; higher is better.
    """
    terms = _token_set(query)
    score = weights.base_rank / fused_rank
    score += weights.coverage * _coverage(terms, chunk.text)
    score += weights.heading * _coverage(terms, chunk.heading_path)
    if topic_hint and chunk.topic == topic_hint:
        score += weights.topic_prior
    if chunk.is_prohibition and _ASKING_PERMISSION.search(query):
        score += weights.prohibition
    if _IMPERATIVE_HINT.search(chunk.text):
        score += weights.imperative
    return score


def _overlap(a: ChildChunk, b: ChildChunk) -> float:
    """Jaccard term overlap between two chunks, used as an MMR penalty."""
    ta, tb = _token_set(a.text), _token_set(b.text)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


def mmr_select(
    scored: list[tuple[ChildChunk, float]], *, k: int, lambda_: float
) -> list[ChildChunk]:
    """Greedily pick ``k`` chunks trading relevance against redundancy.

    Without this, a query like "snakebite" returns four near-identical
    prohibitions and the model never sees what it *should* do.

    Args:
        scored: Candidates with relevance scores, best first.
        k: Number to select.
        lambda_: Weight on relevance; ``1.0`` disables diversification.

    Returns:
        The selected chunks in selection order.
    """
    if lambda_ >= 1.0:
        return [c for c, _ in scored[:k]]
    pool = list(scored)
    chosen: list[ChildChunk] = []
    while pool and len(chosen) < k:
        best_i, best_val = 0, float("-inf")
        for i, (chunk, rel) in enumerate(pool):
            penalty = max((_overlap(chunk, c) for c in chosen), default=0.0)
            val = lambda_ * rel - (1.0 - lambda_) * penalty
            if val > best_val:
                best_i, best_val = i, val
        chosen.append(pool.pop(best_i)[0])
    return chosen
