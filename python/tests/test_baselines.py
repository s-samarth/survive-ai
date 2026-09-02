"""Recorded baselines: the harness's memory of what the numbers used to be."""

from __future__ import annotations

import json
from pathlib import Path

from evals.harness.baselines import (
    MATERIAL_DELTA,
    Delta,
    compare,
    regressions,
    render,
    snapshot_path,
)


def test_material_change_ignores_noise() -> None:
    """A handful of cases moving is not a result worth reporting."""
    tiny = Delta("recall_at_5", 0.888, 0.888 + MATERIAL_DELTA / 2)
    assert not tiny.is_material
    real = Delta("recall_at_5", 0.888, 0.888 + MATERIAL_DELTA * 2)
    assert real.is_material


def test_regression_is_a_material_move_in_the_wrong_direction() -> None:
    """An improvement must never be reported as a regression."""
    assert Delta("mrr", 0.75, 0.60).is_regression
    assert not Delta("mrr", 0.60, 0.75).is_regression
    assert not Delta("mrr", 0.75, 0.749).is_regression


def test_compare_ignores_metrics_missing_from_either_side() -> None:
    """Adding a metric must not crash the diff against an older snapshot."""
    deltas = compare({"a": 1.0, "new": 2.0}, {"a": 0.5, "gone": 9.0})
    assert [d.metric for d in deltas] == ["a"]


def test_compare_ignores_non_numeric_and_boolean_values() -> None:
    """A config name or a flag is not a metric to subtract."""
    deltas = compare(
        {"name": "x", "passed": True, "score": 1.0},
        {"name": "y", "passed": False, "score": 0.5},
    )
    assert [d.metric for d in deltas] == ["score"]


def test_compare_orders_worst_movement_first() -> None:
    """The reader should see what broke before what improved."""
    deltas = compare({"a": 1.0, "b": 0.0}, {"a": 0.0, "b": 1.0})
    assert deltas[0].metric == "b"


def test_regressions_filters_to_the_bad_news() -> None:
    """The CI gate acts on this list, so it must contain only real drops."""
    deltas = compare({"a": 0.5, "b": 0.9}, {"a": 0.9, "b": 0.5})
    assert [d.metric for d in regressions(deltas)] == ["a"]


def test_render_explains_an_absent_baseline() -> None:
    """A first run must say how to record one, not print an empty table."""
    assert "--save" in render([], "retrieval")


def test_render_says_so_when_nothing_moved() -> None:
    """Silence would read as a broken comparison."""
    text = render([Delta("a", 0.5, 0.5)], "retrieval")
    assert "no material change" in text


def test_recorded_retrieval_baseline_is_committed_and_sane() -> None:
    """The snapshot in the repo is what a regression is measured against."""
    path = snapshot_path("retrieval")
    assert path.is_file(), "commit a baseline so regressions are detectable"
    recorded = json.loads(Path(path).read_text(encoding="utf-8"))
    assert 0.0 <= recorded["recall_at_5"] <= 1.0
    assert recorded["recall_at_20"] >= recorded["recall_at_5"]
