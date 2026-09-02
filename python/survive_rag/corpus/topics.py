"""The 18 India situations -- mirror of ``lib/models/doc_topic.dart``.

This must stay in lockstep with the Dart enum: the Python side owns chunking
and evaluation, the Dart side owns runtime lookup, and a divergence in topic
keys silently breaks every topic filter. ``tests/test_corpus.py`` asserts the
two lists match.
"""

from __future__ import annotations

from dataclasses import dataclass

GUIDES_DIRNAME = "docs/survival_guides"


@dataclass(frozen=True, slots=True)
class Topic:
    """One guide: its stable key, display name, and one-line scope summary."""

    key: str
    display_name: str
    summary: str

    @property
    def filename(self) -> str:
        """Markdown filename for this topic."""
        return f"{self.key}.md"


TOPICS: tuple[Topic, ...] = (
    Topic("first_response", "First Response",
          "The first five minutes, triage, and the stay-or-move decision."),
    Topic("blackout", "Power & Network Blackout",
          "Grid failure, internet shutdown, charging, light, and staying informed."),
    Topic("medical", "Emergency Medical",
          "Bleeding, CPR, choking, shock, burns, fractures, head and chest injury."),
    Topic("earthquake", "Earthquake",
          "During shaking, after shaking, trapped, and rescuing others."),
    Topic("flood", "Flood & Waterlogging",
          "Rising water, evacuation, driving, drowning, and post-flood disease."),
    Topic("cyclone", "Cyclone & Storm",
          "IMD warning stages, shelter, the eye, and storm surge."),
    Topic("landslide", "Landslide",
          "Warning signs, escape direction, and hill-road hazards."),
    Topic("fire", "Fire",
          "Building fire, LPG cylinder, electrical fire, burns, and escape."),
    Topic("crowd", "Crowd Crush & Stampede",
          "Density thresholds, body position, falling, and exit strategy."),
    Topic("unrest", "Riots & Civil Unrest",
          "Curfew, tear gas, lathi charge, and moving through a hostile street."),
    Topic("blast", "Bomb Blast",
          "Immediate response, secondary devices, blast injuries, and evacuation."),
    Topic("war", "War & Shelling",
          "Air raid, shelling, shelter selection, and sustained conflict."),
    Topic("chemical", "Chemical & Gas Leak",
          "Industrial release, LPG, upwind movement, decontamination."),
    Topic("heat_cold", "Heat & Cold",
          "Heat stroke, loo, hypothermia, and Himalayan exposure."),
    Topic("bites", "Bites & Stings",
          "Snakebite, the Big Four, scorpions, rabies, and anaphylaxis."),
    Topic("water_food", "Water & Food",
          "Purification, rationing, ORS, foraging, and contamination."),
    Topic("shelter", "Shelter & Warmth",
          "Improvised shelter, insulation, ventilation, and carbon monoxide."),
    Topic("vulnerable", "Children, Elderly & Pregnancy",
          "Infants, the elderly, pregnancy, disability, and mental health."),
)

TOPIC_KEYS: tuple[str, ...] = tuple(t.key for t in TOPICS)
_BY_KEY: dict[str, Topic] = {t.key: t for t in TOPICS}


def topic_for(key: str) -> Topic | None:
    """Return the :class:`Topic` with ``key``, or None if unknown."""
    return _BY_KEY.get(key)


def display_name(key: str) -> str:
    """Return the human-readable name for a topic key, falling back to the key."""
    topic = _BY_KEY.get(key)
    return topic.display_name if topic else key
