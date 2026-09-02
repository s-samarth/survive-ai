"""Latency and throughput measurement for a generator.

Quality metrics say whether an answer is right. These say whether it arrives
in time to matter, which for this app is a product requirement rather than a
nicety: someone is looking at a snakebite. The three that decide the felt
experience are:

    * **time to first token** -- how long the screen stays empty. Dominated by
      prompt length, because the whole prompt must be processed before the
      first token appears, which is why context-window discipline is a
      latency question and not only a quality one.
    * **decode rate** -- tokens per second once output starts. Above roughly
      reading speed the user stops noticing.
    * **total time** -- when the answer is complete enough to act on.

Measured on a laptop, so the absolute numbers are optimistic against a 4 GB
Android phone; the *ratios* between models are what transfers.
"""

from __future__ import annotations

import statistics
import time
from dataclasses import dataclass, field
from typing import Any

from survive_rag.generation.prompt import estimate_tokens


@dataclass(frozen=True, slots=True)
class Timing:
    """One generation's latency profile."""

    prompt_tokens: int
    output_tokens: int
    ttft_seconds: float
    total_seconds: float

    @property
    def decode_tokens_per_second(self) -> float:
        """Output tokens per second after the first one appeared."""
        decode = self.total_seconds - self.ttft_seconds
        return self.output_tokens / decode if decode > 0 else 0.0

    @property
    def end_to_end_tokens_per_second(self) -> float:
        """Output tokens per second including prompt processing."""
        return self.output_tokens / self.total_seconds if self.total_seconds else 0.0


@dataclass(slots=True)
class PerformanceReport:
    """Aggregated timings for one generator."""

    generator: str
    timings: list[Timing] = field(default_factory=list)

    def _median(self, attribute: str) -> float:
        """Median of one attribute across all timings."""
        values = [getattr(t, attribute) for t in self.timings]
        return statistics.median(values) if values else 0.0

    def _p90(self, attribute: str) -> float:
        """90th percentile -- the tail a user actually complains about."""
        values = sorted(getattr(t, attribute) for t in self.timings)
        return values[int(0.9 * (len(values) - 1))] if values else 0.0

    def summary(self) -> dict[str, float]:
        """Every headline number, ready for a report row."""
        return {
            "median_ttft_s": self._median("ttft_seconds"),
            "p90_ttft_s": self._p90("ttft_seconds"),
            "median_total_s": self._median("total_seconds"),
            "p90_total_s": self._p90("total_seconds"),
            "median_decode_tps": self._median("decode_tokens_per_second"),
            "median_prompt_tokens": self._median("prompt_tokens"),
            "median_output_tokens": self._median("output_tokens"),
        }


def time_generation(generator: Any, prompt: str) -> tuple[str, Timing]:
    """Generate once, measuring time to first token and total time.

    Args:
        generator: Anything with ``generate``; a ``stream`` method is used
            when present, because time-to-first-token cannot be measured
            without it and falls back to total time otherwise.
        prompt: The full prompt to send.

    Returns:
        ``(answer, timing)``.
    """
    started = time.perf_counter()
    first_at: float | None = None
    if hasattr(generator, "stream"):
        pieces: list[str] = []
        for piece in generator.stream(prompt):
            if first_at is None and piece.strip():
                first_at = time.perf_counter()
            pieces.append(piece)
        answer = "".join(pieces)
    else:
        answer = generator.generate(prompt)
    total = time.perf_counter() - started

    return answer, Timing(
        prompt_tokens=estimate_tokens(prompt),
        output_tokens=estimate_tokens(answer),
        ttft_seconds=(first_at - started) if first_at else total,
        total_seconds=total,
    )
