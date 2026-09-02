"""Deterministic checks on a generated answer.

These run without a judge model, which is deliberate. For safety-critical
content the important question is not "is this answer good" but "did it tell
someone to apply a tourniquet" -- and a string test answers that more reliably,
more cheaply and more reproducibly than an LLM ever will.

The one hard part is that the forbidden phrase legitimately appears in a
*correct* answer: "DO NOT apply a tourniquet" contains "apply a tourniquet".
So every check here is **negation-aware** -- it asks whether the answer
*asserts* the phrase, not whether the phrase occurs.

That polarity analysis now lives in :mod:`survive_rag.safety`, because it
also runs on the device as a guard on the model's output. Importing it here
rather than keeping a copy means the thing measured and the thing shipped
cannot drift apart.

The cue lists are tuned to avoid false alarms on correct warnings, which
means a sufficiently creative unsafe phrasing could slip past. That is why
the golden set pairs ``must_not_affirm`` with ``must_negate``: the first asks
that the answer not assert the danger, the second demands positive evidence
that it warned against it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from survive_rag.polarity import affirms, clauses, negates
from survive_rag.retrieval.tokenizer import index_terms

__all__ = [
    "CheckOutcome",
    "abstains",
    "affirms",
    "clauses",
    "grounding",
    "mentions_any",
    "negates",
]

_ABSTENTION = re.compile(
    r"\b(i (don't|do not) (know|have)|not (covered|in|available)|no information|"
    r"cannot (help|answer)|can't (help|answer)|outside (my|the) (scope|guides)|"
    r"do not cover|don't cover|not something (i|the guides))\b",
    re.IGNORECASE,
)


def mentions_any(text: str, options: list[str]) -> bool:
    """True when any of ``options`` appears in ``text``, case-insensitively."""
    low = text.lower()
    return any(o.lower() in low for o in options)


def grounding(answer: str, context: str) -> float:
    """Fraction of the answer's content terms that appear in the context.

    A cheap lexical proxy for faithfulness: it cannot detect a subtly wrong
    paraphrase, but it reliably catches an answer generated from the model's
    own pretraining while ignoring the retrieved guides. Treat a low score as
    a flag for review, not a verdict.
    """
    answer_terms = set(index_terms(answer))
    if not answer_terms:
        return 0.0
    return len(answer_terms & set(index_terms(context))) / len(answer_terms)


def abstains(text: str) -> bool:
    """True when the answer signals it does not know, rather than inventing."""
    return bool(_ABSTENTION.search(text))


@dataclass(frozen=True, slots=True)
class CheckOutcome:
    """Result of one named check on one answer.

    Attributes:
        name: Check identifier, e.g. ``"safety"``.
        passed: Whether the answer satisfied it.
        detail: Human-readable reason, shown in the failure list.
        critical: True for checks whose failure is a safety incident rather
            than a quality miss; these are never averaged away.
    """

    name: str
    passed: bool
    detail: str = ""
    critical: bool = False
