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


def test_first_load_creates_commented_file(tmp_path: Path) -> None:
    path = tmp_path / "voiceflow" / "config.yaml"

    config = load_config(path)

    assert config.model.language == "pl"
    content = path.read_text(encoding="utf-8")
    assert "# voiceflow configuration" in content
    assert "large-v3-turbo" in content


def test_tray_defaults_to_enabled() -> None:
    config = parse_config({})

    assert config.tray.enabled is True


def test_tray_can_be_disabled() -> None:
    config = parse_config({"tray": {"enabled": False}})

    assert config.tray.enabled is False
