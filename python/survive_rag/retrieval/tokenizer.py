"""Query and document tokenisation.

Deliberately simple and dependency-free so it can be reimplemented verbatim in
Dart: normalise, drop stopwords, and apply a light suffix stemmer that yields
*candidates* rather than a single stem. Yielding candidates matters because
``"collapsing"`` must reach ``"collapse"``, which naive ``-ing`` stripping
misses entirely.
"""

from __future__ import annotations

import re
import unicodedata

_NON_WORD = re.compile(r"[^a-z0-9]+")

STOPWORDS: frozenset[str] = frozenset({
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could",
    "did", "do", "does", "doing", "done", "for", "from", "had", "has", "have", "he",
    "her", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its",
    "me", "my", "no", "nor", "not", "of", "on", "or", "our", "ours", "out", "over",
    "should", "so", "some", "such", "than", "that", "the", "their", "them", "then",
    "there", "these", "they", "this", "those", "through", "to", "too", "under", "up",
    "very", "was", "we", "were", "what", "when", "where", "which", "while", "who",
    "whom", "why", "will", "with", "would", "you", "your", "yours"
})

# (suffix, minimum word length, characters to strip). Ordered: the first
# matching rule wins, so "-ing" is tried before the bare "-s".
_SUFFIX_RULES: tuple[tuple[str, int, int], ...] = (
    ("ing", 6, 3),
    ("ed", 5, 2),
    ("ly", 5, 2),
    ("es", 5, 2),
    ("s", 4, 1),
)


def normalise(text: str) -> str:
    """Lowercase, strip accents, and collapse punctuation to single spaces."""
    decomposed = unicodedata.normalize("NFKD", text.lower())
    ascii_only = "".join(c for c in decomposed if not unicodedata.combining(c))
    return _NON_WORD.sub(" ", ascii_only).strip()


def stem_candidates(word: str) -> list[str]:
    """Return the word plus plausible stems, longest-first.

    Args:
        word: A single normalised token.

    Returns:
        ``[word]`` plus any derived stems; never empty.
    """
    out = [word]
    base: str | None = None
    for suffix, min_len, strip in _SUFFIX_RULES:
        if len(word) >= min_len and word.endswith(suffix):
            if suffix == "s" and word.endswith("ss"):
                break
            base = word[:-strip]
            break
    if base and base != word:
        out.append(base)
        if not base.endswith("e"):
            out.append(base + "e")
    return out


def tokenize(text: str, *, keep_stopwords: bool = False) -> list[str]:
    """Split text into indexable terms.

    Args:
        text: Raw query or document text.
        keep_stopwords: Retain stopwords instead of dropping them.

    Returns:
        Normalised tokens of length >= 2, stopwords removed by default.
    """
    words = normalise(text).split()
    return [
        w
        for w in words
        if len(w) > 1 and (keep_stopwords or w not in STOPWORDS)
    ]


def index_terms(text: str) -> list[str]:
    """Tokenise and expand each token to its stem candidates, for indexing.

    Indexing the stems alongside the surface form means a query for
    ``"collapse"`` matches a document that only ever says ``"collapsing"``,
    without needing a full Porter implementation on either side.
    """
    out: list[str] = []
    for token in tokenize(text):
        out.extend(stem_candidates(token))
    return out
