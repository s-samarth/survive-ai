"""Building the retrieval query for a follow-up turn.

A conversation's second question rarely stands on its own. "Should I tie
something above it" carries no topic word at all, so retrieving on the turn
text alone searches for ``tie`` and ``above`` across eighteen guides and finds
whatever happens to share those words.

Three strategies, cheapest first. All of them are pure string work -- no model
call before retrieval, which matters because the user is waiting and the
device has one small model to spend time on, not two.

    ``bare``    -- the turn text only. The baseline, and what the app does now.
    ``window``  -- the turn text plus the previous user turns, so the topic
                   words from the opening question are still in the query.
    ``anchored``-- ``window``, but only the topic-bearing terms of the history
                   are carried, so a long conversation cannot drown the
                   current question in its own past.
"""

from __future__ import annotations

from .expansion import EXPANSION_TERMS
from .tokenizer import STOPWORDS, tokenize

BARE, WINDOW, ANCHORED = "bare", "window", "anchored"
DEFAULT_HISTORY_TURNS = 2
MAX_ANCHOR_TERMS = 8


def _user_turns(history: list[tuple[str, str]], limit: int) -> list[str]:
    """The most recent user messages, oldest first."""
    return [text for role, text in history if role == "user"][-limit:]


def _anchor_terms(texts: list[str], vocabulary: frozenset[str]) -> list[str]:
    """Topic-bearing terms from earlier turns, most recent first.

    A term earns its place by being either a word the corpus actually uses or
    a known bridge word; everything else is conversational filler that would
    only dilute the query.
    """
    seen: set[str] = set()
    picked: list[str] = []
    for text in reversed(texts):
        for token in tokenize(text):
            if token in STOPWORDS or token in seen:
                continue
            if token in vocabulary or token in EXPANSION_TERMS:
                seen.add(token)
                picked.append(token)
                if len(picked) >= MAX_ANCHOR_TERMS:
                    return picked
    return picked


def retrieval_query(
    turn: str,
    history: list[tuple[str, str]],
    *,
    strategy: str = ANCHORED,
    vocabulary: frozenset[str] = frozenset(),
    history_turns: int = DEFAULT_HISTORY_TURNS,
) -> str:
    """Build the text to retrieve on for one conversational turn.

    Args:
        turn: What the user just typed.
        history: ``(role, content)`` pairs oldest first, excluding ``turn``.
        strategy: ``bare``, ``window`` or ``anchored``.
        vocabulary: Corpus terms, used by ``anchored`` to tell topic words
            from filler. An empty set makes ``anchored`` behave like
            ``window`` over the expansion vocabulary alone.
        history_turns: How many previous user turns to consider.

    Returns:
        The query string to hand the retriever.

    Raises:
        ValueError: If ``strategy`` is not one of the three.
    """
    if strategy == BARE:
        return turn
    previous = _user_turns(history, history_turns)
    if not previous:
        return turn
    if strategy == WINDOW:
        return " ".join([*previous, turn])
    if strategy == ANCHORED:
        anchors = _anchor_terms(previous, vocabulary)
        return " ".join([turn, *anchors]) if anchors else turn
    raise ValueError(f"unknown conversation strategy {strategy!r}")
