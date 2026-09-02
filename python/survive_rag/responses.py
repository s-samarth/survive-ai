"""The two answers the app gives without running a model at all.

Both are deliberately fixed text. A capability question and a refusal are the
two places where a 2B model has the least to add and the most to get wrong,
and both are common enough to be worth answering instantly: "what can you do"
is usually someone's first message, and a refusal is what stands between the
user and improvised advice about a subject the guides do not cover.

Neither ends flat. A survival app that answers "I can't help with that" and
stops has failed a person who may be about to face something it *can* help
with, so both responses close by naming what is available.
"""

from __future__ import annotations

from .corpus.topics import TOPICS

CAPABILITY_ANSWER = """\
I'm Survive AI — an offline emergency guide for India. I work with no network, \
no SIM and no internet, so I keep working during floods, cyclones, blackouts \
and shutdowns.

Ask me what to do right now in an emergency and I'll give you the steps, drawn \
from guides written for Indian conditions — with a link to the exact paragraph \
so you can read it yourself.

I cover:
{topics}

You can type in English or Hinglish — "saanp ne kaata", "aag lag gayi", \
"khoon nikal raha hai" all work.

What's happening?"""

DECLINE_ANSWER = """\
That's outside what I can help with. I only answer from a set of Indian \
emergency and survival guides stored on this phone — I have no internet, and \
I won't guess at something this important.

What I can help with:
{topics}

If you're facing any of those, tell me what's happening and I'll give you the \
steps. In a life-threatening emergency, call **112**."""


def _topic_lines(limit: int | None = None) -> str:
    """Render the covered situations as a short bulleted list."""
    names = [t.display_name for t in TOPICS][:limit]
    return "\n".join(f"- {name}" for name in names)


def capability_answer(limit: int | None = None) -> str:
    """What the app is and what it can do; the answer to a first message.

    Args:
        limit: Show only the first N topics, for a narrow screen.

    Returns:
        Ready-to-display markdown.
    """
    return CAPABILITY_ANSWER.format(topics=_topic_lines(limit))


def decline_answer(limit: int | None = 8) -> str:
    """A refusal that still tells the user what is available.

    Args:
        limit: Show only the first N topics, so a refusal stays short.

    Returns:
        Ready-to-display markdown.
    """
    return DECLINE_ANSWER.format(topics=_topic_lines(limit))
