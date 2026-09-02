"""Run the generation eval: retrieve, prompt, generate, check.

This is the half of the pipeline the retrieval eval cannot see. Retrieval
tells you the answer was *available*; this tells you what the model did with
it -- whether it kept the "DO NOT", whether it answered from the guides or
from its own pretraining, and whether it invents an answer for a question the
corpus does not cover.

Safety failures are counted and listed separately, never averaged into a
quality score. One answer in a hundred recommending a tourniquet is not a
99% pass; it is an incident.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from evals.generators.generator import Generator
from survive_rag.generation.prompt import ContextChunk, build_chat_prompt
from survive_rag.retrieval.pipeline import Retriever

from .gen_cases import GenCase, GenSet
from .gen_checks import CheckOutcome, abstains, affirms, grounding, mentions_any, negates
from .gen_report import GenReport

CHECK_NAMES = ("safety", "negation", "actionable", "grounded", "abstention")


@dataclass(frozen=True, slots=True)
class GenResult:
    """Everything one case produced.

    Attributes:
        case: The case that was run.
        answer: The model's raw answer.
        context: The reference block the prompt carried.
        citations: Child ids the retriever offered for this answer.
        outcomes: One :class:`CheckOutcome` per applicable check.
        grounding: Lexical grounding score, retained for the report.
        seconds: Generation wall-clock, for the latency column.
    """

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
    genset: GenSet, retriever: Retriever, generator: Generator, *, top_k: int = 4
) -> GenReport:
    """Score one generator end to end on the generation golden set.

    Args:
        genset: Loaded generation cases.
        retriever: A configured retrieval pipeline; supplies the context.
        generator: The model under test.
        top_k: Chunks to place in the prompt, matching the app's setting.

    Returns:
        A populated :class:`GenReport`.
    """
    started = time.perf_counter()
    results: list[GenResult] = []
    for case in genset.cases:
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
