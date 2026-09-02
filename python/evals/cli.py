"""Command line entry point for the lab: ``python -m evals <command>``.

The lab is deliberately a separate program from ``survive_rag``. That package
is the reference implementation of what ships; this one decides whether it is
good enough, and none of it belongs on a phone.

    validate    every golden set still matches the corpus
    eval        retrieval quality, optionally as a named sweep
    gen-eval    answer quality and safety, for one generator
    multiturn   whether the system holds the thread across a conversation
    perf        time to first token, decode rate, total latency
    context     how much of the context window the prompt actually uses
"""

from __future__ import annotations

import argparse
from pathlib import Path

from .commands.conversation import cmd_multiturn
from .commands.generation import cmd_context, cmd_gen_eval, cmd_perf
from .commands.retrieval import cmd_eval, cmd_validate
from .sweeps import SWEEPS


def _add_retrieval_flags(parser: argparse.ArgumentParser) -> None:
    """Flags shared by every command that builds a retriever."""
    parser.add_argument("--granularity", default="passage", help="child|passage|parent")
    parser.add_argument(
        "--no-dense", action="store_true", help="lexical legs only (no embeddings)"
    )
    parser.add_argument("--embed-model", default="e5-base", help="embedding model key")


def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser."""
    parser = argparse.ArgumentParser(prog="survive-evals", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("validate", help="check every golden set")
    check.set_defaults(func=cmd_validate)

    evaluate = sub.add_parser("eval", help="run the retrieval eval")
    evaluate.add_argument("--sweep", choices=sorted(SWEEPS), help="named A/B sweep")
    evaluate.add_argument("--dense", action="store_true", help="enable the dense leg")
    evaluate.add_argument("--html", help="write an HTML report here")
    evaluate.add_argument("--json", help="write a machine-readable summary here")
    evaluate.add_argument("--strict", action="store_true", help="exit non-zero on gate fail")
    evaluate.set_defaults(func=cmd_eval)

    gen = sub.add_parser("gen-eval", help="run the generation eval on one model")
    gen.add_argument("--model", default="gemma-2b", help="generator key")
    gen.add_argument("--genset", type=Path, help="generation golden set path")
    gen.add_argument("-k", type=int, default=4, help="chunks placed in the prompt")
    gen.add_argument("--json", help="write a machine-readable summary here")
    gen.add_argument("--strict", action="store_true", help="exit non-zero on gate fail")
    _add_retrieval_flags(gen)
    gen.set_defaults(func=cmd_gen_eval)

    multi = sub.add_parser("multiturn", help="score multi-turn conversations")
    multi.add_argument("--model", help="generator key; omit for retrieval only")
    multi.add_argument("--strategy", choices=["bare", "window", "anchored"])
    multi.add_argument("-k", type=int, default=4, help="chunks placed in the prompt")
    multi.add_argument("--no-dense", action="store_true", help="lexical legs only")
    multi.set_defaults(func=cmd_multiturn)

    perf = sub.add_parser("perf", help="measure latency and throughput")
    perf.add_argument("--model", default="gemma-2b", help="generator key")
    perf.add_argument("-k", type=int, default=4, help="chunks placed in the prompt")
    perf.add_argument("-n", type=int, default=12, help="queries to time")
    _add_retrieval_flags(perf)
    perf.set_defaults(func=cmd_perf)

    context = sub.add_parser("context", help="context-window utilisation by top_k")
    context.add_argument(
        "--top-k", type=int, nargs="+", default=[3, 4, 5, 6, 8, 10], help="values to profile"
    )
    context.add_argument("-n", type=int, default=80, help="queries to profile")
    context.add_argument("--chunk-chars", type=int, default=700, help="per-chunk cap")
    _add_retrieval_flags(context)
    context.set_defaults(func=cmd_context)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point for the console script."""
    args = build_parser().parse_args(argv)
    return int(args.func(args))
