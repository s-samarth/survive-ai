"""Console and Markdown rendering of a sweep."""

from __future__ import annotations

from .runner import ConfigReport

HEADLINE: tuple[tuple[str, str], ...] = (
    ("recall_at_5", "Recall@5"),
    ("recall_at_20", "Recall@20"),
    ("hit_at_1", "Hit@1"),
    ("mrr", "MRR"),
    ("ndcg_at_5", "nDCG@5"),
    ("precision_at_5", "P@5"),
    ("topic_hit", "Topic@1"),
)

# Release gates. Recall@5 is the hard one: below it, the generator is being
# asked to answer from context that does not contain the answer.
TARGETS: dict[str, float] = {
    "recall_at_5": 0.90,
    "recall_at_20": 0.97,
    "mrr": 0.75,
    "ndcg_at_5": 0.75,
}


def _cell(value: float, width: int = 8) -> str:
    """Format a metric as a fixed-width percentage."""
    return f"{value * 100:>{width}.1f}"


def scorecard(reports: list[ConfigReport]) -> str:
    """Render the config-comparison table as plain text.

    Args:
        reports: One report per configuration, in display order.

    Returns:
        A monospaced table, one row per configuration.
    """
    name_w = max(len(r.config.name) for r in reports) + 2
    header = f"{'config':<{name_w}}" + "".join(f"{label:>9}" for _, label in HEADLINE)
    header += f"{'Abstain':>9}{'sec':>7}"
    lines = [header, "-" * len(header)]
    for report in reports:
        row = f"{report.config.name:<{name_w}}"
        row += "".join(_cell(report.overall.get(key, 0.0), 9) for key, _ in HEADLINE)
        row += _cell(report.abstention, 9) + f"{report.seconds:>7.1f}"
        lines.append(row)
    return "\n".join(lines)


def slice_table(report: ConfigReport) -> str:
    """Render per-slice Recall@5 and nDCG@5 for one configuration.

    Slices are the point of the golden set: a headline Recall@5 of 0.90 that
    hides a Hinglish slice at 0.55 is a failure disguised as a pass.
    """
    if not report.by_slice:
        return "(no slices)"
    width = max(len(n) for n in report.by_slice) + 2
    lines = [
        f"{'slice':<{width}}{'n':>5}{'Recall@5':>10}{'nDCG@5':>9}{'Hit@1':>8}",
        "-" * (width + 32),
    ]
    for name in sorted(report.by_slice, key=lambda n: report.by_slice[n]["recall_at_5"]):
        stats = report.by_slice[name]
        count = sum(1 for r in report.results if name in r.slices)
        lines.append(
            f"{name:<{width}}{count:>5}"
            f"{_cell(stats['recall_at_5'], 10)}"
            f"{_cell(stats['ndcg_at_5'], 9)}"
            f"{_cell(stats['hit_at_1'], 8)}"
        )
    return "\n".join(lines)


def gate_status(report: ConfigReport) -> tuple[bool, list[str]]:
    """Check a report against :data:`TARGETS`.

    Returns:
        ``(passed, messages)`` where each message names one metric, its value
        and its target.
    """
    messages, passed = [], True
    for key, target in TARGETS.items():
        value = report.overall.get(key, 0.0)
        ok = value >= target
        passed = passed and ok
        messages.append(
            f"{'PASS' if ok else 'FAIL'}  {key:<14} {value * 100:5.1f}%  "
            f"(target {target * 100:.0f}%)"
        )
    return passed, messages


def failure_list(report: ConfigReport, limit: int = 25) -> str:
    """Render the cases that missed entirely -- the work list for the next fix."""
    failures = report.failures
    if not failures:
        return "No Recall@5 failures."
    lines = [f"{len(failures)} cases with no gold chunk in the top 5:"]
    for result in failures[:limit]:
        tags = ",".join(result.slices)
        top = result.ranked[0].split("#", 1)[0] if result.ranked else "-"
        lines.append(
            f"  {result.case_id:<8} [{tags}] {result.query!r}  -> top hit from {top!r}"
        )
    if len(failures) > limit:
        lines.append(f"  ... and {len(failures) - limit} more")
    return "\n".join(lines)


def full_text_report(reports: list[ConfigReport]) -> str:
    """Assemble the complete console report for a sweep."""
    best = reports[0]
    passed, gates = gate_status(best)
    sections = [
        "SCORECARD",
        scorecard(reports),
        "",
        f"RELEASE GATES  ({best.config.name})  ->  {'PASS' if passed else 'FAIL'}",
        *gates,
        "",
        f"SLICES  ({best.config.name})",
        slice_table(best),
        "",
        f"FAILURES  ({best.config.name})",
        failure_list(best),
    ]
    return "\n".join(sections)
