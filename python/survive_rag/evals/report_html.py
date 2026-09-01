"""Self-contained HTML report for a sweep.

No external assets: the report is opened from disk, mailed, or attached to a
CI run, so everything is inlined and it must render with no network.
"""

from __future__ import annotations

import html
from pathlib import Path

from .report import HEADLINE, TARGETS, gate_status
from .runner import ConfigReport

_CSS = """
:root{--bg:#fbfaf8;--fg:#1c1b19;--mut:#6b675f;--line:#e2ded6;--card:#fff;
--ok:#1a7f4b;--bad:#b3261e;--warn:#8a6100;--accent:#3d5a8a}
@media (prefers-color-scheme:dark){:root{--bg:#16151a;--fg:#eceaf3;--mut:#9c98a6;
--line:#2e2c36;--card:#1e1d24;--ok:#5ec98d;--bad:#ff8a80;--warn:#e0b050;
--accent:#8fb0e8}}
*{box-sizing:border-box}
body{margin:0;padding:2rem 1.25rem;background:var(--bg);color:var(--fg);
font:15px/1.55 ui-sans-serif,-apple-system,'Segoe UI',Roboto,sans-serif}
.wrap{max-width:1080px;margin:0 auto}h1{font-size:1.5rem;margin:0 0 .25rem}
h2{font-size:1.05rem;margin:2.5rem 0 .75rem;letter-spacing:.02em;
text-transform:uppercase;color:var(--mut);font-weight:600}
.sub{color:var(--mut);margin:0 0 1.5rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:1rem;margin-bottom:1rem}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{padding:.5rem .6rem;text-align:right;white-space:nowrap;
border-bottom:1px solid var(--line)}
th:first-child,td:first-child{text-align:left;font-family:ui-monospace,monospace}
thead th{color:var(--mut);font-weight:600;font-size:12px;
text-transform:uppercase;letter-spacing:.03em}
tbody tr:last-child td{border-bottom:none}
tr.best td{background:color-mix(in srgb,var(--accent) 10%,transparent)}
.ok{color:var(--ok);font-weight:600}.bad{color:var(--bad);font-weight:600}
.bar{height:6px;border-radius:3px;background:var(--line);position:relative;min-width:60px}
.bar span{position:absolute;inset:0 auto 0 0;border-radius:3px;background:var(--accent)}
.bar.low span{background:var(--bad)}.bar.mid span{background:var(--warn)}
.gate{display:flex;justify-content:space-between;padding:.4rem 0;
border-bottom:1px solid var(--line);font-family:ui-monospace,monospace;font-size:13px}
.gate:last-child{border-bottom:none}
.fail{font-family:ui-monospace,monospace;font-size:12.5px;padding:.35rem 0;
border-bottom:1px solid var(--line);color:var(--mut)}
.fail b{color:var(--fg);font-weight:600}
.pill{display:inline-block;padding:.1rem .45rem;border-radius:999px;
background:var(--line);font-size:11px;margin-right:.25rem}
"""


def _pct(value: float) -> str:
    """Percentage with one decimal."""
    return f"{value * 100:.1f}"


def _bar(value: float) -> str:
    """A proportional bar, coloured by how far below 0.9 the value sits."""
    tone = "low" if value < 0.7 else ("mid" if value < 0.9 else "")
    return f'<div class="bar {tone}"><span style="width:{value * 100:.0f}%"></span></div>'


def _scorecard(reports: list[ConfigReport]) -> str:
    """The config-comparison table."""
    head = "".join(f"<th>{label}</th>" for _, label in HEADLINE)
    rows = []
    best = max(range(len(reports)), key=lambda i: reports[i].overall.get("recall_at_5", 0))
    for i, report in enumerate(reports):
        cells = "".join(
            f"<td>{_pct(report.overall.get(key, 0.0))}</td>" for key, _ in HEADLINE
        )
        rows.append(
            f'<tr class="{"best" if i == best else ""}">'
            f"<td>{html.escape(report.config.name)}</td>{cells}"
            f"<td>{_pct(report.abstention)}</td>"
            f"<td>{report.n_children}</td><td>{report.seconds:.1f}s</td></tr>"
        )
    return (
        '<div class="card scroll"><table><thead><tr><th>config</th>'
        f"{head}<th>Abstain</th><th>chunks</th><th>time</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div>"
    )


