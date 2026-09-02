"""The runtime safety guard: two failure modes, two different responses."""

from __future__ import annotations

import pytest

from survive_rag.polarity import affirms, negates
from survive_rag.safety import (
    AUGMENT,
    BLOCK,
    PASS,
    check_answer_against_context,
    forbidden_actions,
    guard,
    is_safe,
    missing_warnings,
)

TOURNIQUET = (
    "Every one of these causes harm.\n"
    "- **DO NOT apply a tourniquet.** This is the single most damaging "
    "traditional practice. Tourniquets do not stop venom spread; they cause "
    "gangrene and amputation.\n"
    "- **DO NOT suck the venom out.** It does not work."
)


def test_extracts_the_actions_the_guides_forbid() -> None:
    """The guard can only check prohibitions it can find."""
    actions = forbidden_actions(TOURNIQUET)
    assert "apply a tourniquet" in actions
    assert "suck the venom out" in actions


def test_extraction_ignores_a_claim_about_efficacy() -> None:
    """'Tourniquets do not stop venom spread' is not an instruction.

    Read as one, it would forbid stopping venom spread, and the guard would
    block correct answers.
    """
    assert "stop venom spread" not in forbidden_actions(TOURNIQUET)


def test_extraction_drops_dangling_fragments() -> None:
    """A phrase ending in a function word makes an unmatchable needle."""
    assert all(not a.split()[-1] in {"the", "a", "to", "you"} for a in forbidden_actions(TOURNIQUET))


def test_an_answer_asserting_a_forbidden_action_is_blocked() -> None:
    """The failure that must never reach a user."""
    decision = guard("Apply a tourniquet above the bite immediately.", TOURNIQUET)
    assert decision.action == BLOCK
    assert decision.violations
    assert "tourniquet" in str(decision.violations[0])


def test_an_answer_omitting_a_warning_is_augmented_not_blocked() -> None:
    """The observed conversational failure: incomplete, not wrong."""
    decision = guard("Immobilise the limb and get to a hospital with ASV.", TOURNIQUET)
    assert decision.action == AUGMENT
    assert "apply a tourniquet" in decision.omissions


def test_a_correct_and_complete_answer_passes_untouched() -> None:
    """A guard that fires on good answers would be worse than none."""
    answer = (
        "Do not apply a tourniquet — it causes gangrene. Do not suck the venom out. "
        "Immobilise the limb and get to a hospital with ASV."
    )
    assert guard(answer, TOURNIQUET).action == PASS
    assert is_safe(answer, TOURNIQUET)


def test_omissions_are_capped() -> None:
    """A chunk dense with prohibitions must not bury the actual answer."""
    decision = guard("Get to a hospital.", TOURNIQUET, max_omissions=1)
    assert len(decision.omissions) == 1


def test_no_context_means_nothing_to_check() -> None:
    """A capability answer or a refusal has no reference material."""
    assert guard("I can help with Indian emergencies.", "").action == PASS


@pytest.mark.parametrize(
    ("answer", "asserted"),
    [
        ("Apply a tourniquet now.", True),
        ("Never apply a tourniquet.", False),
        ("Applying a tourniquet is harmful.", False),
        ("It is a myth that you should apply a tourniquet.", False),
    ],
)
def test_polarity_underpins_the_guard(answer: str, asserted: bool) -> None:
    """Everything above rests on telling an assertion from a warning."""
    assert affirms(answer, "apply a tourniquet") is asserted


def test_negates_requires_the_phrase_to_be_present() -> None:
    """Silence is not a warning."""
    assert negates("Do not apply a tourniquet.", "apply a tourniquet")
    assert not negates("Go to hospital immediately.", "apply a tourniquet")


def test_violations_and_omissions_are_disjoint_for_one_action() -> None:
    """An answer cannot both assert and omit the same prohibition."""
    asserted = "Apply a tourniquet."
    assert check_answer_against_context(asserted, TOURNIQUET)
    assert "apply a tourniquet" not in missing_warnings(asserted, TOURNIQUET)
