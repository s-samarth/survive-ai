"""The retrieval view: window sizing, overlap, and mapping back to children."""

from __future__ import annotations

from survive_rag.corpus.chunker import chunk_guide
from survive_rag.corpus.models import Corpus
from survive_rag.corpus.passages import PassageConfig, build_passages

GUIDE = """# Test Guide

## Part 1: First Section

Alpha paragraph with enough words to carry some weight in a retrieval index.

- **DO NOT do the dangerous thing.** It causes harm in several ways.
- **DO NOT do the other thing.** This is also harmful and must be avoided.
- **DO NOT do a third thing.** There are many reasons this one is unwise too.
- **DO NOT do a fourth thing.** It has consequences that are hard to reverse.
- **DO NOT do a fifth thing.** This one is the least obvious of all of them.

## Part 2: Second Section

Beta paragraph that belongs to an entirely different section of the guide.
"""


def _chunk(cfg: PassageConfig):
    parents, children = chunk_guide(GUIDE, "test")
    return parents, children, build_passages(parents, children, cfg)


def test_passages_never_straddle_a_parent() -> None:
    """A window must have exactly one section of context to hand the model."""
    _, children, passages = _chunk(PassageConfig(target_tokens=1000))
    for passage in passages:
        owners = {children_by_id(children)[c].parent_id for c in passage.child_ids}
        assert owners == {passage.parent_id}


def children_by_id(children):
    """Index children by id for the assertions above."""
    return {c.chunk_id: c for c in children}


def test_overlap_repeats_children_between_windows() -> None:
    """Consecutive windows share trailing children when overlap is enabled."""
    _, _, overlapped = _chunk(PassageConfig(target_tokens=70, max_tokens=110, overlap_tokens=40))
    _, _, disjoint = _chunk(PassageConfig(target_tokens=70, max_tokens=110, overlap_tokens=0))
    assert sum(len(p.child_ids) for p in overlapped) > sum(len(p.child_ids) for p in disjoint)


def test_zero_overlap_partitions_children_exactly_once() -> None:
    """Without overlap every child appears in exactly one window."""
    _, children, passages = _chunk(PassageConfig(target_tokens=70, overlap_tokens=0))
    seen = [c for p in passages for c in p.child_ids]
    assert sorted(seen) == sorted(c.chunk_id for c in children)


def test_every_child_appears_in_at_least_one_window() -> None:
    """Overlapping windows must still cover the whole section."""
    _, children, passages = _chunk(PassageConfig(target_tokens=70, overlap_tokens=40))
    covered = {c for p in passages for c in p.child_ids}
    assert covered == {c.chunk_id for c in children}


def test_a_window_always_advances() -> None:
    """An overlap wider than the window must not loop forever."""
    _, _, passages = _chunk(PassageConfig(target_tokens=20, max_tokens=25, overlap_tokens=9999))
    assert 0 < len(passages) < 100


def test_passage_is_interchangeable_with_a_child() -> None:
    """Downstream code reads the same attributes on any granularity."""
    _, _, passages = _chunk(PassageConfig())
    passage = passages[0]
    for attribute in ("chunk_id", "text", "topic", "heading_path", "is_prohibition"):
        assert hasattr(passage, attribute)


def test_prohibition_propagates_to_the_window() -> None:
    """A window containing a DO NOT is itself flagged, for the rerank boost."""
    _, _, passages = _chunk(PassageConfig(target_tokens=1000))
    assert any(p.is_prohibition for p in passages)


def test_corpus_resolves_ids_at_every_granularity() -> None:
    """One lookup serves children, passages and parents."""
    parents, children, passages = _chunk(PassageConfig())
    corpus = Corpus(children=children, parents=parents, passages=passages)
    assert corpus.unit(children[0].chunk_id) is children[0]
    assert corpus.unit(passages[0].passage_id) is passages[0]
    assert corpus.unit(parents[0].parent_id) is parents[0]
    assert corpus.unit("no-such-id") is None


def test_citation_maps_a_coarse_unit_back_to_a_child() -> None:
    """A user must land on a paragraph, never on a whole section."""
    parents, children, passages = _chunk(PassageConfig())
    corpus = Corpus(children=children, parents=parents, passages=passages)
    cited = corpus.citation_for(passages[0].passage_id)
    assert cited in {c.chunk_id for c in children}
