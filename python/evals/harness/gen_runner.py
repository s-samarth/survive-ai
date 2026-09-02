"""Run the generation eval: route, retrieve, prompt, generate, check.

Retrieval says the answer was *available*; this says what the model did with
it. Safety failures are counted and listed separately, never averaged into a
quality score: one answer in a hundred recommending a tourniquet is not a 99%
pass, it is an incident.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from evals.generators.generator import Generator
from survive_rag.generation.prompt import ContextChunk, build_chat_prompt
from survive_rag.retrieval.pipeline import Retriever
from survive_rag.routing import ANSWER

from .gen_cases import GenCase, GenSet
from .gen_checks import (
    CheckOutcome,
    abstains,
    affirms,
    grounding,
    mentions_any,
    negates,
)
from .gen_report import GenReport
from .gen_routing import canned_answer, route_query

CHECK_NAMES = ("safety", "negation", "actionable", "grounded", "abstention")


@dataclass(frozen=True, slots=True)
class GenResult:
    """Everything one case produced: the answer, its context and citations,
    one :class:`CheckOutcome` per applicable check, and the wall-clock."""

    case: GenCase
    answer: str
    context: str
    citations: tuple[str, ...]
    outcomes: tuple[CheckOutcome, ...]
    grounding: float
    seconds: float

    @property
    def safety_violations(self) -> list[CheckOutcome]:
        """Failed critical checks -- the list that must stay empty."""
        return [o for o in self.outcomes if o.critical and not o.passed]

    @property
    def passed(self) -> bool:
        """True when every applicable check passed."""
        return all(o.passed for o in self.outcomes)


def check_answer(case: GenCase, answer: str, context: str) -> list[CheckOutcome]:
    """Apply every check that applies to ``case``.

    Args:
        case: The labelled case.
        answer: What the model produced.
        context: The reference block the model was given.

    Returns:
        Outcomes in a stable order, omitting checks the case does not label.
    """
    out: list[CheckOutcome] = []

    for phrase in case.must_not_affirm:
        asserted = affirms(answer, phrase)
        out.append(
            CheckOutcome(
                name="safety",
                passed=not asserted,
                detail=f"asserted {phrase!r}" if asserted else "",
                critical=True,
            )
        )

    for group in case.must_negate:
        kept = any(negates(answer, phrase) for phrase in group)
        out.append(
            CheckOutcome(
                name="negation",
                passed=kept,
                detail="" if kept else f"warned against none of {list(group)}",
                critical=True,
            )
        )

    for group in case.must_mention_any:
        hit = mentions_any(answer, list(group))
        out.append(
            CheckOutcome(
                name="actionable",
                passed=hit,
                detail="" if hit else f"mentioned none of {list(group)}",
            )
        )

    if case.expect_abstention:
        declined = abstains(answer)
        out.append(
            CheckOutcome(
                name="abstention",
                passed=declined,
                detail="" if declined else "answered a question outside the corpus",
            )
        )
    else:
        score = grounding(answer, context)
        out.append(
            CheckOutcome(
                name="grounded",
                passed=score >= case.min_grounding,
                detail=f"grounding {score:.2f} < {case.min_grounding:.2f}"
                if score < case.min_grounding
                else "",
            )
        )
    return out


def run_generation(
    genset: GenSet,
    retriever: Retriever,
    generator: Generator,
    *,
    top_k: int = 4,
    use_router: bool = True,
) -> GenReport:
    """Score one generator end to end on the generation golden set.

    With ``use_router`` the pipeline is measured as it behaves in the app: an
    unsupported query is declined before a model sees it. Turning it off
    measures the model alone, which is what a bake-off wants.

    Args:
        genset: Loaded generation cases.
        retriever: Configured pipeline; supplies context and confidence.
        generator: The model under test.
        top_k: Chunks placed in the prompt, matching the app.
        use_router: Route before generating, as the app does.

    Returns:
        A populated :class:`GenReport`.
    """
    started = time.perf_counter()
    results: list[GenResult] = []
    for case in genset.cases:
        if use_router:
            decision = route_query(case.query, retriever)
            if decision.intent != ANSWER:
                answer = canned_answer(decision.intent)
                results.append(
                    GenResult(
                        case=case,
                        answer=answer,
                        context="",
                        citations=(),
                        outcomes=tuple(check_answer(case, answer, answer)),
                        grounding=1.0,
                        seconds=0.0,
                    )
                )
                continue
        hits = retriever.retrieve(case.query, top_k=top_k)
        chunks = [
            ContextChunk(
                chunk_id=h.citation,
                topic=h.unit.topic,
                heading_path=h.unit.heading_path,
                body=h.context,
            )
            for h in hits
        ]
        prompt = build_chat_prompt(chunks, [], case.query)
        context = "\n\n".join(c.body for c in chunks)
        t0 = time.perf_counter()
        answer = generator.generate(prompt)
        elapsed = time.perf_counter() - t0
        results.append(
            GenResult(
                case=case,
                answer=answer,
                context=context,
                citations=tuple(h.citation for h in hits),
                outcomes=tuple(check_answer(case, answer, context)),
                grounding=grounding(answer, context),
                seconds=elapsed,
            )
        )
    return GenReport(
        generator=getattr(generator, "name", "unknown"),
        results=results,
        seconds=time.perf_counter() - started,
    )
