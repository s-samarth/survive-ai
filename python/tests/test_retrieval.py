"""Tokenisation, expansion, BM25, fusion and the assembled pipeline."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from survive_rag.config import RetrievalConfig
from survive_rag.corpus.models import Corpus
from survive_rag.retrieval.bm25 import build_index
from survive_rag.retrieval.expansion import expand
from survive_rag.retrieval.expansion_terms import EXPANSION_TERMS
from survive_rag.retrieval.fusion import reciprocal_rank_fusion
from survive_rag.retrieval.pipeline import Retriever
from survive_rag.retrieval.tokenizer import index_terms, stem_candidates, tokenize


def test_tokenize_drops_stopwords_and_punctuation() -> None:
    assert tokenize("The building, is collapsing!") == ["building", "collapsing"]


def test_stemmer_reaches_the_silent_e_form() -> None:
    """Naive '-ing' stripping gives 'collaps', which matches nothing."""
    assert "collapse" in stem_candidates("collapsing")
    assert "bleed" in stem_candidates("bleeding")


def test_index_terms_include_stems() -> None:
    assert "collapse" in index_terms("the building is collapsing")


def test_hinglish_expansion_reaches_english_corpus_terms() -> None:
    """Without these, a large share of real Indian queries retrieve nothing."""
    assert "blood" in expand("khoon nikal raha hai")
    assert "snake" in expand("saanp ne kaata")
    assert "fire" in expand("ghar me aag lag gayi")


def test_expansion_never_repeats_the_query() -> None:
    assert "fire" not in expand("fire in the building")


def test_expansion_is_capped() -> None:
    assert len(expand("bleeding fire snake flood earthquake", max_expansions=6)) <= 6


def test_expansion_keys_are_single_lowercase_words() -> None:
    assert all(re.fullmatch(r"[a-z0-9]+", k) for k in EXPANSION_TERMS)


def test_expansion_parity_with_dart(root: Path) -> None:
    """The Dart table is the runtime one; a drift here is a silent app bug."""
    dart = (root / "lib" / "utils" / "expansion_terms.dart").read_text(encoding="utf-8")
    keys = set(re.findall(r"'([a-z0-9]+)':\s*\[", dart))
    assert set(EXPANSION_TERMS) == keys, set(EXPANSION_TERMS) ^ keys


def test_bm25_prefers_the_document_containing_the_rare_term() -> None:
    index = build_index(
        [
            ("a", ["tourniquet", "limb", "bleeding"]),
            ("b", ["bleeding", "pressure", "dressing"]),
            ("c", ["bleeding", "pressure", "cloth"]),
        ]
    )
    assert index.search(["tourniquet"])[0][0] == "a"


def test_bm25_discounts_terms_present_in_every_document() -> None:
    """A universal term must not outrank a rare one, and must never score
    negative -- the unsmoothed IDF goes negative and penalises a real match."""
    index = build_index([("a", ["x", "y"]), ("b", ["x", "z"]), ("c", ["x", "w"])])
    universal = index.score(["x"])
    rare = index.score(["y"])
    assert all(v > 0 for v in universal.values())
    assert rare["a"] > universal["a"]


def test_bm25_skips_unseen_terms() -> None:
    index = build_index([("a", ["x"])])
    assert index.score(["nothing-like-this"]) == {}


def test_rrf_rewards_agreement_between_legs() -> None:
    fused = dict(reciprocal_rank_fusion([["a", "b", "c"], ["b", "c", "a"]]))
    assert fused["b"] > fused["a"] or fused["a"] == pytest.approx(fused["b"], abs=1e-9)
    assert fused["b"] > fused["c"]


def test_rrf_rejects_mismatched_weights() -> None:
    with pytest.raises(ValueError):
        reciprocal_rank_fusion([["a"], ["b"]], weights=[1.0])


def test_retriever_returns_ranked_results(corpus: Corpus) -> None:
    hits = Retriever(corpus=corpus).retrieve("snake bite first aid", top_k=5)
    assert [h.rank for h in hits] == [1, 2, 3, 4, 5]
    assert all(h.child.topic == "bites" for h in hits[:2])


def test_results_carry_parent_context_for_the_model(corpus: Corpus) -> None:
    hit = Retriever(corpus=corpus).retrieve("how do I do cpr", top_k=1)[0]
    assert hit.parent is not None
    assert len(hit.context) >= len(hit.child.text)


def test_oversized_parents_fall_back_to_the_child(corpus: Corpus) -> None:
    """A single huge section must never blow the prompt budget."""
    config = RetrievalConfig(max_parent_tokens=1)
    for hit in Retriever(corpus=corpus, config=config).retrieve("flood", top_k=3):
        assert hit.context == hit.child.text


def test_mmr_reduces_duplicate_prohibitions(corpus: Corpus) -> None:
    """Without diversification, 'snakebite' returns four near-identical don'ts."""
    diverse = Retriever(corpus=corpus, config=RetrievalConfig(mmr_lambda=0.6))
    plain = Retriever(corpus=corpus, config=RetrievalConfig(mmr_lambda=1.0))
    query = "snake bite what should I not do"
    n_diverse = sum(1 for h in diverse.retrieve(query, top_k=5) if h.child.is_prohibition)
    n_plain = sum(1 for h in plain.retrieve(query, top_k=5) if h.child.is_prohibition)
    assert n_diverse <= n_plain


def test_empty_query_retrieves_nothing(corpus: Corpus) -> None:
    assert Retriever(corpus=corpus).retrieve("   ") == []
