"""Catching an answer that contradicts its own reference material.

The generation eval measured a 2B model preserving prohibitions perfectly on
single-turn questions and failing three times in thirty-two conversational
turns -- always on a follow-up, always by dropping a "DO NOT" while copying
the rest of a chunk. A larger model would help; a larger model does not fit.

So the check runs at inference instead. It is pure string work, microseconds,
no model, and it knows something the model does not reliably use: exactly
which prohibitions were in the context it was given. If the answer asserts
something its own reference material forbids, the answer is wrong and can be
replaced by the guide text, which is never wrong.

The polarity analysis it rests on is in :mod:`survive_rag.polarity`. Both live
in the shipped package rather than the eval harness because they are runtime
code now; the harness imports them, so the thing measured and the thing
shipped cannot drift.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .polarity import affirms, clauses, negates

# "DO NOT apply a tourniquet." -> "apply a tourniquet". Anchored to the START
# of a clause so that a claim about efficacy -- "tourniquets do not stop venom
# spread" -- is not read as an instruction not to stop venom spread.
_PROHIBITION = re.compile(
    r"^(?:do not|do  not|don't|never)\s+([a-z][a-z' ]{4,50})", re.IGNORECASE
)

# Fragments ending in a dangling function word make unmatchable needles.
_DANGLING = re.compile(r"\b(?:the|a|an|to|of|it|you|your|are|is|and|or|for|in|on)$")

_MARKUP = re.compile(r"[*_`#\[\]]")
MAX_ACTION_WORDS = 5


def forbidden_actions(context: str) -> list[str]:
    """Extract the actions the reference material tells the reader not to do.

    Args:
        context: The reference block the model was given.

    Returns:
        Lowercased action phrases such as ``"apply a tourniquet"``, trimmed to
        a few words so a long sentence does not become an unmatchable needle.
    """
    found: list[str] = []
    seen: set[str] = set()
    for clause in clauses(_MARKUP.sub("", context)):
        match = _PROHIBITION.match(clause.lstrip("-•* "))
        if not match:
            continue
        words = match.group(1).strip().split()[:MAX_ACTION_WORDS]
        while words and _DANGLING.search(words[-1]):
            words.pop()
        action = " ".join(words).lower().strip()
        if len(action) > 4 and action not in seen:
            seen.add(action)
            found.append(action)
    return found


def missing_warnings(answer: str, context: str) -> list[str]:
    """Prohibitions in the context that the answer neither states nor denies.

    A different failure from :func:`check_answer_against_context`, and the one
    actually observed in conversation: the model does not recommend the
    dangerous thing, it forgets to warn against it while summarising the rest
    of the chunk -- three times in thirty-two turns, always on a follow-up.
    Blocking is the wrong response to an omission, so the caller appends the
    missing warning instead.

    Args:
        answer: What the model produced.
        context: The reference material it was given.

    Returns:
        Action phrases the context forbids and the answer never mentions.
    """
    low = answer.lower()
    return [
        action
        for action in forbidden_actions(context)
        if action not in low and not negates(answer, action)
    ]


@dataclass(frozen=True, slots=True)
class Violation:
    """One thing the answer asserted that its own context forbids."""

    action: str

    def __str__(self) -> str:
        """Human-readable form for logs."""
        return f"asserted {self.action!r}, which the guides forbid"


def check_answer_against_context(answer: str, context: str) -> list[Violation]:
    """Find assertions in ``answer`` that contradict ``context``.

    Args:
        answer: What the model produced.
        context: The reference material it was given.

    Returns:
        One :class:`Violation` per contradicted prohibition; empty is a pass.
    """
    return [
        Violation(action)
        for action in forbidden_actions(context)
        if affirms(answer, action)
    ]


def is_safe(answer: str, context: str) -> bool:
    """True when the answer contradicts none of its context's prohibitions."""
    return not check_answer_against_context(answer, context)


BLOCK, AUGMENT, PASS = "block", "augment", "pass"


@dataclass(frozen=True, slots=True)
class Guard:
    """What to do with an answer before showing it.

    Attributes:
        action: ``block``, ``augment`` or ``pass``.
        violations: Prohibitions the answer contradicted outright.
        omissions: Prohibitions it failed to carry over.
    """

    action: str
    violations: tuple[Violation, ...] = ()
    omissions: tuple[str, ...] = ()


def guard(answer: str, context: str, *, max_omissions: int = 2) -> Guard:
    """Decide whether an answer is safe to show as-is.

    Two failure modes, two responses. An answer that *asserts* something its
    own material forbids is wrong and must not be shown; one that merely
    *omits* a warning is incomplete, and the warning is appended verbatim.

    Args:
        answer: What the model produced.
        context: The reference material it was given.
        max_omissions: Cap on appended warnings, so a chunk dense with
            prohibitions does not bury the actual answer.

    Returns:
        The :class:`Guard` decision.
    """
    violations = check_answer_against_context(answer, context)
    if violations:
        return Guard(BLOCK, tuple(violations))
    omissions = missing_warnings(answer, context)[:max_omissions]
    return Guard(AUGMENT, omissions=tuple(omissions)) if omissions else Guard(PASS)
