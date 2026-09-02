"""Routing command: score the answer/decline/capability decision, and calibrate it."""

from __future__ import annotations

import argparse

from survive_rag.config import RECOMMENDED
from survive_rag.routing import ANSWER_THRESHOLD, CAPABILITY_VETO

from ..harness.goldset import load_goldset
from ..harness.lab import goldset_path, retriever_for
from ..harness.routing_eval import render, run_routing

CALIBRATION_STEPS = [0.15, 0.18, 0.20, 0.22, 0.235, 0.25, 0.28, 0.30, 0.35]


def cmd_route(args: argparse.Namespace) -> int:
    """Score routing, or sweep the threshold to choose one."""
    goldset = load_goldset(goldset_path("retrieval"))
    retriever = retriever_for(RECOMMENDED)

    if not args.calibrate:
        report = run_routing(
            goldset,
            retriever,
            threshold=args.threshold,
            capability_veto=args.capability_veto,
        )
        print(render(report))
        return 1 if (report.false_declines and args.strict) else 0

    print(
        f"{'threshold':>10}{'accuracy':>10}{'answer':>9}{'decline':>9}"
        f"{'capability':>12}{'FALSE DECL':>12}{'false ans':>11}"
    )
    for threshold in CALIBRATION_STEPS:
        report = run_routing(
            goldset,
            retriever,
            threshold=threshold,
            capability_veto=args.capability_veto,
        )
        print(
            f"{threshold:>10.3f}{report.accuracy:>10.1%}"
            f"{report.rate_for('answer'):>9.1%}{report.rate_for('decline'):>9.1%}"
            f"{report.rate_for('capability'):>12.1%}"
            f"{len(report.false_declines):>12}{len(report.false_answers):>11}"
        )
    print(
        "\nPick the lowest threshold with zero false declines: turning away a real"
        "\nemergency is worse than letting the generation checks catch a stray answer."
    )
    return 0


def add_parser(sub: argparse._SubParsersAction) -> None:
    """Register the ``route`` subcommand."""
    parser = sub.add_parser("route", help="score answer/decline/capability routing")
    parser.add_argument("--threshold", type=float, default=ANSWER_THRESHOLD)
    parser.add_argument("--capability-veto", type=float, default=CAPABILITY_VETO)
    parser.add_argument(
        "--calibrate", action="store_true", help="sweep the answer threshold"
    )
    parser.add_argument(
        "--strict", action="store_true", help="exit non-zero on any false decline"
    )
    parser.set_defaults(func=cmd_route)
