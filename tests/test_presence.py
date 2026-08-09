"""Tests for Discord Rich Presence framing and configuration."""

from __future__ import annotations

import json
import struct

from voiceflow.config import parse_config
from voiceflow.presence import DiscordPresence, _encode
from voiceflow.config import PresenceConfig


def test_frame_encoding_is_little_endian_with_length() -> None:
    frame = _encode(1, {"cmd": "SET_ACTIVITY"})

    opcode, length = struct.unpack("<II", frame[:8])
    assert opcode == 1
    assert length == len(frame) - 8
    assert json.loads(frame[8:]) == {"cmd": "SET_ACTIVITY"}


def test_disabled_or_unconfigured_presence_is_inert() -> None:
    assert DiscordPresence(PresenceConfig()).available is False
    assert DiscordPresence(PresenceConfig(enabled=True)).available is False
    assert DiscordPresence(PresenceConfig(enabled=True, client_id="123")).available is True

    # Calls on an unavailable presence must be no-ops, not errors.
    presence = DiscordPresence(PresenceConfig())
    presence.dictating()
    presence.clear()


def test_config_parses_presence_section() -> None:
    config = parse_config({"presence": {"enabled": True, "client_id": 12345}})

    assert config.presence.enabled is True
    assert config.presence.client_id == "12345"


def test_config_defaults_presence_off() -> None:
    assert parse_config({}).presence.enabled is False
