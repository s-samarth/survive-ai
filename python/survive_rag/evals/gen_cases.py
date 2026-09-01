"""The generation golden set: query -> what a safe answer must and must not say.

A retrieval label says which chunk should be found. A generation label says
what the answer has to do with it, in four kinds:

    ``must_not_affirm``   phrases that would be dangerous if asserted. The
                          check is negation-aware, so a correct answer may
                          -- and usually must -- mention them in order to
                          warn against them.
    ``must_negate``       the answer must both mention the phrase and warn
                          against it. This catches the specific failure of a
                          small model dropping a "DO NOT" while copying the
                          rest of a prohibition chunk.
    ``must_mention_any``  groups of alternatives; each group needs one hit.
                          This is the actionable content -- "hospital", "ASV".
    ``expect_abstention`` the query is out of corpus and the answer must say
                          so rather than invent something.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True, slots=True)
class GenCase:
    """One evaluated generation.

    Attributes:
        case_id: Stable short identifier, e.g. ``"gen-bi-001"``.
        query: Exactly what the user would type.
        topic: Expected guide, used to report per-topic failures.
        must_not_affirm: Phrases the answer must never assert.
        must_negate: Phrases the answer must mention *and* warn against.
        must_mention_any: Alternative groups; one hit per group is required.
        expect_abstention: The answer should decline rather than answer.
        min_grounding: Floor on the lexical grounding proxy.
        slices: Tags this case is reported under.
        note: Free text explaining a non-obvious label.
    """

    case_id: str
    query: str
    topic: str | None = None
    must_not_affirm: tuple[str, ...] = ()
    must_negate: tuple[str, ...] = ()
    must_mention_any: tuple[tuple[str, ...], ...] = ()
    expect_abstention: bool = False
    min_grounding: float = 0.35
    slices: tuple[str, ...] = ()
    note: str = ""

    @property
    def is_safety_critical(self) -> bool:
        """True when the case asserts something that could get someone hurt."""
        return bool(self.must_not_affirm or self.must_negate)


@dataclass(slots=True)
class GenSet:
    """A loaded generation golden set."""

    cases: list[GenCase] = field(default_factory=list)

    def slice_names(self) -> list[str]:
        """Every slice tag present, sorted."""
        return sorted({s for c in self.cases for s in c.slices})

    def __len__(self) -> int:
        """Number of cases."""
        return len(self.cases)


def _case_from(raw: dict) -> GenCase:
    """Build one :class:`GenCase` from a decoded JSONL row."""
    return GenCase(
        case_id=raw["id"],
        query=raw["query"],
        topic=raw.get("topic"),
        must_not_affirm=tuple(raw.get("must_not_affirm", ())),
        must_negate=tuple(raw.get("must_negate", ())),
        must_mention_any=tuple(tuple(g) for g in raw.get("must_mention_any", ())),
        expect_abstention=bool(raw.get("expect_abstention", False)),
        min_grounding=float(raw.get("min_grounding", 0.35)),
        slices=tuple(raw.get("slices", ())),
        note=raw.get("note", ""),
    )


def load_genset(path: Path) -> GenSet:
    """Read a generation golden set from JSONL.

    Args:
        path: File with one JSON object per line; blank lines are ignored.

    Returns:
        The loaded :class:`GenSet`.

    Raises:
        ValueError: If a case id is duplicated, which would silently
            double-weight it in the aggregate.
    """
    cases: list[GenCase] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        case = _case_from(json.loads(line))
        if case.case_id in seen:
            raise ValueError(f"duplicate generation case id {case.case_id!r}")
        seen.add(case.case_id)
        cases.append(case)
    return GenSet(cases=cases)


def validate(genset: GenSet, topics: list[str]) -> list[str]:
    """Return human-readable problems with the set, empty when it is sound.

    Args:
        genset: The loaded set.
        topics: Valid topic keys, from the corpus.

    Returns:
        One message per problem found.
    """
    problems: list[str] = []
    for case in genset.cases:
        if case.topic and case.topic not in topics:
            problems.append(f"{case.case_id}: unknown topic {case.topic!r}")
        if case.expect_abstention and case.is_safety_critical:
            problems.append(
                f"{case.case_id}: abstention cases cannot also assert content"
            )
        if not case.query.strip():
            problems.append(f"{case.case_id}: empty query")
    return problems
