"""Stable-identifier guarantees.

Chunk ids are the citation target and the golden-set key, so these properties
are contractual, not incidental.
"""

from __future__ import annotations

import re

from survive_rag.corpus.chunker import chunk_guide
from survive_rag.corpus.models import Corpus
from survive_rag.corpus.slugify import content_sha, make_unique, slugify, split_chunk_id

ID_PATTERN = re.compile(r"^[a-z_]+#[a-z0-9-]+#[a-z0-9-]+$")

GUIDE_A = "# G\n\n## Part 1: Alpha\n\nAlpha paragraph with enough words in it here.\n"
GUIDE_B = (
    "# G\n\n## Part 0: Inserted\n\nSomething new added above the original text.\n\n"
    "## Part 1: Alpha\n\nAlpha paragraph with enough words in it here.\n"
)


def test_ids_are_well_formed(corpus: Corpus) -> None:
    assert all(ID_PATTERN.match(c.chunk_id) for c in corpus.children)


def test_ids_are_unique(corpus: Corpus) -> None:
    ids = [c.chunk_id for c in corpus.children]
    assert len(set(ids)) == len(ids)


def test_ids_are_readable(corpus: Corpus) -> None:
    """A citation must say what it points at, for humans auditing labels."""
    for child in corpus.children:
        slug = child.chunk_id.rsplit("#", 1)[1]
        assert len(slug.split("-")) >= 2 or slug.isalpha()


def test_id_survives_an_edit_elsewhere_in_the_file() -> None:
    """Inserting a section above must not renumber the sections below it."""
    _, before = chunk_guide(GUIDE_A, "g")
    _, after = chunk_guide(GUIDE_B, "g")
    assert before[0].chunk_id in {c.chunk_id for c in after}


def test_content_sha_ignores_whitespace_but_not_words() -> None:
    assert content_sha("a  b\nc") == content_sha("a b c")
    assert content_sha("do not cut") != content_sha("do cut")


def test_duplicate_slugs_are_disambiguated() -> None:
    taken: set[str] = set()
    assert [make_unique("x", taken) for _ in range(3)] == ["x", "x-2", "x-3"]


def test_slugify_drops_markdown_and_leading_filler() -> None:
    assert slugify("**The building is collapsing**") == "building-is-collapsing"
    assert slugify("| a | b |") == "b"


def test_split_chunk_id_round_trips(corpus: Corpus) -> None:
    child = corpus.children[0]
    topic, heading, block = split_chunk_id(child.chunk_id)
    assert topic == child.topic
    assert block is not None
    assert f"{topic}#{heading}" == child.parent_id
