"""Run one or many retrieval configurations against the golden set."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path

from ..config import RetrievalConfig
from ..corpus.chunker import ChunkConfig
from ..corpus.loader import load_corpus
from ..corpus.models import Corpus
from ..retrieval.pipeline import Retriever
from .goldset import GoldSet, load_goldset, validate
from .metrics import METRIC_FIELDS, CaseResult, aggregate, evaluate_case
from .spans import resolve, unresolved

EVAL_DEPTH = 20


@dataclass(slots=True)
class ConfigReport:
    """Everything one configuration produced on one golden set.

    Attributes:
        config: The configuration that was run.
        results: Per-case metric values, in golden-set order.
        overall: Mean of each metric across all in-corpus cases.
        by_slice: Mean of each metric per slice tag.
        abstention: Fraction of out-of-corpus cases that returned nothing.
        n_children: Corpus size the run used, for context in the report.
        seconds: Wall-clock time for the whole sweep of this config.
    """

    config: RetrievalConfig
    results: list[CaseResult] = field(default_factory=list)
    overall: dict[str, float] = field(default_factory=dict)
    by_slice: dict[str, dict[str, float]] = field(default_factory=dict)
    abstention: float = 0.0
    n_children: int = 0
    seconds: float = 0.0

    @property
    def failures(self) -> list[CaseResult]:
        """Cases where no gold chunk reached the top 5, worst first."""
        return sorted(
            (r for r in self.results if r.failed), key=lambda r: (r.slices, r.case_id)
        )


def run_config(
    config: RetrievalConfig,
    goldset: GoldSet,
    corpus: Corpus | None = None,
    reference: Corpus | None = None,
) -> ConfigReport:
    """Evaluate a single configuration.

    Out-of-corpus cases are excluded from the quality means and reported
    separately as an abstention rate: averaging "found nothing, correctly" in
    with "found the right chunk" would inflate the headline number.

    Args:
        config: The retrieval setup to measure.
        goldset: Loaded and validated golden set.
        corpus: Pre-chunked corpus; rebuilt from ``config.chunking`` if omitted.
        reference: Corpus the golden set was labelled against. Defaults to
            ``corpus``; pass the default-chunking corpus when sweeping
            chunking policies so the same labels score every policy.

    Returns:
        A populated :class:`ConfigReport`.
    """
    corpus = corpus or load_corpus(cfg=config.chunking)
    retriever = Retriever(corpus=corpus, config=config)
    matchers = resolve(goldset, reference or corpus, corpus)
    started = time.perf_counter()

    results: list[CaseResult] = []
    abstained = out_corpus = 0
    for matcher in matchers:
        case = matcher.case
        ranked = retriever.retrieve_ids(case.query, top_k=EVAL_DEPTH)
        if case.is_out_of_corpus:
            out_corpus += 1
            abstained += 1 if not ranked else 0
            continue
        results.append(evaluate_case(ranked, matcher))

    by_slice: dict[str, dict[str, float]] = {}
    for name in goldset.slice_names():
        subset = [r for r in results if name in r.slices]
        if subset:
            by_slice[name] = aggregate(subset)

    return ConfigReport(
        config=config,
        results=results,
        overall=aggregate(results),
        by_slice=by_slice,
        abstention=abstained / out_corpus if out_corpus else 0.0,
        n_children=len(corpus),
        seconds=time.perf_counter() - started,
    )


def run_sweep(
    configs: list[RetrievalConfig], goldset_path: Path, root: Path | None = None
) -> list[ConfigReport]:
    """Evaluate several configurations, reusing corpora with identical chunking.

    Args:
        configs: Configurations to compare, in report order.
        goldset_path: Path to the golden-set JSONL.
        root: Repository root; discovered automatically when omitted.

    Returns:
        One :class:`ConfigReport` per configuration.

    Raises:
        ValueError: If the golden set does not validate against the
            reference corpus, or a label resolves to no source span.
    """
    goldset = load_goldset(goldset_path)
    # The golden set is authored against the DEFAULT chunking policy. That
    # corpus is the reference: it resolves every label to source line spans,
    # which every other policy is then scored against by overlap. Without
    # this, changing the chunker renames every id and the set scores zero.
    reference = load_corpus(root)
    problems = validate(goldset, reference)
    if problems:
        raise ValueError(
            "golden set does not match the reference corpus:\n  "
            + "\n  ".join(problems[:20])
        )
    stale = unresolved(resolve(goldset, reference))
    if stale:
        raise ValueError(
            f"{len(stale)} cases resolved to no source span: "
            + ", ".join(c.case_id for c in stale[:10])
        )

    cache: dict[object, Corpus] = {ChunkConfig(): reference}
    reports: list[ConfigReport] = []
    for config in configs:
        if config.chunking not in cache:
            cache[config.chunking] = load_corpus(root, cfg=config.chunking)
        reports.append(
            run_config(config, goldset, cache[config.chunking], reference)
        )

    return reports


def compare(reports: list[ConfigReport]) -> dict[str, list[float]]:
    """Pivot a sweep into ``metric -> one value per config`` for tabling."""
    return {
        name: [r.overall.get(name, 0.0) for r in reports] for name in METRIC_FIELDS
    }
