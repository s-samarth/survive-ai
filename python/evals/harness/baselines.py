"""Recorded results, so a change can be shown to have helped or hurt.

A harness whose job is deciding what to ship needs memory. Absolute scores
answer "is this good enough"; only a diff against a recorded run answers "did
that change help", which is the question actually being asked most of the time.

Snapshots are plain JSON committed next to the golden sets, so a pull request
that moves a number moves a file, and the review shows both.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Below this, a difference is noise from a handful of cases rather than signal.
MATERIAL_DELTA = 0.005


def snapshot_dir() -> Path:
    """Directory holding recorded snapshots."""
    return Path(__file__).resolve().parents[1] / "baselines"


def snapshot_path(name: str) -> Path:
    """Path of one snapshot by bare name."""
    return snapshot_dir() / f"{name}.json"


def save(name: str, metrics: dict[str, Any]) -> Path:
    """Write a snapshot, sorted so diffs stay readable.

    Args:
        name: Snapshot name, e.g. ``"retrieval"``.
        metrics: Flat ``metric -> value`` mapping.

    Returns:
        The path written.
    """
    path = snapshot_path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(metrics, indent=1, sort_keys=True) + "\n", encoding="utf-8"
    )
    return path


def load(name: str) -> dict[str, Any] | None:
    """Read a snapshot, or None when none has been recorded yet."""
    path = snapshot_path(name)
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


@dataclass(frozen=True, slots=True)
class Delta:
    """One metric's movement against the recorded baseline."""

    metric: str
    before: float
    after: float

    @property
    def change(self) -> float:
        """Signed difference, after minus before."""
        return self.after - self.before

    @property
    def is_material(self) -> bool:
        """True when the movement is larger than run-to-run noise."""
        return abs(self.change) >= MATERIAL_DELTA

    @property
    def is_regression(self) -> bool:
        """True when a material movement went the wrong way."""
        return self.is_material and self.change < 0


def compare(current: dict[str, Any], baseline: dict[str, Any]) -> list[Delta]:
    """Diff a run against a baseline, ignoring metrics absent from either.

    Args:
        current: This run's metrics.
        baseline: The recorded metrics.

    Returns:
        One :class:`Delta` per shared numeric metric, worst movement first.
    """
    shared = [
        key
        for key in current
        if key in baseline
        and isinstance(current[key], int | float)
        and isinstance(baseline[key], int | float)
        and not isinstance(current[key], bool)
    ]
    deltas = [Delta(key, float(baseline[key]), float(current[key])) for key in shared]
    return sorted(deltas, key=lambda d: d.change)


def render(deltas: list[Delta], name: str) -> str:
    """Format a comparison for the console."""
    if not deltas:
        return f"no baseline recorded for {name!r}; run with --save to create one"
    lines = [f"vs recorded {name} baseline:", ""]
    for delta in deltas:
        if not delta.is_material:
            continue
        arrow = "WORSE" if delta.is_regression else "better"
        lines.append(
            f"  {delta.metric:22} {delta.before:7.3f} -> {delta.after:7.3f}  "
            f"{delta.change:+.3f}  {arrow}"
        )
    if len(lines) == 2:
        lines.append("  no material change")
    return "\n".join(lines)


def regressions(deltas: list[Delta]) -> list[Delta]:
    """Only the material movements that went the wrong way."""
    return [d for d in deltas if d.is_regression]
