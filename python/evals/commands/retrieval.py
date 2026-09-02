"""Retrieval commands: validate the golden sets, and run the retrieval eval."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from survive_rag.corpus.loader import load_corpus

from ..harness.baselines import compare, load, regressions, render, save
from ..harness.gen_cases import load_genset
from ..harness.gen_cases import validate as validate_generation
from ..harness.goldset import load_goldset, validate
from ..harness.lab import goldset_path
from ..harness.multiturn import load_conversations
from ..harness.report import full_text_report, gate_status
from ..harness.report_html import write_html_report
from ..harness.runner import run_sweep
from ..sweeps import BASELINE, SWEEPS


def cmd_validate(args: argparse.Namespace) -> int:
    """Check every golden set against the live corpus.

    A guide edit that invalidates a hand-authored label must fail loudly here
    rather than quietly depressing every score in the next report.
    """
    corpus = load_corpus()
    topics = corpus.topics()
    problems: list[str] = []

    goldset = load_goldset(goldset_path("retrieval"))
    found = validate(goldset, corpus)
    print(f"retrieval   {len(goldset):4} cases, {len(found)} problems")
    problems += found

    genset = load_genset(goldset_path("generation"))
    found = validate_generation(genset, topics)
    print(f"generation  {len(genset):4} cases, {len(found)} problems")
    problems += found

    conversations = load_conversations(goldset_path("multiturn"))
    flattened = conversations.as_goldset()
    found = validate(flattened, corpus)
    print(
        f"multiturn   {len(conversations):4} conversations, "
        f"{conversations.turn_count} turns, {len(found)} problems"
    )
    problems += found

    for problem in problems:
        print(f"  {problem}")
    return 1 if problems else 0


def cmd_eval(args: argparse.Namespace) -> int:
    """Run the retrieval eval, optionally as a named sweep."""
    configs = SWEEPS[args.sweep]() if args.sweep else [BASELINE]
    if args.dense:
        configs = [c.with_(use_dense_leg=True) for c in configs]
    # Scoring the exported graph is the only way to know what the device gets:
    # a quantised export is a different model, not a packaging detail.
    overrides = {
        k: v
        for k, v in (
            ("embed_model", getattr(args, "embed_model", None)),
            ("embed_backend", getattr(args, "embed_backend", None)),
        )
        if v
    }
    if overrides:
        configs = [c.with_(**overrides) for c in configs]
    reports = run_sweep(configs, goldset_path("retrieval"))
    print(full_text_report(reports))

    if args.html:
        path = write_html_report(reports, Path(args.html))
        print(f"\nwrote {path}")
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                [
                    {"name": r.config.name, "units": r.n_units, **r.overall}
                    for r in reports
                ],
                indent=1,
            ),
            encoding="utf-8",
        )
    exit_code = _record(reports[0].overall | {"n_units": reports[0].n_units}, args)
    passed, _ = gate_status(reports[0])
    if args.strict and not passed:
        return 1
    return exit_code


def _record(metrics: dict, args) -> int:
    """Save or compare against the recorded baseline, per the flags given.

    Returns:
        1 when ``--check-regressions`` was asked for and something regressed.
    """
    name = getattr(args, "baseline", None) or "retrieval"
    if getattr(args, "save_baseline", False):
        print(f"\nwrote baseline {save(name, metrics)}")
        return 0
    recorded = load(name)
    if recorded is None:
        return 0
    deltas = compare(metrics, recorded)
    print()
    print(render(deltas, name))
    worse = regressions(deltas)
    return 1 if (worse and getattr(args, "check_regressions", False)) else 0
