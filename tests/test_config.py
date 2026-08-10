"""Tests for configuration defaults and tolerant parsing."""

from __future__ import annotations

import logging
from pathlib import Path

import pytest

from voiceflow.config import load_config, parse_config


def test_missing_values_use_defaults() -> None:
    config = parse_config({"model": {"language": None}, "audio": {}})

    assert config.model.name == "large-v3-turbo"
    assert config.model.language is None
    assert config.model.beam_size == 5
    assert config.audio.max_seconds == 300
    assert config.inject.key_delay_ms == 12
    assert config.inject.paste_key == "ctrl+shift+v"


def test_known_values_are_parsed() -> None:
    config = parse_config(
        {
            "model": {"name": "small", "device": "cpu", "compute_type": "int8", "beam_size": 2},
            "audio": {"source": "alsa_input.usb", "max_seconds": 12},
            "inject": {"method": "auto", "key_delay_ms": 20, "restore_clipboard": False},
            "notifications": {"enabled": False},
            "log_level": "debug",
        }
    )

    assert config.model.name == "small"
    assert config.model.device == "cpu"
    assert config.audio.source == "alsa_input.usb"
    assert config.inject.method == "auto"
    assert config.notifications.enabled is False
    assert config.log_level == "DEBUG"


def test_unknown_keys_warn_instead_of_raising(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING):
        config = parse_config({"mystery": 1, "model": {"unknown_option": True}})

    assert config.model.name == "large-v3-turbo"
    assert "mystery" in caplog.text
    assert "model.unknown_option" in caplog.text


def test_hotkey_defaults_are_toggle_only() -> None:
    config = parse_config({})

    assert config.hotkey.toggle.enabled is True
    assert config.hotkey.toggle.binding == "<Super>g"
    # Push-to-talk is opt-in: binding it prompts the desktop for confirmation,
    # which nobody should get without asking for the feature.
    assert config.hotkey.push_to_talk.enabled is False


def test_hotkey_modes_are_independent() -> None:
    config = parse_config(
        {
            "hotkey": {
                "toggle": {"enabled": False, "binding": "<Control><Alt>d"},
                "push_to_talk": {"enabled": True, "binding": "<Super>space"},
            }
        }
    )

    assert config.hotkey.toggle.enabled is False
    assert config.hotkey.toggle.binding == "<Control><Alt>d"
    assert config.hotkey.push_to_talk.enabled is True
    assert config.hotkey.push_to_talk.binding == "<Super>space"


def test_both_modes_on_one_key_disable_push_to_talk(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """The ambiguous configuration is refused, not resolved by a stopwatch."""
    with caplog.at_level(logging.WARNING):
        config = parse_config(
            {
                "hotkey": {
                    "toggle": {"enabled": True, "binding": "<Super>g"},
                    "push_to_talk": {"enabled": True, "binding": "<super>G"},
                }
            }
        )

    assert config.hotkey.toggle.enabled is True
    assert config.hotkey.push_to_talk.enabled is False
    assert "push_to_talk" in caplog.text


def test_same_binding_is_allowed_while_only_one_mode_is_on() -> None:
    config = parse_config(
        {
            "hotkey": {
                "toggle": {"enabled": False, "binding": "<Super>g"},
                "push_to_talk": {"enabled": True, "binding": "<Super>g"},
            }
        }
    )

    assert config.hotkey.push_to_talk.enabled is True


def test_hotkey_junk_falls_back_per_field(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING):
        config = parse_config(
            {"hotkey": {"toggle": {"enabled": "tak", "binding": "   "}, "push_to_talk": 7}}
        )

    assert config.hotkey.toggle.enabled is True
    assert config.hotkey.toggle.binding == "<Super>g"
    assert config.hotkey.push_to_talk.binding == "<Control><Alt>space"


def test_windows_binding_survives_the_new_sections() -> None:
    """The Windows daemon reads hotkey.binding; adding modes must not move it."""
    config = parse_config({"hotkey": {"binding": "ctrl+shift+f9"}})

    assert config.hotkey.binding == "ctrl+shift+f9"
    assert config.hotkey.toggle.binding == "<Super>g"


def test_first_load_creates_commented_file(tmp_path: Path) -> None:
    path = tmp_path / "voiceflow" / "config.yaml"

    config = load_config(path)

    assert config.model.language == "pl"
    content = path.read_text(encoding="utf-8")
    assert "# voiceflow configuration" in content
    assert "large-v3-turbo" in content
