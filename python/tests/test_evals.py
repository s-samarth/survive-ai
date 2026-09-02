"""Golden-set integrity and metric correctness.

The integrity tests are the ones that matter day to day: they fail the moment
a guide is edited in a way that invalidates a hand-authored label, which is
the failure mode that would otherwise silently depress every score.
"""

from __future__ import annotations

from collections import Counter

import pytest

from evals.harness.goldset import GoldCase, GoldSet, validate
from evals.harness.metrics import evaluate_case, ndcg_at_k, recall_at_k
from evals.harness.spans import CaseMatcher, Span, resolve, unresolved
from survive_rag.corpus.chunker import ChunkConfig
from survive_rag.corpus.loader import load_corpus
from survive_rag.corpus.models import Corpus

MIN_CASES = 250
MIN_PER_SLICE = 3


# --------------------------------------------------------------- golden set

def test_every_label_exists_in_the_corpus(goldset: GoldSet, corpus: Corpus) -> None:
    assert validate(goldset, corpus) == []


def test_every_label_resolves_to_a_source_span(goldset: GoldSet, corpus: Corpus) -> None:
    assert unresolved(resolve(goldset, corpus)) == []


def test_golden_set_is_large_enough(goldset: GoldSet) -> None:
    assert len(goldset) >= MIN_CASES


def test_every_topic_is_covered(goldset: GoldSet, corpus: Corpus) -> None:
    covered = {c.topic for c in goldset.cases if c.topic}
    assert covered == set(corpus.topics())


def test_hard_slices_are_present_and_populated(goldset: GoldSet) -> None:
    """A golden set of only well-formed English queries proves nothing."""
    for name in ("hinglish", "terse", "symptom", "prohibition", "misspelled",
                 "near_miss", "out_of_corpus", "india_specific"):
        assert len(goldset.slice(name)) >= MIN_PER_SLICE, name


def test_out_of_corpus_cases_have_no_gold(goldset: GoldSet) -> None:
    for case in goldset.slice("out_of_corpus"):
        assert case.is_out_of_corpus


def test_case_ids_are_unique(goldset: GoldSet) -> None:
    counts = Counter(c.case_id for c in goldset.cases)
    assert [k for k, v in counts.items() if v > 1] == []


def test_queries_are_not_duplicated(goldset: GoldSet) -> None:
    counts = Counter(c.query.lower() for c in goldset.cases)
    assert [k for k, v in counts.items() if v > 1] == []


def test_gold_and_also_relevant_do_not_overlap(goldset: GoldSet) -> None:
    for case in goldset.cases:
        assert not set(case.gold) & set(case.also_relevant), case.case_id


# ------------------------------------------------------------------ metrics

def _matcher(gold: tuple[str, ...], corpus: Corpus) -> CaseMatcher:
    case = GoldCase(case_id="t", query="q", gold=gold)
    return resolve(GoldSet([case]), corpus)[0]


def test_recall_counts_distinct_gold_spans(corpus: Corpus) -> None:
    ids = tuple(c.chunk_id for c in corpus.children[:2])
    matcher = _matcher(ids, corpus)
    assert recall_at_k(list(ids), matcher, 5) == 1.0
    assert recall_at_k([ids[0]], matcher, 5) == 0.5
    assert recall_at_k([], matcher, 5) == 0.0


def test_ndcg_rewards_ranking_the_best_chunk_first(corpus: Corpus) -> None:
    gold = corpus.children[0].chunk_id
    other = corpus.children[50].chunk_id
    matcher = _matcher((gold,), corpus)
    assert ndcg_at_k([gold, other], matcher, 5) > ndcg_at_k([other, gold], matcher, 5)


def test_case_is_marked_failed_when_nothing_relevant_returns(corpus: Corpus) -> None:
    matcher = _matcher((corpus.children[0].chunk_id,), corpus)
    result = evaluate_case([corpus.children[300].chunk_id], matcher)
    assert result.failed


# ------------------------------------------------------------------- spans

def test_span_overlap_is_topic_scoped() -> None:
    assert Span("a", 1, 10).overlap(Span("b", 1, 10)) == 0
    assert Span("a", 1, 10).overlap(Span("a", 5, 20)) == 6


def test_labels_score_a_different_chunking_policy(goldset: GoldSet, corpus: Corpus) -> None:
    """The whole point of span resolution: sweep chunking without relabelling."""
    coarse = load_corpus(
        cfg=ChunkConfig(min_tokens=200, target_tokens=300, max_tokens=400,
                        explode_lists=False, anchor_flush=False)
    )
    matchers = resolve(goldset, corpus, coarse)
    scored = [m for m in matchers if not m.case.is_out_of_corpus]
    # Under a coarser policy every gold span must still be reachable: some
    # coarse chunk covers it, otherwise the sweep would be measuring nothing.
    hits = sum(
        1
        for m in scored
        if any(m.relevance(c.chunk_id) == 2 for c in coarse.children if c.topic == m.case.topic)
    )
    assert hits / len(scored) > 0.95


@pytest.mark.parametrize("k", [1, 5, 20])
def test_out_of_corpus_cases_score_neutrally(corpus: Corpus, k: int) -> None:
    matcher = _matcher((), corpus)
    assert recall_at_k([], matcher, k) == 1.0
