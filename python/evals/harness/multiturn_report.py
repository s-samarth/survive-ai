"""Aggregation for the multi-turn eval.

The headline is not a single score but a curve: how retrieval quality moves
from the opening question to the follow-ups that depend on it. A flat curve
means the system holds the thread; a falling one measures exactly how much it
forgets, which is the budget available to a fix.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from survive_rag.generation.prompt import MAX_PROMPT_TOKENS

if TYPE_CHECKING:  # pragma: no cover - import cycle guard
    from .multiturn_runner import TurnResult

@dataclass(slots=True)
class MultiTurnReport:
    """Aggregate outcome of one strategy on the conversation set."""

    strategy: str
    generator: str = "none"
    results: list[TurnResult] = field(default_factory=list)
    seconds: float = 0.0

    def recall_by_turn(self) -> dict[int, float]:
        """Mean Recall@5 per turn index -- the curve that matters."""
        out: dict[int, float] = {}
        for index in sorted({r.index for r in self.results}):
            subset = [r for r in self.results if r.index == index]
            out[index + 1] = sum(r.recall_at_5 for r in subset) / len(subset)
        return out

    def tokens_by_turn(self) -> dict[int, float]:
        """Mean prompt size per turn index, against the 1452-token budget."""
        out: dict[int, float] = {}
        for index in sorted({r.index for r in self.results}):
            subset = [r for r in self.results if r.index == index]
            out[index + 1] = sum(r.prompt_tokens for r in subset) / len(subset)
        return out

    @property
    def recall_at_5(self) -> float:
        """Mean Recall@5 across every turn."""
        return (
            sum(r.recall_at_5 for r in self.results) / len(self.results)
            if self.results
            else 0.0
        )

    @property
    def first_turn_recall(self) -> float:
        """Recall on opening turns, which are ordinary single-turn queries."""
        first = [r for r in self.results if r.index == 0]
        return sum(r.recall_at_5 for r in first) / len(first) if first else 0.0

    @property
    def follow_up_recall(self) -> float:
        """Recall on every turn after the first -- the number under test."""
        rest = [r for r in self.results if r.index > 0]
        return sum(r.recall_at_5 for r in rest) / len(rest) if rest else 0.0

    @property
    def incidents(self) -> list[TurnResult]:
        """Turns with a safety violation."""
        return [r for r in self.results if r.safety_violations]

    @property
    def over_budget(self) -> list[TurnResult]:
        """Turns whose prompt exceeded the model's prompt budget."""
        return [r for r in self.results if r.prompt_tokens > MAX_PROMPT_TOKENS]
