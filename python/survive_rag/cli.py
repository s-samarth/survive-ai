"""Corpus tooling: inspect the chunking and build the shipped index artifact.

Everything here concerns the artifact the app consumes. The evaluation
commands live in ``python -m evals``, because measuring the system is not part
of the system.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from .config import RECOMMENDED
from .corpus.artifacts import build_artifacts
from .corpus.loader import export_index, load_corpus
from .retrieval.pipeline import Retriever


def _percentiles(values: list[int]) -> tuple[int, int, int]:
    """Return the p10, median and p90 of a sorted-able list."""
    ordered = sorted(values)
    n = len(ordered)
    return ordered[n // 10], ordered[n // 2], ordered[n * 9 // 10]


def cmd_chunk(args: argparse.Namespace) -> int:
    """Chunk the corpus and report its shape at all three granularities."""
    corpus = load_corpus(cfg=RECOMMENDED.chunking, passages=RECOMMENDED.passages)
    for label, units in (
        ("child", corpus.children),
        ("passage", corpus.passages),
        ("parent", corpus.parents),
    ):
        p10, median, p90 = _percentiles([u.token_estimate for u in units])
        print(f"{label:8} {len(units):4} units   p10={p10:4} median={median:4} p90={p90:4}")
    print(f"prohibitions {sum(1 for c in corpus.children if c.is_prohibition)}")
    if args.export:
        path = export_index(corpus, Path(args.export))
        print(f"wrote {path} ({path.stat().st_size // 1024} KB)")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    """Retrieve for one query and print the ranked units and their citations."""
    config = RECOMMENDED.with_(use_dense_leg=args.dense)
    corpus = load_corpus(cfg=config.chunking, passages=config.passages)
    retriever = Retriever(corpus=corpus, config=config)
    hits = retriever.retrieve(args.text, top_k=args.k)
    for hit in hits:
        print(f"{hit.rank}. [{hit.score:.3f}] {hit.unit.heading_path}")
        print(f"   cite -> {hit.citation}")
        print(f"   {' '.join(hit.unit.text.split())[:160]}")
    return 0


def cmd_pack(args: argparse.Namespace) -> int:
    """Build every artifact the app ships, from one corpus and one model."""
    written = build_artifacts(
        Path(args.tokenizer),
        Path(args.assets),
        Path(args.fixture),
        config=RECOMMENDED.with_(
            embed_model=args.embed_model, embed_backend=args.embed_backend
        ),
    )
    for name, path in written.items():
        print(f"{name:16} {path}  ({path.stat().st_size // 1024} KB)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser."""
    parser = argparse.ArgumentParser(prog="survive-rag", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    chunk = sub.add_parser("chunk", help="chunk the corpus and report its shape")
    chunk.add_argument("--export", help="write the index artifact to this path")
    chunk.set_defaults(func=cmd_chunk)

    query = sub.add_parser("query", help="retrieve for one query")
    query.add_argument("text", help="the query")
    query.add_argument("-k", type=int, default=5, help="results to show")
    query.add_argument("--dense", action="store_true", help="enable the dense leg")
    query.set_defaults(func=cmd_query)

    pack = sub.add_parser("pack", help="build every artifact the app ships")
    pack.add_argument(
        "--tokenizer", required=True, help="tokenizer.json for the embedding model"
    )
    pack.add_argument("--assets", default="../assets/index", help="app asset directory")
    pack.add_argument(
        "--fixture",
        default="../test/fixtures/tokenizer_cases.json",
        help="Dart tokeniser parity fixture",
    )
    pack.add_argument("--embed-model", default=RECOMMENDED.embed_model)
    pack.add_argument("--embed-backend", default="onnx", choices=("torch", "onnx"))
    pack.set_defaults(func=cmd_pack)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point for the console script."""
    args = build_parser().parse_args(argv)
    return int(args.func(args))
