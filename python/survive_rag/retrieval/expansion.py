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


def transliterated_terms(query: str, vocabulary: frozenset[str]) -> list[str]:
    """Query tokens that bridge into the corpus rather than appearing in it.

    A romanised-Hindi token like ``khoon`` is a key in the expansion table but
    occurs nowhere in the English guides; ``bleeding`` is a key *and* occurs.
    That difference identifies transliteration with no extra list to maintain
    and no language-detection model.

    Args:
        query: Raw user query.
        vocabulary: Every term indexed from the corpus.

    Returns:
        The bridging tokens, in query order.
    """
    return [
        token
        for token in tokenize(query)
        if token in EXPANSION_TERMS and token not in vocabulary
    ]


def is_transliterated(query: str, vocabulary: frozenset[str]) -> bool:
    """True when the query leans on romanised-Hindi vocabulary."""
    return bool(transliterated_terms(query, vocabulary))
