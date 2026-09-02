"""Run conversations: retrieve per turn, optionally generate, then score.

The measurement that matters is the *shape* of the curve across turn index.
Turn one is an ordinary single-turn query and should score like one; if turn
three is much worse, the system is losing the thread, and the size of that
drop is the budget available to a fix.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from survive_rag.generation.prompt import ContextChunk, build_chat_prompt, estimate_tokens
from survive_rag.retrieval.conversation import ANCHORED, retrieval_query
from survive_rag.retrieval.pipeline import Retriever

from .gen_checks import CheckOutcome, grounding
from .gen_runner import check_answer
from .multiturn import Conversation, ConversationSet
from .multiturn_report import MultiTurnReport
from .performance import Timing, time_generation
from .spans import CaseMatcher

EVAL_DEPTH = 20


@dataclass(frozen=True, slots=True)
class TurnResult:
    """What one turn produced."""

    turn_id: str
    index: int
    query: str
    retrieved_on: str
    ranked: tuple[str, ...]
    cited: tuple[str, ...]
    recall_at_5: float
    prompt_tokens: int
    answer: str = ""
    outcomes: tuple[CheckOutcome, ...] = ()
    grounding: float = 0.0
    timing: Timing | None = None

    @property
    def safety_violations(self) -> list[CheckOutcome]:
        """Failed critical checks on this turn."""
        return [o for o in self.outcomes if o.critical and not o.passed]

    @property
    def passed(self) -> bool:
        """True when every applicable generation check passed."""
        return all(o.passed for o in self.outcomes)


def _context(hits: list) -> list[ContextChunk]:
    """Render retrieved hits as prompt context chunks."""
    return [
        ContextChunk(h.citation, h.unit.topic, h.unit.heading_path, h.context)
        for h in hits
    ]


def run_conversation(
    conversation: Conversation,
    matchers: dict[str, CaseMatcher],
    retriever: Retriever,
    *,
    strategy: str = ANCHORED,
    generator: Any = None,
    top_k: int = 4,
) -> list[TurnResult]:
    """Walk one conversation, carrying history forward exactly as the app would.

    Args:
        conversation: The labelled exchange.
        matchers: Turn id -> matcher, from :func:`spans.resolve`.
        retriever: A configured pipeline.
        strategy: How the retrieval query is built from history.
        generator: Model under test, or None to score retrieval only.
        top_k: Chunks placed in the prompt.

    Returns:
        One :class:`TurnResult` per turn, in order.
    """
    history: list[tuple[str, str]] = []
    results: list[TurnResult] = []

    for index, turn in enumerate(conversation.turns):
        query = retrieval_query(
            turn.query, history, strategy=strategy, vocabulary=retriever.vocabulary
        )
        hits = retriever.retrieve(query, top_k=EVAL_DEPTH)
        matcher = matchers[conversation.turn_id(index)]
        prompt_hits = hits[:top_k]
        chunks = _context(prompt_hits)
        prompt = build_chat_prompt(chunks, history, turn.query)

        answer, outcomes, score, timing = "", (), 0.0, None
        if generator is not None:
            answer, timing = time_generation(generator, prompt)
            context = "\n\n".join(c.body for c in chunks)
            outcomes = tuple(check_answer(conversation.gen_case(index), answer, context))
            score = grounding(answer, context)

        results.append(
            TurnResult(
                turn_id=conversation.turn_id(index),
                index=index,
                query=turn.query,
                retrieved_on=query,
                ranked=tuple(h.unit_id for h in hits),
                cited=tuple(retriever.citations_for(prompt_hits, query, limit=top_k)),
                recall_at_5=matcher.gold_found([h.unit_id for h in hits], 5)
                / max(matcher.n_gold, 1)
                if matcher.n_gold
                else 1.0,
                prompt_tokens=estimate_tokens(prompt),
                answer=answer,
                outcomes=outcomes,
                grounding=score,
                timing=timing,
            )
        )
        history.append(("user", turn.query))
        history.append(("model", answer or "(not generated)"))

    return results


def run_multiturn(
    conversations: ConversationSet,
    matchers: dict[str, CaseMatcher],
    retriever: Retriever,
    *,
    strategy: str = ANCHORED,
    generator: Any = None,
    top_k: int = 4,
) -> MultiTurnReport:
    """Score every conversation under one query-construction strategy."""
    started = time.perf_counter()
    results: list[TurnResult] = []
    for conversation in conversations.conversations:
        results.extend(
            run_conversation(
                conversation,
                matchers,
                retriever,
                strategy=strategy,
                generator=generator,
                top_k=top_k,
            )
        )
    return MultiTurnReport(
        strategy=strategy,
        generator=getattr(generator, "name", "none"),
        results=results,
        seconds=time.perf_counter() - started,
    )
