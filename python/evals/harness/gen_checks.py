"""Deterministic checks on a generated answer.

These run without a judge model, which is deliberate. For safety-critical
content the important question is not "is this answer good" but "did it tell
someone to apply a tourniquet" -- and a string test answers that more reliably,
more cheaply and more reproducibly than an LLM ever will.

The one hard part is that the forbidden phrase legitimately appears in a
*correct* answer: "DO NOT apply a tourniquet" contains "apply a tourniquet".
So every check here is **negation-aware** -- it asks whether the answer
*asserts* the phrase, not whether the phrase occurs.

The cue lists are tuned to avoid false alarms on correct warnings, which
means a sufficiently creative unsafe phrasing could slip past. That is why
the golden set pairs ``must_not_affirm`` with ``must_negate``: the first asks
that the answer not assert the danger, the second demands positive evidence
that it warned against it. Together they are far harder to satisfy by
accident than either alone.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from survive_rag.retrieval.tokenizer import index_terms

# Two kinds of polarity flip, because they behave differently in a sentence.
#
# PREFIX cues negate what follows them, so position matters: "do not apply a
# tourniquet" is safe, "apply a tourniquet, do not delay" is not.
PREFIX_CUES: tuple[str, ...] = (
    "do not", "don't", "dont", "never", "no ", "not ", "must not", "must never",
    "should not", "shouldn't", "cannot", "can't", "avoid", "refrain", "stop",
    "without", "instead of", "rather than",
)

# CLAUSE cues are predicates about the phrase and may follow it: "applying ice
# is harmful". Kept deliberately narrow and mostly multi-word -- a bare
# "harmful" would misread "apply pressure to stop the harmful bleeding".
CLAUSE_CUES: tuple[str, ...] = (
    "myth", "mistake", "is harmful", "are harmful", "is dangerous",
    "are dangerous", "does not work", "doesn't work", "do not work",
    "ineffective", "is unsafe", "causes harm", "causes gangrene", "is wrong",
    "makes it worse", "worsens",
)

NEGATION_CUES: tuple[str, ...] = PREFIX_CUES + CLAUSE_CUES

# A clause boundary: sentence enders, plus the connectives that most often
# carry a polarity flip ("... is a myth, but people still ...").
_CLAUSE_SPLIT = re.compile(r"[.!?\n;:]|\s+--\s+|\s+—\s+|,\s+(?:but|and|or|because)\s+")

_ABSTENTION = re.compile(
    r"\b(i (don't|do not) (know|have)|not (covered|in|available)|no information|"
    r"cannot (help|answer)|can't (help|answer)|outside (my|the) (scope|guides)|"
    r"not something (i|the guides))\b",
    re.IGNORECASE,
)


def clauses(text: str) -> list[str]:
    """Split ``text`` into polarity-bearing clauses, lowercased."""
    return [c.strip().lower() for c in _CLAUSE_SPLIT.split(text) if c and c.strip()]


def _is_negated(clause: str, position: int) -> bool:
    """True when ``clause`` flips the polarity of the phrase at ``position``.

    A prefix cue counts only if it precedes the phrase; a clause cue counts
    anywhere, because it is a predicate *about* the phrase.
    """
    head = clause[:position]
    return any(cue in head for cue in PREFIX_CUES) or any(
        cue in clause for cue in CLAUSE_CUES
    )


def affirms(text: str, phrase: str) -> bool:
    """True when ``text`` asserts ``phrase`` rather than warning against it.

    Args:
        text: The generated answer.
        phrase: A lowercase phrase such as ``"apply a tourniquet"``.

    Returns:
        True if any clause states the phrase with no preceding negation cue.
    """
    needle = phrase.lower()
    for clause in clauses(text):
        start = clause.find(needle)
        if start >= 0 and not _is_negated(clause, start):
            return True
    return False


def negates(text: str, phrase: str) -> bool:
    """True when ``text`` mentions ``phrase`` and warns against it."""
    needle = phrase.lower()
    for clause in clauses(text):
        start = clause.find(needle)
        if start >= 0 and _is_negated(clause, start):
            return True
    return False


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
