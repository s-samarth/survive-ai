"""Python mirror of the app's Dart ``PromptBuilder``.

The generation eval is only worth running if it scores the prompt the app
actually sends, so this reproduces ``lib/utils/prompt_builder.dart`` exactly:
instruction-last layout, the same 700-character chunk cap, the same
``words x 1.3`` token estimate, and the same budget derived from the model's
context window.

Layout, top to bottom -- a 2B model attends most strongly to what is nearest
the generation point, so the instruction sits immediately before the question
rather than in a system preamble it will have forgotten by then:

    1. reference material from the guides
    2. conversation history
    3. instruction
    4. question
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# Mirrors kContextTokens/kMaxPromptTokens in lib/services/llm_service.dart:
# 2048 context - 512 reserved output - 84 safety.
CONTEXT_TOKENS = 2048
RESERVED_OUTPUT_TOKENS = 512
SAFETY_TOKENS = 84
MAX_PROMPT_TOKENS = CONTEXT_TOKENS - RESERVED_OUTPUT_TOKENS - SAFETY_TOKENS

# Appended only when reference material is present. Kept to one sentence:
# the instruction sits ~60 tokens from the generation point precisely because
# a 2B model stops attending to anything longer, so every clause added here
# competes with the ones already earning their place.
GROUNDING_CLAUSE = (
    " Use the reference information above to answer. If it does not answer the "
    "question, say plainly that your guides do not cover this — do not guess."
)

MAX_CHUNK_CHARS = 1400
MAX_HISTORY_TURNS = 4
# Held back from the reference block so history always has room.
HISTORY_RESERVE_TOKENS = 220

INSTRUCTION = (
    "You are Survive AI, an offline survival expert. "
    "Answer the question below directly and helpfully. "
    "If the user message is a greeting respond by telling about you and how you can help. "
    "Give the most critical action FIRST, then supporting steps. "
    "Be specific with distances, times, and quantities. "
    "Assume there is no network and no ambulance coming: give steps the user "
    "can do themselves right now. Mention 112 only as a second line, never as "
    "the whole answer. "
    "Do not add filler phrases. "
    "Take the user's request very seriously — never tell them it is only a warning "
    "or not serious. "
    "The user is in India: prefer Indian emergency numbers (112), Indian names for "
    "things, and advice that works with what an Indian household actually has."
)


def estimate_tokens(text: str) -> int:
    """Words x 1.3, rounded up -- the same heuristic the Dart side uses."""
    return math.ceil(len(text.split()) * 1.3)


@dataclass(frozen=True, slots=True)
class ContextChunk:
    """One retrieved passage as the prompt presents it to the model."""

    chunk_id: str
    topic: str
    heading_path: str
    body: str

    def render(self, chunk_chars: int = MAX_CHUNK_CHARS) -> str:
        """Format as ``[source]\\nbody``, truncated to the per-chunk cap."""
        source = f"{self.topic} > {self.heading_path}" if self.heading_path else self.topic
        body = self.body
        if len(body) > chunk_chars:
            body = body[: chunk_chars - 3] + "..."
        return f"[{source}]\n{body}"


def fit_context(
    chunks: list[ContextChunk], budget_tokens: int, chunk_chars: int = MAX_CHUNK_CHARS
) -> tuple[str, int]:
    """Fit as many chunks as the budget allows, best first.

    Chunks arrive ranked, so dropping from the end sheds the least relevant
    material. The alternative -- refusing the whole block when it does not fit
    -- fails silently and catastrophically: the model receives no reference
    material at all and answers from its own pretraining, which is exactly the
    failure the retrieval work exists to prevent. The first chunk is always
    kept, because an oversized best chunk is still better than nothing.

    Args:
        chunks: Retrieved reference material, best first.
        budget_tokens: Tokens available for the reference block.
        chunk_chars: Per-chunk character cap.

    Returns:
        ``(rendered_block, chunks_used)``.
    """
    kept: list[str] = []
    used = 0
    for chunk in chunks:
        rendered = chunk.render(chunk_chars)
        cost = estimate_tokens(rendered) + 2
        if kept and used + cost > budget_tokens:
            break
        kept.append(rendered)
        used += cost
    return "\n\n".join(kept), len(kept)


def build_context(chunks: list[ContextChunk], chunk_chars: int = MAX_CHUNK_CHARS) -> str:
    """Join every rendered chunk, ignoring any budget."""
    return "\n\n".join(c.render(chunk_chars) for c in chunks)


def build_history(history: list[tuple[str, str]], max_tokens: int) -> str:
    """Render recent turns as ``Q:``/``A:`` lines inside a token budget.

    Args:
        history: ``(role, content)`` pairs oldest first, excluding the current
            message. Role is ``"user"`` or anything else for the assistant.
        max_tokens: Budget remaining after context and instruction.

    Returns:
        The rendered block, or an empty string if nothing fits.
    """
    lines: list[str] = []
    tokens = 5
    for role, content in history[-MAX_HISTORY_TURNS:]:
        if len(content) > 400:
            content = content[:397] + "..."
        line = f"{'Q' if role == 'user' else 'A'}: {content}"
        cost = estimate_tokens(line)
        if tokens + cost > max_tokens:
            break
        lines.append(line)
        tokens += cost
    return "Previous exchange:\n" + "\n".join(lines) if lines else ""


def build_chat_prompt(
    chunks: list[ContextChunk],
    history: list[tuple[str, str]],
    user_message: str,
    *,
    chunk_chars: int = MAX_CHUNK_CHARS,
    history_reserve: int = HISTORY_RESERVE_TOKENS,
) -> str:
    """Build the full prompt for one RAG-augmented turn.

    Args:
        chunks: Retrieved reference material, best first.
        history: Prior turns, oldest first, excluding ``user_message``.
        user_message: What the user just asked.
        chunk_chars: Per-chunk character cap.
        history_reserve: Tokens held back for conversation history, so a long
            reference block cannot crowd out the thread of the conversation.

    Returns:
        Plain text with no turn markers -- flutter_gemma adds its own, and
        adding a second set corrupts the prompt.
    """
    parts: list[str] = []
    used = estimate_tokens(INSTRUCTION) + estimate_tokens(user_message) + 5

    reserve = history_reserve if history else 0
    available = MAX_PROMPT_TOKENS - used - reserve - 10
    context, _ = fit_context(chunks, available, chunk_chars) if available > 0 else ("", 0)
    if context:
        parts.append(f"Reference information from survival guides:\n{context}\n")
        used += estimate_tokens(context) + 6

    if history and MAX_PROMPT_TOKENS - used > 50:
        rendered = build_history(history, MAX_PROMPT_TOKENS - used)
        if rendered:
            parts.append(rendered + "\n")

    tail = INSTRUCTION + (GROUNDING_CLAUSE if context else "")
    parts.append(tail + "\n")
    parts.append(f"Question: {user_message}")
    return "\n".join(parts)
