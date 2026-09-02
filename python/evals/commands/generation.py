"""Generation commands: score answers, and measure how fast they arrive."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from survive_rag.config import RECOMMENDED
from survive_rag.generation.prompt import ContextChunk, build_chat_prompt

from ..harness.context import profile_fill, render_fill
from ..harness.gen_cases import load_genset
from ..harness.gen_report import render as render_generation
from ..harness.gen_runner import run_generation
from ..harness.goldset import load_goldset
from ..harness.lab import goldset_path, retriever_for
from ..harness.performance import PerformanceReport, time_generation


def _config(args: argparse.Namespace):
    """Build the retrieval config a generation command should run under."""
    return RECOMMENDED.with_(
        granularity=args.granularity,
        use_dense_leg=not args.no_dense,
        embed_model=args.embed_model,
    )


def cmd_gen_eval(args: argparse.Namespace) -> int:
    """Run the generation eval: retrieve, prompt, generate, check."""
    from ..generators.generator import load_generator

    genset = load_genset(args.genset or goldset_path("generation"))
    retriever = retriever_for(_config(args))
    report = run_generation(genset, retriever, load_generator(args.model), top_k=args.k)
    print(render_generation(report))

    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {
                    "generator": report.generator,
                    "pass_rate": report.pass_rate,
                    "safety": report.rate("safety"),
                    "negation": report.rate("negation"),
                    "incidents": [r.case.case_id for r in report.incidents],
                    "by_slice": report.by_slice(),
                },
                indent=1,
            ),
            encoding="utf-8",
        )
    return 0 if (report.pass_rate >= 0.85 or not args.strict) else 1


def cmd_perf(args: argparse.Namespace) -> int:
    """Measure time-to-first-token, decode rate and total latency."""
    from ..generators.generator import load_generator

    genset = load_genset(goldset_path("generation"))
    retriever = retriever_for(_config(args))
    generator = load_generator(args.model)
    queries = [c.query for c in genset.cases][: args.n]

    report = PerformanceReport(generator=getattr(generator, "name", args.model))
    for query in queries:
        hits = retriever.retrieve(query, top_k=args.k)
        chunks = [
            ContextChunk(h.citation, h.unit.topic, h.unit.heading_path, h.context)
            for h in hits
        ]
        _, timing = time_generation(generator, build_chat_prompt(chunks, [], query))
        report.timings.append(timing)

    print(f"performance -- {report.generator}, {len(queries)} queries, top_k={args.k}")
    for name, value in report.summary().items():
        print(f"  {name:24} {value:8.1f}")
    return 0


def cmd_context(args: argparse.Namespace) -> int:
    """Report how much of the context window each ``top_k`` actually uses."""
    config = _config(args)
    retriever = retriever_for(config)
    queries = [c.query for c in load_goldset(goldset_path("retrieval")).cases][: args.n]
    profiles = [
        profile_fill(retriever, queries, top_k=k, chunk_chars=args.chunk_chars)
        for k in args.top_k
    ]
    print(render_fill(profiles))
    return 0
