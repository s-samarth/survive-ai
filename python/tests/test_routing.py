"""The router: answer, decline, or explain what the app does."""

from __future__ import annotations

import pytest

from evals.harness.goldset import load_goldset
from evals.harness.lab import goldset_path
from evals.harness.routing_eval import expected_intent
from survive_rag.responses import capability_answer, decline_answer
from survive_rag.retrieval.expansion import is_transliterated, transliterated_terms
from survive_rag.routing import (
    ANSWER,
    ANSWER_THRESHOLD,
    CAPABILITY,
    CAPABILITY_VETO,
    DECLINE,
    Signals,
    looks_like_capability_question,
    route,
)


@pytest.mark.parametrize(
    "query",
    [
        "what can you do",
        "how can you help me",
        "who are you",
        "what is this app",
        "hello",
        "namaste",
        "aap kya kar sakte ho",
        "tum kaun ho",
        "help",
    ],
)
def test_capability_questions_are_recognised(query: str) -> None:
    """This is usually someone's first message, so it is the first impression."""
    assert looks_like_capability_question(query)


@pytest.mark.parametrize(
    "query",
    [
        "should I tie a tourniquet on a snake bite",
        "khoon nikal raha hai",
        "chest pain",
        "aag lag gayi hai",
        "how do I purify water",
    ],
)
def test_real_emergencies_are_not_capability_questions(query: str) -> None:
    """A false capability match would answer a snakebite with a help screen."""
    assert not looks_like_capability_question(query)


def test_high_confidence_beats_a_capability_phrase() -> None:
    """'what can you do about a snake bite' is an emergency, not a help request."""
    decision = route("what can you do about a snake bite", Signals(confidence=0.62))
    assert decision.intent == ANSWER


def test_capability_wins_when_confidence_is_ordinary() -> None:
    """Capability queries score mid-range, so the pattern must decide."""
    decision = route("what can you do", Signals(confidence=0.33))
    assert decision.intent == CAPABILITY


def test_low_confidence_declines() -> None:
    """A 2B model must not improvise survival advice about mutual funds."""
    decision = route("how do I invest in mutual funds", Signals(confidence=0.12))
    assert decision.intent == DECLINE
    assert "confidence" in decision.reason


def test_bridge_words_rescue_a_hinglish_emergency() -> None:
    """The embedding cannot read romanised Hindi; the expansion table can.

    Without this floor a real Hinglish emergency scoring 0.20 would be turned
    away, which is the worst error this router can make.
    """
    low = Signals(confidence=0.20, has_bridge_terms=False)
    assert route("saanp ne kaata", low).intent == DECLINE
    rescued = Signals(confidence=0.20, has_bridge_terms=True)
    assert route("saanp ne kaata", rescued).intent == ANSWER


def test_no_dense_signal_declines_rather_than_guesses() -> None:
    """With no evidence at all, admitting ignorance beats improvising."""
    assert route("something obscure", Signals()).intent == DECLINE


def test_thresholds_are_ordered() -> None:
    """The capability veto must sit above the answer threshold to mean anything."""
    assert CAPABILITY_VETO > ANSWER_THRESHOLD


@pytest.mark.parametrize("word", ["aag", "khoon", "saanp", "baadh", "bheed", "chakkar"])
def test_hinglish_emergency_words_are_bridge_terms(word: str) -> None:
    """'aag' regressed once because the corpus happens to use it; guard it."""
    assert is_transliterated(word)


@pytest.mark.parametrize("query", ["snake bite", "how do I lose weight", "chest pain"])
def test_english_queries_are_not_bridge_terms(query: str) -> None:
    """A false bridge match would bypass the decline path for English queries."""
    assert not transliterated_terms(query)


def test_expected_intent_reads_the_golden_set_slices() -> None:
    """Routing labels come from slices already in the set, not a fourth file."""
    goldset = load_goldset(goldset_path("retrieval"))
    intents = {expected_intent(c) for c in goldset.cases}
    assert intents == {ANSWER, DECLINE, CAPABILITY}


def test_canned_answers_name_what_the_app_covers() -> None:
    """A refusal that stops at 'no' fails someone who is about to need help."""
    for text in (capability_answer(), decline_answer()):
        assert "Survive AI" in text or "emergency" in text
        assert text.count("- ") >= 5
    assert "112" in decline_answer()
    assert "Hinglish" in capability_answer()
