"""Stable, human-readable identifier construction.

Chunk ids are built from *content*, not position, so that inserting a
paragraph at the top of a guide does not renumber every citation below it::

    bites#part-3-snakebite-what-not-to-do#do-not-apply-a-tourniquet

Readability is deliberate: these ids appear in the hand-authored golden set,
in eval reports, and in user-facing citation links, and all three are far
easier to audit when the id says what it points at.
"""

from __future__ import annotations

import hashlib
import re

_MARKDOWN_NOISE = re.compile(r"[*_`>#\[\]()|]")
_NON_SLUG = re.compile(r"[^a-z0-9]+")

# Dropped only when they are *leading* filler; kept mid-slug so that
# "what-not-to-do" and "do-not-apply" stay legible and distinct.
_LEADING_FILLER = frozenset({"the", "a", "an", "and", "of", "in", "on", "to", "is"})

_SLUG_WORDS = 7
_SLUG_MAXLEN = 60


def slugify(text: str, *, max_words: int = _SLUG_WORDS) -> str:
    """Reduce arbitrary markdown text to a short lowercase hyphenated slug.

    Args:
        text: Raw text, possibly containing markdown emphasis and punctuation.
        max_words: Maximum number of words to keep.

    Returns:
        A slug of at most ``max_words`` words, or ``"block"`` if nothing survives.
    """
    cleaned = _MARKDOWN_NOISE.sub(" ", text)
    words = [w for w in _NON_SLUG.sub(" ", cleaned.lower()).split() if w]
    while words and words[0] in _LEADING_FILLER:
        words.pop(0)
    if not words:
        return "block"
    slug = "-".join(words[:max_words])[:_SLUG_MAXLEN].strip("-")
    return slug or "block"


def content_sha(text: str, *, length: int = 10) -> str:
    """Return a short stable hash of ``text`` for drift detection.

    Args:
        text: Chunk body.
        length: Number of hex characters to keep.

    Returns:
        The first ``length`` hex characters of the SHA-256 of the
        whitespace-normalised text.
    """
    normalised = " ".join(text.split())
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()[:length]


def make_unique(slug: str, taken: set[str]) -> str:
    """Disambiguate ``slug`` against ids already issued in the same scope.

    Two blocks in one section can legitimately start with the same words
    (``"do not"`` bullets are the common case). The first keeps the bare slug;
    later ones get a numeric suffix.

    Args:
        slug: Candidate slug.
        taken: Slugs already issued within the same parent; mutated in place.

    Returns:
        A slug not present in ``taken``.
    """
    if slug not in taken:
        taken.add(slug)
        return slug
    n = 2
    while f"{slug}-{n}" in taken:
        n += 1
    unique = f"{slug}-{n}"
    taken.add(unique)
    return unique


def parent_id(topic: str, heading_slug: str) -> str:
    """Build a parent chunk id from its topic and heading slug."""
    return f"{topic}#{heading_slug}"


def child_id(topic: str, heading_slug: str, block_slug: str) -> str:
    """Build a child chunk id from its topic, heading slug and block slug."""
    return f"{topic}#{heading_slug}#{block_slug}"


def split_chunk_id(chunk_id: str) -> tuple[str, str, str | None]:
    """Split a chunk id into ``(topic, heading_slug, block_slug)``.

    Args:
        chunk_id: A parent or child chunk id.

    Returns:
        A 3-tuple; ``block_slug`` is None for parent ids.

    Raises:
        ValueError: If ``chunk_id`` has neither two nor three segments.
    """
    parts = chunk_id.split("#")
    if len(parts) == 2:
        return parts[0], parts[1], None
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]
    raise ValueError(f"malformed chunk id: {chunk_id!r}")
