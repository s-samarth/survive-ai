"""The golden set: hand-authored ``query -> gold chunk id`` cases.

Stored as JSONL so that a diff shows one changed case per line, and so cases
can be appended without rewriting the file. Every case is validated against
the live corpus before a run: a gold id that no longer exists means the guide
was edited and the label is stale, which must fail loudly rather than quietly
depress the score.

Relevance is graded, not binary:

    ``gold``          -- relevance 2, the chunk that actually answers the query
    ``also_relevant`` -- relevance 1, genuinely useful but not the best answer

Graded labels matter because several guides legitimately cover the same
emergency, and a metric that calls the second-best chunk "wrong" punishes the
retriever for being right.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from ..corpus.models import Corpus

GOLD_RELEVANCE = 2
PARTIAL_RELEVANCE = 1


@dataclass(frozen=True, slots=True)
class GoldCase:
    """One evaluated query.

    Attributes:
        case_id: Stable short identifier, e.g. ``"snk-004"``.
        query: Exactly what a user would type, including any misspelling.
        gold: Chunk ids that fully answer the query. Empty means the query is
            deliberately out of corpus and the retriever should find nothing.
        also_relevant: Chunk ids that are useful but not the best answer.
        topic: Expected topic key, used for the topic-routing metric.
        slices: Tags this case is reported under, e.g. ``["hinglish", "terse"]``.
        note: Free text explaining a non-obvious label.
    """

    case_id: str
    query: str
    gold: tuple[str, ...] = ()
    also_relevant: tuple[str, ...] = ()
    topic: str | None = None
    slices: tuple[str, ...] = ()
    note: str = ""

    @property
    def is_out_of_corpus(self) -> bool:
        """True when the correct behaviour is to retrieve nothing."""
        return not self.gold

    def relevance(self, chunk_id: str) -> int:
        """Graded relevance of ``chunk_id`` for this case."""
        if chunk_id in self.gold:
            return GOLD_RELEVANCE
        if chunk_id in self.also_relevant:
            return PARTIAL_RELEVANCE
        return 0


@dataclass(slots=True)
class GoldSet:
    """A loaded, validated collection of :class:`GoldCase`."""

    cases: list[GoldCase] = field(default_factory=list)

    def slice(self, name: str) -> list[GoldCase]:
        """Return the cases tagged ``name``."""
        return [c for c in self.cases if name in c.slices]

    def slice_names(self) -> list[str]:
        """Return every slice tag present, sorted."""
        return sorted({s for c in self.cases for s in c.slices})

    def __len__(self) -> int:
        return len(self.cases)


def load_goldset(path: Path) -> GoldSet:
    """Read a golden set from JSONL.

    Args:
        path: Path to the ``.jsonl`` file. Blank lines and ``#`` comment lines
            are skipped so the file can be annotated in place.

    Returns:
        The parsed :class:`GoldSet`.

    Raises:
        ValueError: If a case is missing ``id`` or ``query``, or a case id
            repeats.
    """
    cases: list[GoldCase] = []
    seen: set[str] = set()
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        data = json.loads(line)
        case_id, query = data.get("id"), data.get("query")
        if not case_id or not query:
            raise ValueError(f"{path.name}:{lineno}: case needs both 'id' and 'query'")
        if case_id in seen:
            raise ValueError(f"{path.name}:{lineno}: duplicate case id {case_id!r}")
        seen.add(case_id)
        cases.append(
            GoldCase(
                case_id=case_id,
                query=query,
                gold=tuple(data.get("gold", ())),
                also_relevant=tuple(data.get("also_relevant", ())),
                topic=data.get("topic"),
                slices=tuple(data.get("slices", ())),
                note=data.get("note", ""),
            )
        )
    return GoldSet(cases=cases)


def validate(goldset: GoldSet, corpus: Corpus) -> list[str]:
    """Check every label against the live corpus.

    Args:
        goldset: The loaded golden set.
        corpus: The freshly chunked corpus.

    Returns:
        Human-readable problem descriptions; empty means the set is clean.
    """
    problems: list[str] = []
    for case in goldset.cases:
        for chunk_id in (*case.gold, *case.also_relevant):
            if corpus.child(chunk_id) is None:
                problems.append(f"{case.case_id}: unknown chunk id {chunk_id!r}")
        if case.topic and case.topic not in corpus.topics():
            problems.append(f"{case.case_id}: unknown topic {case.topic!r}")
        if case.is_out_of_corpus and "out_of_corpus" not in case.slices:
            problems.append(f"{case.case_id}: empty gold must be tagged out_of_corpus")
    return problems
