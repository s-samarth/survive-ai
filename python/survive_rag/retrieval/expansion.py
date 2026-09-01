"""Synonym and Hinglish query expansion."""

from __future__ import annotations

from .expansion_terms import EXPANSION_TERMS
from .tokenizer import stem_candidates, tokenize

MAX_EXPANSIONS = 10


def expand(query: str, *, max_expansions: int = MAX_EXPANSIONS) -> list[str]:
    """Return domain terms to add to ``query``, excluding terms already present.

    Each query token is looked up directly and via its stem candidates, so
    ``"bleeding"``, ``"bleeds"`` and ``"bleed"`` all reach the same entry. The
    result is capped because past ~10 added terms the extra recall is bought
    with enough dilution to displace the exact match.

    Args:
        query: Raw user query.
        max_expansions: Hard cap on returned terms.

    Returns:
        Added terms in first-seen order, never containing an original token.
    """
    original = set(tokenize(query))
    added: list[str] = []
    seen = set(original)
    for token in tokenize(query):
        for candidate in stem_candidates(token):
            for term in EXPANSION_TERMS.get(candidate, ()):
                if term not in seen:
                    seen.add(term)
                    added.append(term)
                    if len(added) >= max_expansions:
                        return added
    return added


def expanded_query(query: str, *, max_expansions: int = MAX_EXPANSIONS) -> str:
    """Return ``query`` with its expansion terms appended, space-joined."""
    added = expand(query, max_expansions=max_expansions)
    return " ".join([*tokenize(query), *added])
