"""Building the individual retrieval legs, before anything fuses them.

Each leg is an independent opinion about which units answer the query, and the
three disagree in useful ways: literal BM25 is precise and brittle, expanded
BM25 bridges vocabulary the corpus does not share with the user, and the dense
leg understands paraphrase but not romanised Hindi.

That last one is why the dense leg can be routed out entirely rather than
merely down-weighted. Measured on the Hinglish slice, the lexical legs alone
score 60.7% Recall@5 and every embedding model 28-46%, because they are trained
on Devanagari and rate "saanp" barely above noise. A partial weight still
poisons the ranking, so the routing is binary.
"""

from __future__ import annotations

from typing import Any

from ..config import RetrievalConfig
from .expansion import expand, is_transliterated
from .tokenizer import stem_candidates, tokenize


def run_legs(
    query: str,
    *,
    cfg: RetrievalConfig,
    index: Any,
    dense: Any,
    vocabulary: frozenset[str],
) -> tuple[list[list[str]], list[float]]:
    """Run the enabled retrieval legs.

    Args:
        query: The user's query.
        cfg: Retrieval configuration; decides which legs run and their weights.
        index: BM25 index over the retrieval units.
        dense: Dense index, or None when the dense leg is disabled.
        vocabulary: Every term indexed from the corpus, for bridge-word
            detection.

    Returns:
        ``(rankings, weights)``, one entry per leg that produced results.
    """
    rankings: list[list[str]] = []
    weights: list[float] = []

    literal = tokenize(query)
    if cfg.use_literal_leg and literal:
        hits = index.search(
            [t for w in literal for t in stem_candidates(w)], limit=cfg.leg_limit
        )
        rankings.append([doc for doc, _ in hits])
        weights.append(cfg.literal_weight)

    if cfg.use_expanded_leg:
        added = expand(query, max_expansions=cfg.max_expansions)
        if added:
            terms = [t for w in literal + added for t in stem_candidates(w)]
            hits = index.search(terms, limit=cfg.leg_limit)
            rankings.append([doc for doc, _ in hits])
            weights.append(cfg.expanded_weight)

    if dense is not None:
        hits = dense.search(query, limit=cfg.leg_limit)
        weight = cfg.dense_weight
        if is_transliterated(query, vocabulary):
            weight *= cfg.transliterated_dense_weight
        if weight > 0:
            rankings.append([doc for doc, _ in hits])
            weights.append(weight)

    return rankings, weights
