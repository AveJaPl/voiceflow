"""The file through which the daemon tells the desktop app what the room is doing."""

from __future__ import annotations

import json

from voiceflow.roomstate import RoomState, clear_room_state, read_room_state, write_room_state


def test_round_trip_preserves_every_field(tmp_path):
    path = tmp_path / "room.json"
    state = RoomState(code="MSV5H3", connected=True, speaking="Wojtek", speaking_here=False)

    write_room_state(state, path)

    assert read_room_state(path) == state


def test_missing_file_reads_as_empty_state(tmp_path):
    """A machine that never joined a room is the normal case, not an error."""
    assert read_room_state(tmp_path / "nie-ma-takiego.json") == RoomState()


def test_broken_json_reads_as_empty_state(tmp_path):
    path = tmp_path / "room.json"
    path.write_text("{to nie jest json", encoding="utf-8")

    assert read_room_state(path) == RoomState()


def test_non_object_document_reads_as_empty_state(tmp_path):
    path = tmp_path / "room.json"
    path.write_text("[1, 2, 3]", encoding="utf-8")

    assert read_room_state(path) == RoomState()


def test_empty_speaker_string_becomes_none(tmp_path):
    """An empty name is silence; it must not render as somebody called "" ."""
    path = tmp_path / "room.json"
    path.write_text(json.dumps({"code": "ABC123", "speaking": ""}), encoding="utf-8")

    assert read_room_state(path).speaking is None


def test_write_failure_is_swallowed(tmp_path):
    """Losing this file must never disturb dictation, which is the whole tool."""
    unwritable = tmp_path / "nie-ma-katalogu" / "room.json"

    write_room_state(RoomState(code="ABC123"), unwritable)  # nie podnosi wyjątku

    assert read_room_state(unwritable) == RoomState()


def test_write_leaves_no_temporary_file_behind(tmp_path):
    path = tmp_path / "room.json"

    write_room_state(RoomState(code="ABC123"), path)

    assert [item.name for item in tmp_path.iterdir()] == ["room.json"]


def test_clear_removes_the_file(tmp_path):
    path = tmp_path / "room.json"
    write_room_state(RoomState(code="ABC123"), path)

    clear_room_state(path)

    assert not path.exists()


def test_clear_on_missing_file_is_silent(tmp_path):
    clear_room_state(tmp_path / "nie-ma-takiego.json")
