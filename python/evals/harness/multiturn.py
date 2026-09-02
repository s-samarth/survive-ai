"""The multi-turn golden set: conversations, not isolated questions.

A single-turn eval cannot see the failure that matters most in a real
conversation. "Should I tie something above it" contains no topic word, so
retrieval on the turn alone searches eighteen guides for ``tie`` and ``above``.
The user has told us what they are talking about; the question is whether the
system still knows.

Three things are scored per turn:

    * **retrieval** -- did the right chunk come back for *this* turn, given
      what came before? Reuses the same span-resolved labels as the
      single-turn set, so the numbers are directly comparable.
    * **generation** -- the same safety and grounding checks, because a
      prohibition is no less deadly on turn three.
    * **budget** -- does the prompt still fit once history is in it?

Turn ids are ``<case>#t<n>``, which lets every existing retrieval metric run
over a conversation unchanged.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .gen_cases import GenCase
from .goldset import GoldCase, GoldSet


@dataclass(frozen=True, slots=True)
class Turn:
    """One user message inside a conversation.

    Attributes:
        query: What the user typed on this turn.
        gold: Chunk ids that answer it; empty means nothing should be found.
        also_relevant: Useful but not the best answer.
        must_not_affirm: Phrases the answer must never assert.
        must_negate: Groups of alternative phrasings; one negated member
            per group satisfies the check.
        must_mention_any: Alternative groups; one hit per group is required.
        note: Free text explaining a non-obvious label.
    """

    query: str
    gold: tuple[str, ...] = ()
    also_relevant: tuple[str, ...] = ()
    must_not_affirm: tuple[str, ...] = ()
    must_negate: tuple[tuple[str, ...], ...] = ()
    must_mention_any: tuple[tuple[str, ...], ...] = ()
    note: str = ""

    @property
    def is_safety_critical(self) -> bool:
        """True when this turn asserts something that could get someone hurt."""
        return bool(self.must_not_affirm or self.must_negate)


@dataclass(frozen=True, slots=True)
class Conversation:
    """A labelled multi-turn exchange.

    Attributes:
        case_id: Stable identifier, e.g. ``"mt-bi-001"``.
        turns: The user messages in order; at least two.
        topic: Expected guide for the conversation as a whole.
        slices: Tags this conversation is reported under.
        note: Free text explaining what the conversation is testing.
    """

    case_id: str
    turns: tuple[Turn, ...]
    topic: str | None = None
    slices: tuple[str, ...] = ()
    note: str = ""

    def turn_id(self, index: int) -> str:
        """Id of one turn, unique across the whole set."""
        return f"{self.case_id}#t{index + 1}"

    def gold_case(self, index: int) -> GoldCase:
        """Express one turn as a retrieval case, for the existing metrics."""
        turn = self.turns[index]
        return GoldCase(
            case_id=self.turn_id(index),
            query=turn.query,
            gold=turn.gold,
            also_relevant=turn.also_relevant,
            topic=self.topic,
            slices=(*self.slices, f"turn{index + 1}"),
            note=turn.note,
        )

    def gen_case(self, index: int) -> GenCase:
        """Express one turn as a generation case, for the existing checks."""
        turn = self.turns[index]
        return GenCase(
            case_id=self.turn_id(index),
            query=turn.query,
            topic=self.topic,
            must_not_affirm=turn.must_not_affirm,
            must_negate=turn.must_negate,
            must_mention_any=turn.must_mention_any,
            slices=(*self.slices, f"turn{index + 1}"),
            note=turn.note,
        )


@dataclass(slots=True)
class ConversationSet:
    """A loaded multi-turn golden set."""

    conversations: list[Conversation] = field(default_factory=list)

    def as_goldset(self) -> GoldSet:
        """Flatten every turn into a retrieval golden set.

        This is what lets the multi-turn numbers sit in the same table as the
        single-turn ones: identical labels, identical span resolution,
        identical metrics -- only the query construction differs.
        """
        return GoldSet(
            cases=[
                c.gold_case(i)
                for c in self.conversations
                for i in range(len(c.turns))
            ]
        )

    def slice_names(self) -> list[str]:
        """Every slice tag present, sorted."""
        return sorted({s for c in self.conversations for s in c.slices})

    @property
    def turn_count(self) -> int:
        """Total labelled turns across all conversations."""
        return sum(len(c.turns) for c in self.conversations)

    def __len__(self) -> int:
        """Number of conversations."""
        return len(self.conversations)


def _turn_from(raw: dict) -> Turn:
    """Build one :class:`Turn` from a decoded JSON object."""
    return Turn(
        query=raw["query"],
        gold=tuple(raw.get("gold", ())),
        also_relevant=tuple(raw.get("also_relevant", ())),
        must_not_affirm=tuple(raw.get("must_not_affirm", ())),
        must_negate=tuple(
            (e,) if isinstance(e, str) else tuple(e)
            for e in raw.get("must_negate", ())
        ),
        must_mention_any=tuple(tuple(g) for g in raw.get("must_mention_any", ())),
        note=raw.get("note", ""),
    )


def load_conversations(path: Path) -> ConversationSet:
    """Read a multi-turn golden set from JSONL.

    Args:
        path: File with one conversation per line.

    Returns:
        The loaded :class:`ConversationSet`.

    Raises:
        ValueError: On a duplicate id or a conversation with fewer than two
            turns, which would silently be a single-turn case in disguise.
    """
    conversations: list[Conversation] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        raw = json.loads(line)
        turns = tuple(_turn_from(t) for t in raw["turns"])
        if len(turns) < 2:
            raise ValueError(f"{raw['id']}: a conversation needs at least two turns")
        if raw["id"] in seen:
            raise ValueError(f"duplicate conversation id {raw['id']!r}")
        seen.add(raw["id"])
        conversations.append(
            Conversation(
                case_id=raw["id"],
                turns=turns,
                topic=raw.get("topic"),
                slices=tuple(raw.get("slices", ())),
                note=raw.get("note", ""),
            )
        )
    return ConversationSet(conversations=conversations)
