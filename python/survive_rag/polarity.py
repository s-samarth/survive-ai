"""Does a piece of text assert something, or warn against it?

The distinction the whole safety layer rests on. A correct answer about
snakebite must *say* "apply a tourniquet" in order to forbid it, so asking
whether a phrase occurs is useless; the question is what the sentence does
with it.

Two kinds of polarity flip, because they behave differently in a sentence.
Prefix cues negate what follows them, so position matters. Clause cues are
predicates *about* a phrase and may follow it -- "applying ice is harmful" --
and are kept deliberately narrow and mostly multi-word, since a bare
"harmful" would misread "apply pressure to stop the harmful bleeding".
"""

from __future__ import annotations

import re

# Cues that negate what FOLLOWS them; position matters.
PREFIX_CUES: tuple[str, ...] = (
    "do not", "don't", "dont", "never", "no ", "not ", "must not", "must never",
    "should not", "shouldn't", "cannot", "can't", "avoid", "refrain", "stop",
    "without", "instead of", "rather than",
)

# Predicates ABOUT a phrase, which may follow it: "applying ice is harmful".
# Deliberately narrow and mostly multi-word -- a bare "harmful" would misread
# "apply pressure to stop the harmful bleeding".
CLAUSE_CUES: tuple[str, ...] = (
    "myth", "mistake", "is harmful", "are harmful", "is dangerous",
    "are dangerous", "does not work", "doesn't work", "do not work",
    "ineffective", "is unsafe", "causes harm", "causes gangrene", "is wrong",
    "makes it worse", "worsens",
)

_CLAUSE_SPLIT = re.compile(r"[.!?\n;:]|\s+--\s+|\s+—\s+|,\s+(?:but|and|or|because)\s+")

_CLAUSE_SPLIT = re.compile(r"[.!?\n;:]|\s+--\s+|\s+—\s+|,\s+(?:but|and|or|because)\s+")


def clauses(text: str) -> list[str]:
    """Split ``text`` into polarity-bearing clauses, lowercased."""
    return [c.strip().lower() for c in _CLAUSE_SPLIT.split(text) if c and c.strip()]


def _is_negated(clause: str, position: int) -> bool:
    """True when ``clause`` flips the polarity of the phrase at ``position``."""
    head = clause[:position]
    return any(cue in head for cue in PREFIX_CUES) or any(
        cue in clause for cue in CLAUSE_CUES
    )


def affirms(text: str, phrase: str) -> bool:
    """True when ``text`` asserts ``phrase`` rather than warning against it.

    A correct answer must *say* the dangerous phrase in order to forbid it, so
    a substring test would flag every safe answer. This asks about polarity.
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
