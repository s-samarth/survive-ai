"""Corpus-wide invariants, including parity with the Dart side."""

from __future__ import annotations

import re
from pathlib import Path

from survive_rag.corpus.loader import guides_dir
from survive_rag.corpus.models import Corpus
from survive_rag.corpus.topics import TOPIC_KEYS

# Parents are what the model reads. This is the per-section ceiling that keeps
# a handful of them inside the 1452-token prompt budget in llm_service.dart.
PARENT_TOKEN_CEILING = 1000


def test_every_topic_has_a_guide(root: Path) -> None:
    for key in TOPIC_KEYS:
        path = guides_dir(root) / f"{key}.md"
        assert path.is_file(), f"missing guide: {path}"
        assert len(path.read_text(encoding="utf-8")) > 2000


def test_python_topics_match_the_dart_enum(root: Path) -> None:
    """Divergent topic keys silently break every topic filter in the app."""
    dart = (root / "lib" / "models" / "doc_topic.dart").read_text(encoding="utf-8")
    found = set(re.findall(r"=> '([a-z_]+)'", dart))
    assert set(TOPIC_KEYS) <= found, set(TOPIC_KEYS) - found


def test_all_topics_are_chunked(corpus: Corpus) -> None:
    assert corpus.topics() == sorted(TOPIC_KEYS)


def test_no_child_is_empty(corpus: Corpus) -> None:
    assert all(c.text.strip() for c in corpus.children)


def test_parents_stay_within_the_prompt_budget(corpus: Corpus) -> None:
    oversized = [p.parent_id for p in corpus.parents if p.token_estimate > PARENT_TOKEN_CEILING]
    assert not oversized, f"sections too large to send whole: {oversized}"


def test_children_resolve_to_their_parent(corpus: Corpus) -> None:
    for child in corpus.children:
        parent = corpus.parent_of(child.chunk_id)
        assert parent is not None
        assert child.chunk_id in parent.child_ids


def test_child_spans_lie_inside_their_parent_span(corpus: Corpus) -> None:
    for child in corpus.children:
        parent = corpus.parent_of(child.chunk_id)
        assert parent is not None
        assert parent.line_start <= child.line_start <= child.line_end <= parent.line_end


def test_prohibitions_are_well_represented(corpus: Corpus) -> None:
    """The corpus is heavy on 'do not'; if this collapses, the flag broke."""
    assert sum(1 for c in corpus.children if c.is_prohibition) > 100
