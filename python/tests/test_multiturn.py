"""Multi-turn: conversation modelling, query construction, and the runner."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from evals.harness.lab import goldset_path
from evals.harness.multiturn import Conversation, Turn, load_conversations
from evals.harness.multiturn_report import MultiTurnReport
from survive_rag.retrieval.conversation import (
    ANCHORED,
    BARE,
    WINDOW,
    retrieval_query,
)

HISTORY = [
    ("user", "my friend was bitten by a snake in the field"),
    ("model", "Get to a hospital that stocks ASV."),
]


def test_bare_strategy_returns_the_turn_unchanged() -> None:
    """The baseline must be exactly what the app does today."""
    assert retrieval_query("should I tie it", HISTORY, strategy=BARE) == "should I tie it"


def test_window_strategy_carries_the_opening_question() -> None:
    """A follow-up with no topic word needs the topic from earlier turns."""
    built = retrieval_query("should I tie it", HISTORY, strategy=WINDOW)
    assert "snake" in built and "tie" in built


def test_anchored_strategy_keeps_only_topic_terms() -> None:
    """Filler from history must not dilute the current question."""
    built = retrieval_query(
        "should I tie it", HISTORY, strategy=ANCHORED, vocabulary=frozenset({"snake"})
    )
    assert "snake" in built
    assert "was" not in built.split()


def test_anchored_falls_back_when_history_has_no_topic_terms() -> None:
    """With nothing worth carrying, the turn is used as-is."""
    history = [("user", "hello there")]
    assert retrieval_query("what now", history, strategy=ANCHORED) == "what now"


def test_first_turn_is_unchanged_by_every_strategy() -> None:
    """An opening question has no history, so all strategies must agree."""
    for strategy in (BARE, WINDOW, ANCHORED):
        assert retrieval_query("snake bite", [], strategy=strategy) == "snake bite"


def test_unknown_strategy_is_rejected() -> None:
    """A typo in a sweep must fail loudly, not silently score the baseline."""
    with pytest.raises(ValueError, match="unknown conversation strategy"):
        retrieval_query("q", HISTORY, strategy="magic")


def test_conversation_flattens_to_retrieval_and_generation_cases() -> None:
    """One labelled turn must feed both existing metric stacks unchanged."""
    conversation = Conversation(
        case_id="mt-x",
        turns=(Turn(query="a", gold=("t#h#c",)), Turn(query="b", must_negate=("ice",))),
        topic="bites",
        slices=("anaphora",),
    )
    assert conversation.turn_id(0) == "mt-x#t1"
    assert conversation.gold_case(0).gold == ("t#h#c",)
    assert "turn1" in conversation.gold_case(0).slices
    assert conversation.gen_case(1).must_negate == ("ice",)


def test_single_turn_conversations_are_rejected(tmp_path: Path) -> None:
    """A one-turn 'conversation' is a single-turn case in disguise."""
    path = tmp_path / "bad.jsonl"
    path.write_text(
        json.dumps({"id": "x", "turns": [{"query": "only one"}]}) + "\n", encoding="utf-8"
    )
    with pytest.raises(ValueError, match="at least two turns"):
        load_conversations(path)


def test_duplicate_conversation_ids_are_rejected(tmp_path: Path) -> None:
    """A duplicate would double-weight one conversation in the aggregate."""
    row = json.dumps({"id": "x", "turns": [{"query": "a"}, {"query": "b"}]})
    path = tmp_path / "dupe.jsonl"
    path.write_text(f"{row}\n{row}\n", encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate"):
        load_conversations(path)


def test_shipped_multiturn_set_is_well_formed() -> None:
    """The committed set must stay loadable and meaningfully sized."""
    conversations = load_conversations(goldset_path("multiturn"))
    assert len(conversations) >= 10
    assert conversations.turn_count >= 25
    assert all(len(c.turns) >= 2 for c in conversations.conversations)
    assert any("anaphora" in c.slices for c in conversations.conversations)
    assert any("topic_switch" in c.slices for c in conversations.conversations)
    flattened = conversations.as_goldset()
    assert len(flattened.cases) == conversations.turn_count


def test_report_separates_opening_turns_from_follow_ups() -> None:
    """The headline is the drop between them, so they cannot be averaged."""
    from evals.harness.multiturn_runner import TurnResult

    def result(index: int, recall: float) -> TurnResult:
        return TurnResult(
            turn_id=f"c#t{index + 1}",
            index=index,
            query="q",
            retrieved_on="q",
            ranked=(),
            cited=(),
            recall_at_5=recall,
            prompt_tokens=100,
        )

    report = MultiTurnReport(strategy=BARE, results=[result(0, 1.0), result(1, 0.0)])
    assert report.first_turn_recall == 1.0
    assert report.follow_up_recall == 0.0
    assert report.recall_at_5 == 0.5
    assert report.recall_by_turn() == {1: 1.0, 2: 0.0}
