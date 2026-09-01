"""Command line entry point: ``python -m survive_rag <command>``."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import RetrievalConfig
from .corpus.loader import export_index, load_corpus, repo_root
from .evals.gen_cases import load_genset
from .evals.gen_report import render as render_generation
from .evals.gen_runner import run_generation
from .evals.goldset import load_goldset, validate
from .evals.report import full_text_report, gate_status
from .evals.report_html import write_html_report
from .evals.runner import run_sweep
from .retrieval.pipeline import Retriever
from .sweeps import BASELINE, SWEEPS


def _goldset_path(root: Path) -> Path:
    """Default location of the retrieval golden set."""
    return root / "python" / "goldset" / "retrieval.jsonl"


def _genset_path(root: Path) -> Path:
    """Default location of the generation golden set."""
    return root / "python" / "goldset" / "generation.jsonl"


def cmd_gen_eval(args: argparse.Namespace) -> int:
    """Run the generation eval: retrieve, prompt, generate, check."""
    from .generation.generator import load_generator

    root = repo_root()
    genset = load_genset(args.genset or _genset_path(root))
    config = RetrievalConfig(
        granularity=args.granularity,
        use_dense_leg=args.dense,
        embed_model=args.embed_model,
    )
    retriever = Retriever(corpus=load_corpus(cfg=config.chunking), config=config)
    generator = load_generator(args.model)
    report = run_generation(genset, retriever, generator, top_k=args.k)
    print(render_generation(report))
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {
                    "generator": report.generator,
                    "pass_rate": report.pass_rate,
                    "incidents": [r.case.case_id for r in report.incidents],
                    "by_slice": report.by_slice(),
                },
                indent=1,
            ),
            encoding="utf-8",
        )
    return 0 if not args.strict else (0 if report.pass_rate >= 0.85 else 1)


def cmd_chunk(args: argparse.Namespace) -> int:
    """Chunk the corpus and report its shape, optionally exporting the index."""
    corpus = load_corpus()
    tokens = sorted(c.token_estimate for c in corpus.children)
    print(f"{len(corpus.parents)} parents, {len(corpus.children)} children")
    print(
        f"child tokens  p10={tokens[len(tokens) // 10]}  "
        f"median={tokens[len(tokens) // 2]}  p90={tokens[len(tokens) * 9 // 10]}  "
        f"max={tokens[-1]}"
    )
    print(f"prohibitions  {sum(1 for c in corpus.children if c.is_prohibition)}")
    if args.export:
        path = export_index(corpus, Path(args.export))
        print(f"wrote {path} ({path.stat().st_size // 1024} KB)")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    """Retrieve for one query and print the ranked chunks."""
    retriever = Retriever(corpus=load_corpus(), config=RetrievalConfig())
    for hit in retriever.retrieve(args.text, top_k=args.k):
        print(f"{hit.rank}. [{hit.score:.3f}] {hit.unit.heading_path}")
        print(f"   {hit.citation}")
        print(f"   {' '.join(hit.unit.text.split())[:160]}")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    """Check the golden set against the live corpus."""
    root = repo_root()
    goldset = load_goldset(args.goldset or _goldset_path(root))
    problems = validate(goldset, load_corpus())
    print(f"{len(goldset)} cases, {len(problems)} problems")
    for problem in problems:
        print(f"  {problem}")
    return 1 if problems else 0


def cmd_eval(args: argparse.Namespace) -> int:
    """Run a sweep and write the reports."""
    root = repo_root()
    configs = SWEEPS[args.sweep]() if args.sweep else [BASELINE]
    reports = run_sweep(configs, args.goldset or _goldset_path(root), root)
    print(full_text_report(reports))

    if args.html:
        path = write_html_report(reports, Path(args.html))
        print(f"\nwrote {path}")
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                [
                    {
                        "config": r.config.to_json(),
                        "overall": r.overall,
                        "by_slice": r.by_slice,
                        "abstention": r.abstention,
                        "failures": [f.case_id for f in r.failures],
                    }
                    for r in reports
                ],
                indent=1,
            ),
            encoding="utf-8",
        )
        print(f"wrote {args.json}")

    passed, _ = gate_status(reports[0])
    return 0 if passed or not args.strict else 1


def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser."""
    parser = argparse.ArgumentParser(prog="survive-rag")
    sub = parser.add_subparsers(dest="command", required=True)

    chunk = sub.add_parser("chunk", help="chunk the corpus and report its shape")
    chunk.add_argument("--export", help="write the shipped index JSON here")
    chunk.set_defaults(func=cmd_chunk)

    query = sub.add_parser("query", help="retrieve for one query")
    query.add_argument("text")
    query.add_argument("-k", type=int, default=5)
    query.set_defaults(func=cmd_query)

    check = sub.add_parser("validate", help="check golden-set labels")
    check.add_argument("--goldset", type=Path)
    check.set_defaults(func=cmd_validate)

    evaluate = sub.add_parser("eval", help="run the retrieval eval")
    evaluate.add_argument("--sweep", choices=sorted(SWEEPS))
    evaluate.add_argument("--goldset", type=Path)
    evaluate.add_argument("--html", help="write an HTML report here")
    evaluate.add_argument("--json", help="write raw results here")
    evaluate.add_argument(
        "--strict", action="store_true", help="exit non-zero if gates fail"
    )
    evaluate.set_defaults(func=cmd_eval)

    gen = sub.add_parser("gen-eval", help="run the generation eval on one model")
    gen.add_argument("--model", default="qwen-1.5b", help="generator key")
    gen.add_argument("--genset", type=Path, help="generation golden set path")
    gen.add_argument("--granularity", default="passage", help="child|passage|parent")
    gen.add_argument("--dense", action="store_true", help="enable the dense leg")
    gen.add_argument("--embed-model", default="e5-base", help="embedding model key")
    gen.add_argument("-k", type=int, default=4, help="chunks placed in the prompt")
    gen.add_argument("--json", help="write a machine-readable summary here")
    gen.add_argument("--strict", action="store_true", help="exit non-zero on gate fail")
    gen.set_defaults(func=cmd_gen_eval)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and dispatch."""
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
