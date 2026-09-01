"""End-to-end smoke test of the runner and both report renderers."""

from __future__ import annotations

from pathlib import Path

from survive_rag.config import RetrievalConfig
from survive_rag.evals.report import full_text_report, gate_status, scorecard
from survive_rag.evals.report_html import render_html
from survive_rag.evals.runner import run_sweep
from survive_rag.sweeps import SWEEPS


def _reports(root: Path, configs: list[RetrievalConfig]):
    return run_sweep(configs, root / "python" / "goldset" / "retrieval.jsonl", root)


def test_sweep_produces_one_report_per_config(root: Path) -> None:
    configs = [RetrievalConfig(name="a"), RetrievalConfig(name="b", rerank=False)]
    reports = _reports(root, configs)
    assert [r.config.name for r in reports] == ["a", "b"]
    assert all(r.results for r in reports)


def test_out_of_corpus_cases_are_excluded_from_quality_means(root: Path) -> None:
    """Averaging 'correctly found nothing' in would inflate the headline."""
    report = _reports(root, [RetrievalConfig()])[0]
    assert all("out_of_corpus" not in r.slices for r in report.results)
    assert 0.0 <= report.abstention <= 1.0


def test_metrics_are_in_range(root: Path) -> None:
    report = _reports(root, [RetrievalConfig()])[0]
    for value in report.overall.values():
        assert 0.0 <= value <= 1.0


def test_slices_are_reported_separately(root: Path) -> None:
    report = _reports(root, [RetrievalConfig()])[0]
    assert {"hinglish", "prohibition", "terse"} <= set(report.by_slice)


def test_text_report_renders(root: Path) -> None:
    text = full_text_report(_reports(root, [RetrievalConfig()]))
    assert "SCORECARD" in text and "RELEASE GATES" in text and "SLICES" in text


def test_html_report_is_self_contained(root: Path) -> None:
    """It is opened from disk and attached to CI runs; no network allowed."""
    html = render_html(_reports(root, [RetrievalConfig()]))
    assert html.startswith("<!doctype html>")
    assert "http://" not in html and "https://" not in html
    assert "<style>" in html and "src=" not in html


def test_gates_report_pass_or_fail(root: Path) -> None:
    passed, messages = gate_status(_reports(root, [RetrievalConfig()])[0])
    assert isinstance(passed, bool)
    assert len(messages) == 4


def test_every_named_sweep_is_runnable() -> None:
    for name, build in SWEEPS.items():
        configs = build()
        assert configs, name
        assert len({c.name for c in configs}) == len(configs), name


def test_scorecard_has_a_row_per_config(root: Path) -> None:
    reports = _reports(root, [RetrievalConfig(name="x"), RetrievalConfig(name="y")])
    lines = scorecard(reports).splitlines()
    assert len(lines) == 4
