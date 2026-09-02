"""Deciding what kind of question this is, before spending a model on it.

Three outcomes, and only one of them costs a generation pass:

    ``CAPABILITY`` -- the user is asking what the app is or what it can do.
      Answered from a fixed description, instantly, with no retrieval and no
      model. This is almost always someone's first message, so it is also the
      app's first impression.
    ``ANSWER``     -- the corpus can help. Retrieve and generate.
    ``DECLINE``    -- the corpus cannot help. Say so, and say what it *can*
      do, rather than letting a 2B model improvise survival advice about
      mutual funds.

The decision uses two signals, because one is not enough. Measured over 382
golden-set cases:

    group                cosine range     bridge words
    in-corpus English    0.304 - 0.70     no
    in-corpus Hinglish   0.247 - 0.40     yes, 23 of 28
    capability           0.191 - 0.358    no
    out-of-corpus        0.085 - 0.224    no

Two consequences drive the logic below.

**Capability questions cannot be separated by confidence** -- they straddle the
whole range. They are matched by pattern instead, and vetoed only by a *high*
confidence, so "what can you do about a snake bite" stays an emergency.

**Romanised Hindi cannot be trusted to the cosine.** Embedding models are
trained on Devanagari, so a real Hinglish emergency scores 0.247 where an
English one scores 0.50, leaving almost no margin above the out-of-corpus
ceiling of 0.224. But those queries carry *bridge words* -- tokens in the
expansion table that appear nowhere in the corpus, like ``khoon`` or
``saanp``. That table is India-emergency vocabulary and nothing else, so its
presence is direct evidence the question is in domain. It is used as a floor
that the cosine cannot veto.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

CAPABILITY, ANSWER, DECLINE = "capability", "answer", "decline"

# Chosen by `evals route --calibrate` over 382 cases as the highest threshold
# with ZERO false declines. It is not the most accurate setting -- 0.28 scores
# better overall -- but 0.28 turns away one real query, and turning away
# someone in an emergency is the worst thing this app can do short of giving
# dangerous advice.
#
# At 0.25 it declines 63% of out-of-corpus queries. The remaining 37% overlap
# irreducibly with in-corpus Hinglish (0.247-0.40), so no single threshold
# separates them; contrast signals (margin, z-score, ratio) were measured and
# separate no better. Those are caught by the generator instead, which is
# instructed to refuse when the reference material does not answer the
# question -- see `survive_rag.generation.prompt`.
ANSWER_THRESHOLD = 0.25

# Above this, a capability-shaped query is treated as a real question. Every
# genuine capability query measured stays below 0.36; "what can you do about a
# snake bite" scores 0.62.
CAPABILITY_VETO = 0.45

# A capability question is short and about the app. Anchored where possible so
# a real emergency does not match by accident.
_CAPABILITY_PATTERNS: tuple[re.Pattern[str], ...] = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        r"^(hi|hello|hey|yo|namaste|namaskar|salaam|hola)\b[\s!.?]*$",
        r"^help[\s!.?]*$",
        r"^(who|what) (are|r) (you|u)\b",
        r"^(tum|aap|tu) kaun (ho|hai|hain)\b",
        r"^what('?s| is)? this( app| bot| thing)?[\s!.?]*$",
        r"\bwhat can (you|u|this app|this) do\b",
        r"\bhow can (you|u|this app|this) help\b",
        r"\bwhat do you do\b",
        r"\bwhat (topics|things|questions).{0,20}(cover|ask|help|answer)\b",
        r"\b(aap|tum|tu) kya kar sakte? (ho|hai|hain)\b",
        r"^kya kar sakte? (ho|hai|hain)\b",
        r"\byeh kya hai\b",
        r"\bhow (do|does) (you|this) work\b",
    )
)


@dataclass(frozen=True, slots=True)
class Signals:
    """Everything the router needs to know about a query.

    Attributes:
        confidence: Top retrieval cosine. 0.0 when no dense index exists.
        has_bridge_terms: True when the query uses romanised-Hindi vocabulary
            that maps into the corpus -- evidence of domain independent of
            the embedding, which cannot read transliteration.
    """

    confidence: float = 0.0
    has_bridge_terms: bool = False


@dataclass(frozen=True, slots=True)
class Route:
    """The routing decision for one query.

    Attributes:
        intent: ``capability``, ``answer`` or ``decline``.
        confidence: The cosine this decision was made on, for logs and reports.
        reason: Short human-readable explanation.
    """

    intent: str
    confidence: float
    reason: str

    @property
    def should_retrieve(self) -> bool:
        """True only when a generation pass is worth spending."""
        return self.intent == ANSWER


def looks_like_capability_question(query: str) -> bool:
    """True when the query is about the app rather than about an emergency."""
    text = query.strip()
    if not text:
        return True
    return any(pattern.search(text) for pattern in _CAPABILITY_PATTERNS)


def route(
    query: str,
    signals: Signals,
    *,
    threshold: float = ANSWER_THRESHOLD,
    capability_veto: float = CAPABILITY_VETO,
) -> Route:
    """Decide how to handle one query.

    Args:
        query: Raw user text.
        signals: Retrieval evidence for this query.
        threshold: Confidence at or above which the corpus is judged able to
            help.
        capability_veto: Confidence at or above which a capability-shaped
            query is treated as a real question instead.

    Returns:
        The :class:`Route` to take.
    """
    confidence = signals.confidence
    if looks_like_capability_question(query) and confidence < capability_veto:
        return Route(CAPABILITY, confidence, "asks what the app does")
    if confidence >= threshold:
        return Route(ANSWER, confidence, "retrieval confident")
    if signals.has_bridge_terms:
        # The embedding cannot read romanised Hindi; the expansion table can,
        # and it contains nothing but India-emergency vocabulary.
        return Route(ANSWER, confidence, "romanised Hindi bridge vocabulary")
    return Route(DECLINE, confidence, f"confidence {confidence:.2f} below threshold")
