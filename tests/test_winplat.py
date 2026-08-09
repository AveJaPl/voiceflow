"""Tests for the Windows platform layer's pure logic (run on any OS)."""

from __future__ import annotations

import pytest

from voiceflow.config import parse_config
from voiceflow.winplat.hotkey import parse_binding
from voiceflow.winplat.injector import InjectionError, parse_paste_chord


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
    import voiceflow.winplat.micmute
    import voiceflow.winplat.overlay
    import voiceflow.winplat.recorder  # noqa: F401
