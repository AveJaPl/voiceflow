"""Tests for the Windows platform layer's pure logic (run on any OS)."""

from __future__ import annotations

import os

import pytest

from voiceflow.config import DEFAULT_PASTE_KEY, parse_config
from voiceflow.winplat.hotkey import format_binding, parse_binding
from voiceflow.winplat.keycapture import binding_from_keys
from voiceflow.winplat.injector import (
    InjectionError,
    modifiers_to_release,
    parse_paste_chord,
)
from voiceflow.winplat.notifier import build_toast_xml

_LSHIFT, _RSHIFT, _LCTRL, _LALT = 0xA0, 0xA1, 0xA2, 0xA4
_VK_SHIFT, _VK_CTRL, _VK_V = 0x10, 0x11, 0x56


def test_binding_parses_modifiers_and_letter() -> None:
    modifiers, key = parse_binding("ctrl+shift+g")

    assert modifiers == 0x0002 | 0x0004
    assert key == ord("G")


def test_binding_parses_named_key() -> None:
    modifiers, key = parse_binding("ctrl+shift+space")

    assert modifiers == 0x0002 | 0x0004
    assert key == 0x20


def test_binding_without_main_key_is_rejected() -> None:
    with pytest.raises(ValueError):
        parse_binding("ctrl+shift")


def test_binding_unknown_key_is_rejected() -> None:
    with pytest.raises(ValueError):
        parse_binding("hyper+g")


def test_paste_chord_translates_to_virtual_keys() -> None:
    assert parse_paste_chord("ctrl+v") == [0x11, 0x56]
    assert parse_paste_chord("ctrl+shift+v") == [0x11, 0x10, 0x56]


def test_paste_chord_unknown_key_is_a_clear_error() -> None:
    with pytest.raises(InjectionError, match="Nieznany klawisz"):
        parse_paste_chord("ctrl+ż")


def test_hotkey_config_defaults() -> None:
    config = parse_config({})

    assert config.hotkey.binding == "ctrl+shift+space"


def test_hotkey_config_custom_binding() -> None:
    config = parse_config({"hotkey": {"binding": "ctrl+alt+d"}})

    assert config.hotkey.binding == "ctrl+alt+d"


def test_winplat_modules_import_everywhere() -> None:
    """ctypes.windll must stay lazy so the suite runs on Linux CI."""
    import voiceflow.winplat.injector
    import voiceflow.winplat.keycapture
    import voiceflow.winplat.micmute
    import voiceflow.winplat.notifier
    import voiceflow.winplat.overlay
    import voiceflow.winplat.recorder  # noqa: F401


def test_binding_accepts_every_function_key() -> None:
    """F-keys are the usual escape route when Ctrl+Shift+Space is taken."""
    assert parse_binding("ctrl+f12")[1] == 0x7B
    assert parse_binding("alt+f1")[1] == 0x70


def test_binding_accepts_the_keyboardless_function_keys() -> None:
    """F13-F24 are on no keyboard, so nothing can steal them — the point of them."""
    assert parse_binding("f13")[1] == 0x7C
    assert parse_binding("ctrl+f24")[1] == 0x87


def test_recorded_binding_survives_a_round_trip() -> None:
    """Whatever the recorder writes, the daemon must be able to read back."""
    for binding in ("ctrl+shift+space", "win+alt+space", "pause", "f13", "ctrl+alt+d"):
        assert format_binding(*parse_binding(binding)) == binding


def test_format_binding_is_canonical_regardless_of_press_order() -> None:
    """Shift-then-ctrl and ctrl-then-shift are the same shortcut, one spelling."""
    _SHIFT, _CTRL = 0x0004, 0x0002

    assert format_binding(_SHIFT | _CTRL, 0x20) == "ctrl+shift+space"


def test_capture_merges_left_and_right_modifiers() -> None:
    """A low-level hook reports VK_RSHIFT; the config knows only "shift"."""
    assert binding_from_keys({_RSHIFT, 0xA2}, ord("D")) == "ctrl+shift+d"


def test_capture_allows_a_bare_key() -> None:
    """Pause with no modifier is a legitimate — and excellent — hotkey."""
    assert binding_from_keys(set(), 0x13) == "pause"


def test_capture_waits_while_only_modifiers_are_held() -> None:
    assert binding_from_keys({_LCTRL}, _VK_SHIFT) is None


def test_capture_refuses_a_key_the_daemon_could_not_bind() -> None:
    """Better an empty result than a binding that kills the hotkey on restart."""
    assert binding_from_keys({_LCTRL}, 0xB3) is None  # VK_MEDIA_PLAY_PAUSE


def test_paste_key_default_matches_the_platform() -> None:
    """ctrl+shift+v is a no-op in most native Windows apps; ctrl+v is universal."""
    expected = "ctrl+v" if os.name == "nt" else "ctrl+shift+v"

    assert DEFAULT_PASTE_KEY == expected
    assert parse_config({}).inject.paste_key == expected


def test_held_modifiers_outside_the_chord_are_released() -> None:
    """The hotkey ending a dictation is itself Ctrl+Shift — both must go."""
    chord = parse_paste_chord("ctrl+v")

    released = modifiers_to_release(chord, {_LSHIFT, _LCTRL})

    assert _LSHIFT in released
    assert _LCTRL not in released  # ctrl is part of ctrl+v


def test_modifiers_in_the_chord_are_never_released() -> None:
    chord = parse_paste_chord("ctrl+shift+v")

    assert modifiers_to_release(chord, {_LSHIFT, _RSHIFT, _LCTRL}) == []


def test_only_pressed_modifiers_are_released() -> None:
    assert modifiers_to_release(parse_paste_chord("ctrl+v"), set()) == []
    assert modifiers_to_release(parse_paste_chord("ctrl+v"), {_LALT}) == [_LALT]


def test_toast_xml_escapes_user_text() -> None:
    """A failure message carries paths and quotes; unescaped they break the XML."""
    xml = build_toast_xml('błąd <b> & "cudzysłów"')

    assert "&lt;b&gt;" in xml
    assert "&amp;" in xml
    assert "&quot;" in xml
    assert "<b>" not in xml


def test_toast_marks_errors_long_lived() -> None:
    assert 'duration="long"' in build_toast_xml("boom", urgency="critical")
    assert "duration" not in build_toast_xml("fyi")
