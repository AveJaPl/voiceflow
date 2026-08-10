"""Tests for dictation-shortcut comparison and conflict reporting.

Only the pure logic is covered: reading and writing gsettings needs a live
session, but deciding whether two accelerators are the same key does not — and
that decision is the part that silently produces a wrong answer.
"""

from __future__ import annotations

from voiceflow_app.shortcuts import Binding, conflicts, describe, is_complete, normalize


def test_modifier_order_does_not_change_a_shortcut() -> None:
    """GNOME writes modifiers in whatever order it likes; both are one key."""
    assert normalize("<Shift><Super>space") == normalize("<Super><Shift>space")


def test_modifier_spellings_are_unified() -> None:
    # <Primary> and <Control> are the same physical key, and GNOME uses both
    # spellings across its own schemas.
    assert normalize("<Primary><Alt>d") == normalize("<Control><Alt>d")
    assert normalize("<Meta>x") == normalize("<Super>x")


def test_case_is_irrelevant() -> None:
    assert normalize("<super>G") == normalize("<Super>g")


def test_different_keys_stay_different() -> None:
    assert normalize("<Super>g") != normalize("<Super>h")
    assert normalize("<Super>g") != normalize("<Control>g")


def test_modifier_only_accelerator_is_incomplete() -> None:
    assert is_complete("<Super>") is False
    assert is_complete("") is False
    assert is_complete("<Super>g") is True


def test_conflict_is_found_regardless_of_modifier_order() -> None:
    existing = [Binding("<Shift><Super>space", "Okna: Switch input source backward")]

    found = conflicts("<Super><Shift>space", existing)

    assert [binding.owner for binding in found] == [
        "Okna: Switch input source backward"
    ]


def test_voiceflow_own_binding_is_not_a_conflict() -> None:
    """Rebinding onto our own key is a no-op, not a collision to warn about."""
    existing = [Binding("<Super>g", "Własny: voiceflow", is_voiceflow=True)]

    assert conflicts("<Super>g", existing) == []


def test_free_shortcut_reports_no_conflict() -> None:
    existing = [Binding("<Super>space", "Okna: Switch input source")]

    assert conflicts("<Control><Alt>space", existing) == []


def test_incomplete_accelerator_never_conflicts() -> None:
    existing = [Binding("<Super>g", "Własny: coś")]

    assert conflicts("<Super>", existing) == []


def test_describe_lists_every_owner_once() -> None:
    found = [
        Binding("<Super>v", "GNOME Shell: Toggle message tray"),
        Binding("<Super>v", "GNOME Shell: Toggle message tray"),
        Binding("<Super>v", "Okna: Coś innego"),
    ]

    assert describe(found) == "GNOME Shell: Toggle message tray oraz Okna: Coś innego"


def test_describe_single_owner_reads_plainly() -> None:
    assert describe([Binding("<Super>space", "Okna: Switch input source")]) == (
        "Okna: Switch input source"
    )
