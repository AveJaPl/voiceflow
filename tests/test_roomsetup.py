"""Tests for writing the room section into a hand-written config file."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from voiceflow.roomsetup import RoomSetupError, _http_base, leave_room, save_to_config


def test_http_base_maps_websocket_scheme_to_http() -> None:
    assert _http_base("wss://rooms.pbdevs.com") == "https://rooms.pbdevs.com"
    assert _http_base("ws://localhost:3000/") == "http://localhost:3000"
    assert _http_base("https://rooms.pbdevs.com") == "https://rooms.pbdevs.com"


def test_writing_the_room_section_keeps_every_comment(tmp_path: Path) -> None:
    """config.yaml is a commented document; joining a room must not flatten it."""
    path = tmp_path / "config.yaml"
    path.write_text(
        "# voiceflow configuration\n"
        "model:\n"
        "  # Ten komentarz musi przetrwać\n"
        "  name: large-v3-turbo\n"
        "log_level: INFO\n",
        encoding="utf-8",
    )

    save_to_config("wss://example", "AB23CD", "sekret", path)

    text = path.read_text(encoding="utf-8")
    assert "# Ten komentarz musi przetrwać" in text
    assert "name: large-v3-turbo" in text
    assert "log_level: INFO" in text
    assert "code: AB23CD" in text


def test_rejoining_replaces_the_old_section_instead_of_stacking(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text("log_level: INFO\n", encoding="utf-8")

    save_to_config("wss://example", "AAAAAA", "stary", path)
    save_to_config("wss://example", "BBBBBB", "nowy", path)

    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert parsed["room"]["code"] == "BBBBBB"
    assert parsed["room"]["token"] == "nowy"
    assert path.read_text(encoding="utf-8").count("room:") == 1


def test_written_file_still_parses_and_is_private(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"

    save_to_config("wss://example", "AB23CD", "token-z-myslnikiem-123", path)

    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert parsed["room"]["enabled"] is True
    assert parsed["room"]["token"] == "token-z-myslnikiem-123"
    assert path.stat().st_mode & 0o777 == 0o600, "token urządzenia nie jest dla wszystkich"


# -- leaving ------------------------------------------------------------------
# One implementation, two callers: the command line and the desktop window. It
# flips a flag inside a block that is spliced in as text, so rewriting the
# parsed document instead would throw that block's comments away.


def test_leaving_switches_the_room_off(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    save_to_config("wss://rooms.example", "K7QP2M", "token-123", path)

    leave_room("wss://rooms.example", "K7QP2M", "token-123", path)

    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert parsed["room"]["enabled"] is False


def test_leaving_keeps_the_code_and_token_for_a_quick_return(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"

    leave_room("wss://rooms.example", "K7QP2M", "token-123", path)

    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert parsed["room"]["code"] == "K7QP2M"
    assert parsed["room"]["token"] == "token-123"
    assert parsed["room"]["server"] == "wss://rooms.example"


def test_leaving_preserves_everything_else_in_the_file(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text(
        "model:\n  # Ten komentarz musi przetrwać\n  name: large-v3-turbo\n",
        encoding="utf-8",
    )

    leave_room("wss://rooms.example", "K7QP2M", "token-123", path)

    text = path.read_text(encoding="utf-8")
    assert "Ten komentarz musi przetrwać" in text
    assert yaml.safe_load(text)["model"]["name"] == "large-v3-turbo"


def test_leaving_twice_leaves_the_room_off_rather_than_toggling_it(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"

    leave_room("wss://rooms.example", "K7QP2M", "token-123", path)
    leave_room("wss://rooms.example", "K7QP2M", "token-123", path)

    assert yaml.safe_load(path.read_text(encoding="utf-8"))["room"]["enabled"] is False
