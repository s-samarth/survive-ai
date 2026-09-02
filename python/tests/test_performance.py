"""Latency measurement and context-window accounting."""

from __future__ import annotations

from evals.harness.context import FillProfile, render_fill
from evals.harness.performance import PerformanceReport, Timing, time_generation
from survive_rag.generation.prompt import MAX_PROMPT_TOKENS


class _Streaming:
    """A generator that yields pieces, so TTFT is observable."""

    name = "streaming"

    def generate(self, prompt: str) -> str:
        """Return the whole answer at once."""
        return "one two three"

    def stream(self, prompt: str):
        """Yield the answer in pieces."""
        yield from ("one ", "two ", "three")


class _Blocking:
    """A generator with no stream method, the fallback path."""

    name = "blocking"

    def generate(self, prompt: str) -> str:
        """Return the whole answer at once."""
        return "one two three"


def test_decode_rate_excludes_prompt_processing() -> None:
    """Tokens per second must not be diluted by time spent before the first token."""
    timing = Timing(prompt_tokens=900, output_tokens=100, ttft_seconds=2.0, total_seconds=12.0)
    assert timing.decode_tokens_per_second == 10.0
    assert timing.end_to_end_tokens_per_second < timing.decode_tokens_per_second


def test_decode_rate_is_zero_when_no_time_elapsed_after_the_first_token() -> None:
    """Guards against a divide-by-zero on a one-token answer."""
    timing = Timing(prompt_tokens=10, output_tokens=1, ttft_seconds=1.0, total_seconds=1.0)
    assert timing.decode_tokens_per_second == 0.0


def test_streaming_measures_a_real_time_to_first_token() -> None:
    """With a stream, TTFT must be strictly less than the total."""
    answer, timing = time_generation(_Streaming(), "prompt")
    assert answer == "one two three"
    assert timing.ttft_seconds <= timing.total_seconds


def test_blocking_generator_falls_back_to_total_time() -> None:
    """Without a stream, TTFT is unmeasurable and must not be invented."""
    _, timing = time_generation(_Blocking(), "prompt")
    assert timing.ttft_seconds == timing.total_seconds


def test_report_summarises_median_and_tail() -> None:
    """The p90 is what a user complains about; it must be reported separately."""
    report = PerformanceReport(generator="t")
    report.timings.extend(
        Timing(prompt_tokens=900, output_tokens=100, ttft_seconds=t, total_seconds=t + 10.0)
        for t in (1.0, 2.0, 3.0, 9.0)
    )
    summary = report.summary()
    assert summary["median_ttft_s"] == 2.5
    assert summary["p90_ttft_s"] >= summary["median_ttft_s"]


def test_empty_report_does_not_divide_by_zero() -> None:
    """A run that produced nothing must summarise to zeros, not crash."""
    assert PerformanceReport(generator="t").summary()["median_ttft_s"] == 0.0


def test_fill_profile_renders_a_table() -> None:
    """The context report is read by a human; it must state the budget."""
    text = render_fill(
        [
            FillProfile(
                top_k=4,
                median_prompt_tokens=880,
                max_prompt_tokens=960,
                budget_used=0.61,
                truncated_fraction=0.92,
                median_chars_dropped=300,
                over_budget=0,
            )
        ]
    )
    assert str(MAX_PROMPT_TOKENS) in text
    assert "top_k" in text and "truncated" in text
