"""How much of the context window the prompt actually uses.

Two questions that sound the same and are not:

    * **how many chunks do we retrieve** -- a retrieval setting, ``top_k``.
    * **how much of them reaches the model** -- a prompt setting, the
      per-chunk character cap. A chunk that is retrieved and then truncated
      to its first 700 characters is not really in the context.

Both matter for latency as well as quality: the whole prompt is processed
before the first token appears, so every token spent here is time the user
spends looking at an empty screen.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from survive_rag.generation.prompt import (
    MAX_CHUNK_CHARS,
    MAX_PROMPT_TOKENS,
    ContextChunk,
    build_chat_prompt,
    estimate_tokens,
)


@dataclass(frozen=True, slots=True)
class FillProfile:
    """Context-window usage at one ``top_k``.

    Attributes:
        top_k: Chunks placed in the prompt.
        median_prompt_tokens: Typical prompt size.
        max_prompt_tokens: Largest prompt seen.
        budget_used: Median prompt as a fraction of the token budget.
        truncated_fraction: Share of chunks cut by the per-chunk cap.
        median_chars_dropped: Characters lost per truncated chunk.
        over_budget: Prompts that exceeded the budget outright.
    """

    top_k: int
    median_prompt_tokens: int
    max_prompt_tokens: int
    budget_used: float
    truncated_fraction: float
    median_chars_dropped: int
    over_budget: int


def _median(values: list[int]) -> int:
    """Median of a list of ints; zero when empty."""
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def profile_fill(
    retriever: Any,
    queries: list[str],
    *,
    top_k: int,
    chunk_chars: int = MAX_CHUNK_CHARS,
) -> FillProfile:
    """Measure prompt size and truncation across a set of real queries.

    Args:
        retriever: A configured retrieval pipeline.
        queries: Queries to profile; the golden sets are the right source.
        top_k: Chunks to place in the prompt.
        chunk_chars: Per-chunk character cap to simulate.

    Returns:
        A populated :class:`FillProfile`.
    """
    prompt_tokens: list[int] = []
    dropped: list[int] = []
    chunks_seen = truncated = 0

    for query in queries:
        hits = retriever.retrieve(query, top_k=top_k)
        rendered: list[ContextChunk] = []
        for hit in hits:
            chunks_seen += 1
            body = hit.context
            if len(body) > chunk_chars:
                truncated += 1
                dropped.append(len(body) - chunk_chars)
                body = body[: chunk_chars - 3] + "..."
            rendered.append(
                ContextChunk(hit.citation, hit.unit.topic, hit.unit.heading_path, body)
            )
        prompt_tokens.append(estimate_tokens(build_chat_prompt(rendered, [], query)))

    median = _median(prompt_tokens)
    return FillProfile(
        top_k=top_k,
        median_prompt_tokens=median,
        max_prompt_tokens=max(prompt_tokens, default=0),
        budget_used=median / MAX_PROMPT_TOKENS,
        truncated_fraction=truncated / chunks_seen if chunks_seen else 0.0,
        median_chars_dropped=_median(dropped),
        over_budget=sum(1 for t in prompt_tokens if t > MAX_PROMPT_TOKENS),
    )


def render_fill(profiles: list[FillProfile]) -> str:
    """Format a set of profiles as a console table."""
    lines = [
        (
            f"context window: {MAX_PROMPT_TOKENS} prompt tokens "
            f"(2048 total - 512 output - 84 safety)"
        ),
        "",
        (
            f"{'top_k':>6}{'median':>9}{'max':>7}{'budget':>9}"
            f"{'truncated':>11}{'chars lost':>12}{'over':>6}"
        ),
    ]
    for p in profiles:
        lines.append(
            f"{p.top_k:>6}{p.median_prompt_tokens:>9}{p.max_prompt_tokens:>7}"
            f"{p.budget_used:>8.0%}{p.truncated_fraction:>11.0%}"
            f"{p.median_chars_dropped:>12}{p.over_budget:>6}"
        )
    return "\n".join(lines)
