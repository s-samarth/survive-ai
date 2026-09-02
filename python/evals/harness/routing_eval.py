"""Scoring the router: did each query get sent down the right path?

Two errors, and they are not equally bad.

    A **false decline** turns away someone in an emergency the corpus could
    have helped with. It is the worst thing this app can do short of giving
    dangerous advice, and it is counted and listed individually.

    A **false answer** lets a 2B model improvise on a question the corpus
    cannot support -- how to invest, what the weather is. Bad, but the
    generation eval's grounding and safety checks are a second net under it.

So the threshold is not tuned to maximise accuracy. It is tuned to drive false
declines to zero and then minimise false answers.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from survive_rag.retrieval.expansion import is_transliterated
from survive_rag.retrieval.pipeline import Retriever
from survive_rag.routing import ANSWER, CAPABILITY, DECLINE, Route, Signals, route

from .goldset import GoldCase, GoldSet


def expected_intent(case: GoldCase) -> str:
    """What the router should have decided for this case."""
    if case.is_capability:
        return CAPABILITY
    return DECLINE if case.is_out_of_corpus else ANSWER


@dataclass(frozen=True, slots=True)
class RouteResult:
    """One case's routing outcome."""

    case: GoldCase
    expected: str
    actual: Route

    @property
    def correct(self) -> bool:
        """True when the router chose the expected path."""
        return self.actual.intent == self.expected

    @property
    def is_false_decline(self) -> bool:
        """Turned away a query the corpus could have answered."""
        return self.expected == ANSWER and self.actual.intent == DECLINE

    @property
    def is_false_answer(self) -> bool:
        """Answered a query the corpus cannot support."""
        return self.expected == DECLINE and self.actual.intent == ANSWER


@dataclass(slots=True)
class RoutingReport:
    """Aggregate routing behaviour over a golden set."""

    results: list[RouteResult] = field(default_factory=list)
    threshold: float = 0.0

    @property
    def accuracy(self) -> float:
        """Fraction routed correctly. Reported, but not what is optimised."""
        return (
            sum(r.correct for r in self.results) / len(self.results)
            if self.results
            else 0.0
        )

    @property
    def false_declines(self) -> list[RouteResult]:
        """The list that must be empty."""
        return [r for r in self.results if r.is_false_decline]

    @property
    def false_answers(self) -> list[RouteResult]:
        """Out-of-corpus queries that were not declined."""
        return [r for r in self.results if r.is_false_answer]

    def rate_for(self, expected: str) -> float:
        """Fraction of cases expecting ``expected`` that got it."""
        subset = [r for r in self.results if r.expected == expected]
        return sum(r.correct for r in subset) / len(subset) if subset else 0.0

    def confusion(self) -> dict[str, dict[str, int]]:
        """``expected -> actual -> count``, for the report table."""
        table: dict[str, dict[str, int]] = {}
        for result in self.results:
            row = table.setdefault(result.expected, {})
            row[result.actual.intent] = row.get(result.actual.intent, 0) + 1
        return table


def signals_for(query: str, retriever: Retriever) -> Signals:
    """Gather the router's evidence for one query."""
    return Signals(
        confidence=retriever.confidence(query),
        has_bridge_terms=is_transliterated(query, retriever.vocabulary),
    )


def run_routing(
    goldset: GoldSet,
    retriever: Retriever,
    *,
    threshold: float,
    capability_veto: float,
) -> RoutingReport:
    """Route every case and score the decisions.

    Args:
        goldset: The retrieval golden set; its slices carry the expected
            intent, so no separate labelling is needed.
        retriever: A configured pipeline with a dense leg.
        threshold: Answer threshold under test.
        capability_veto: Capability veto under test.

    Returns:
        A populated :class:`RoutingReport`.
    """
    results = [
        RouteResult(
            case=case,
            expected=expected_intent(case),
            actual=route(
                case.query,
                signals_for(case.query, retriever),
                threshold=threshold,
                capability_veto=capability_veto,
            ),
        )
        for case in goldset.cases
    ]
    return RoutingReport(results=results, threshold=threshold)


def render(report: RoutingReport) -> str:
    """Format a routing report for the console."""
    lines = [
        f"routing -- {len(report.results)} cases, threshold {report.threshold:.3f}",
        "",
        f"  accuracy          {report.accuracy:.1%}",
        f"  answer   correct  {report.rate_for(ANSWER):.1%}",
        f"  decline  correct  {report.rate_for(DECLINE):.1%}",
        f"  capability correct {report.rate_for(CAPABILITY):.1%}",
        "",
        f"  FALSE DECLINES    {len(report.false_declines)}   (must be 0)",
        f"  false answers     {len(report.false_answers)}",
        "",
        "confusion (expected -> actual):",
    ]
    for expected, row in sorted(report.confusion().items()):
        got = "  ".join(f"{k}={v}" for k, v in sorted(row.items()))
        lines.append(f"  {expected:11} {got}")

    for label, group in (
        ("FALSE DECLINES", report.false_declines),
        ("false answers", report.false_answers),
    ):
        if group:
            lines += ["", f"{label}:"]
            lines += [
                f"  [{r.case.case_id}] conf={r.actual.confidence:.3f}  {r.case.query!r}"
                for r in group[:12]
            ]
    return "\n".join(lines)