def _gates(report: ConfigReport) -> str:
    """The pass/fail release gates for the leading configuration."""
    _, messages = gate_status(report)
    rows = []
    for key, target in TARGETS.items():
        value = report.overall.get(key, 0.0)
        ok = value >= target
        rows.append(
            f'<div class="gate"><span>{key}</span>'
            f'<span class="{"ok" if ok else "bad"}">{_pct(value)}% '
            f'/ {target * 100:.0f}% {"PASS" if ok else "FAIL"}</span></div>'
        )
    return f'<div class="card">{"".join(rows)}</div>'


def _slices(report: ConfigReport) -> str:
    """Per-slice table, worst slice first -- where the next fix should go."""
    rows = []
    order = sorted(report.by_slice, key=lambda n: report.by_slice[n]["recall_at_5"])
    for name in order:
        stats = report.by_slice[name]
        count = sum(1 for r in report.results if name in r.slices)
        rows.append(
            f"<tr><td>{html.escape(name)}</td><td>{count}</td>"
            f'<td>{_pct(stats["recall_at_5"])}</td>'
            f'<td style="width:180px">{_bar(stats["recall_at_5"])}</td>'
            f'<td>{_pct(stats["ndcg_at_5"])}</td>'
            f'<td>{_pct(stats["hit_at_1"])}</td>'
            f'<td>{_pct(stats["topic_hit"])}</td></tr>'
        )
    return (
        '<div class="card scroll"><table><thead><tr><th>slice</th><th>n</th>'
        "<th>Recall@5</th><th></th><th>nDCG@5</th><th>Hit@1</th><th>Topic@1</th>"
        f"</tr></thead><tbody>{''.join(rows)}</tbody></table></div>"
    )


def _failures(report: ConfigReport, limit: int = 40) -> str:
    """The cases that retrieved nothing relevant in the top 5."""
    failures = report.failures
    if not failures:
        return '<div class="card">No Recall@5 failures.</div>'
    rows = []
    for result in failures[:limit]:
        tags = "".join(f'<span class="pill">{html.escape(s)}</span>' for s in result.slices)
        top = html.escape(result.ranked[0]) if result.ranked else "(nothing retrieved)"
        rows.append(
            f'<div class="fail">{tags}<b>{html.escape(result.query)}</b>'
            f"<br>{html.escape(result.case_id)} &rarr; top hit {top}</div>"
        )
    more = (
        f'<div class="fail">... and {len(failures) - limit} more</div>'
        if len(failures) > limit
        else ""
    )
    return f'<div class="card">{"".join(rows)}{more}</div>'


def render_html(reports: list[ConfigReport]) -> str:
    """Render the whole sweep as a standalone HTML document."""
    best = reports[0]
    body = (
        f'<div class="wrap"><h1>Survive AI &mdash; retrieval eval</h1>'
        f'<p class="sub">{len(best.results)} in-corpus cases over '
        f"{best.n_children} chunks &middot; {len(reports)} configuration(s)</p>"
        f"<h2>Scorecard</h2>{_scorecard(reports)}"
        f"<h2>Release gates &mdash; {html.escape(best.config.name)}</h2>{_gates(best)}"
        f"<h2>By slice &mdash; {html.escape(best.config.name)}</h2>{_slices(best)}"
        f"<h2>Failures &mdash; {html.escape(best.config.name)}</h2>{_failures(best)}"
        "</div>"
    )
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        f"<title>Survive AI retrieval eval</title><style>{_CSS}</style></head>"
        f"<body>{body}</body></html>"
    )


def write_html_report(reports: list[ConfigReport], destination: Path) -> Path:
    """Write the HTML report, creating parent directories as needed."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(render_html(reports), encoding="utf-8")
    return destination
