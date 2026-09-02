"""Multi-turn command: does the system hold the thread across turns?"""

from __future__ import annotations

import argparse

from survive_rag.config import RECOMMENDED
from survive_rag.generation.prompt import MAX_PROMPT_TOKENS
from survive_rag.retrieval.conversation import ANCHORED, BARE, WINDOW

from ..harness.lab import goldset_path, reference_corpus, retriever_for
from ..harness.multiturn import load_conversations
from ..harness.multiturn_runner import run_multiturn
from ..harness.spans import resolve

STRATEGIES = (BARE, WINDOW, ANCHORED)


def cmd_multiturn(args: argparse.Namespace) -> int:
    """Score conversations under each query-construction strategy."""
    generator = None
    if args.model:
        from ..generators.generator import load_generator

        generator = load_generator(args.model)

    conversations = load_conversations(goldset_path("multiturn"))
    config = RECOMMENDED.with_(use_dense_leg=not args.no_dense)
    retriever = retriever_for(config)
    matchers = {
        m.case.case_id: m
        for m in resolve(conversations.as_goldset(), reference_corpus(), retriever.corpus)
    }

    strategies = [args.strategy] if args.strategy else list(STRATEGIES)
    print(
        f"{len(conversations)} conversations, {conversations.turn_count} turns"
        + (f", generator={args.model}" if generator else ", retrieval only")
    )
    print(f"\n{'strategy':10}{'all turns':>11}{'turn 1':>9}{'follow-ups':>12}{'drop':>8}")

    reports = []
    for strategy in strategies:
        report = run_multiturn(
            conversations, matchers, retriever, strategy=strategy,
            generator=generator, top_k=args.k,
        )
        reports.append(report)
        drop = report.first_turn_recall - report.follow_up_recall
        print(
            f"{strategy:10}{report.recall_at_5:>10.1%}{report.first_turn_recall:>9.1%}"
            f"{report.follow_up_recall:>12.1%}{drop:>8.1%}"
        )

    best = max(reports, key=lambda r: r.recall_at_5)
    print(f"\nper-turn Recall@5 ({best.strategy}):")
    for index, value in best.recall_by_turn().items():
        print(f"  turn {index}  {value:.1%}")
    print(f"\nprompt tokens by turn (budget {MAX_PROMPT_TOKENS}):")
    for index, value in best.tokens_by_turn().items():
        print(f"  turn {index}  {value:.0f}")
    if best.over_budget:
        print(f"  OVER BUDGET: {len(best.over_budget)} turns")

    if generator:
        for report in reports:
            print(f"\n{report.strategy}: {len(report.incidents)} safety incident(s)")
            for result in report.incidents:
                for violation in result.safety_violations:
                    print(f"  [{result.turn_id}] {result.query}")
                    print(f"      {violation.name}: {violation.detail}")
    return 0
