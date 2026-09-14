"""Numbers behind the room board in the desktop app. No window, no network."""

from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from voiceflow_app.roomdata import (
    RoomDataError,
    RoomState,
    board_rows,
    format_duration,
    http_base,
    read_room_state,
    room_url,
    session_elapsed,
)


def _entry(name: str, words: int, **extra):
    base = {"name": name, "words": words, "seconds": 60, "dictations": 2, "averageWords": 5}
    base.update(extra)
    return base


# --- tablica ---------------------------------------------------------------


def test_empty_ranking_gives_no_rows_instead_of_dividing_by_zero():
    assert board_rows([]) == []


def test_positions_start_at_one():
    rows = board_rows([_entry("Filip", 10), _entry("Wojtek", 5)])

    assert [row.position for row in rows] == [1, 2]


def test_equal_words_split_the_share_evenly():
    rows = board_rows([_entry("Filip", 50), _entry("Wojtek", 50)])

    assert [row.share for row in rows] == [50, 50]


def test_leader_is_behind_nobody():
    rows = board_rows([_entry("Filip", 900), _entry("Wojtek", 300)])

    assert rows[0].behind == 0
    assert rows[1].behind == 600


def test_missing_fields_do_not_crash_the_board():
    """Ranking przychodzi z sieci — brak pola nie może wywrócić okna."""
    rows = board_rows([{"name": "Filip"}])

    assert rows[0].words == 0
    assert rows[0].share == 0
    assert rows[0].average_words == 0


def test_nameless_entry_gets_a_dash_not_the_word_none():
    rows = board_rows([_entry(None, 10)])

    assert rows[0].name == "—"


def test_everyone_silent_gives_zero_shares_not_a_crash():
    rows = board_rows([_entry("Filip", 0), _entry("Wojtek", 0)])

    assert [row.share for row in rows] == [0, 0]


# --- formatowanie ----------------------------------------------------------


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (0, "0 min"),
        (29, "0 min"),
        (60, "1 min"),
        (3600, "1 godz."),
        (5000, "1 godz. 23 min"),
    ],
)
def test_duration_matches_the_web_board(seconds, expected):
    assert format_duration(seconds) == expected


def test_session_clock_counts_from_the_start():
    now = datetime(2026, 8, 11, 12, 30, 15, tzinfo=timezone.utc)

    assert session_elapsed("2026-08-11T11:00:00Z", now) == "01:30:15"


def test_session_clock_accepts_postgres_zulu_and_offset_alike():
    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)

    assert session_elapsed("2026-08-11T11:00:00+00:00", now) == "01:00:00"


def test_naive_timestamp_is_read_as_utc_rather_than_rejected():
    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)

    assert session_elapsed("2026-08-11T11:00:00", now) == "01:00:00"


def test_unparseable_start_shows_unknown_not_zero():
    """Sesja, której początku nie umiemy odczytać, nie trwa zero sekund."""
    assert session_elapsed("kiedyś tam") == "—"


def test_clock_never_runs_backwards():
    now = datetime(2026, 8, 11, 10, 0, 0, tzinfo=timezone.utc)

    assert session_elapsed("2026-08-11T11:00:00Z", now) == "00:00:00"


# --- adresy ----------------------------------------------------------------


def test_websocket_server_becomes_an_http_base():
    assert http_base("wss://rooms.pbdevs.com") == "https://rooms.pbdevs.com"
    assert http_base("ws://localhost:3000") == "http://localhost:3000"


def test_trailing_slash_does_not_double_up():
    assert http_base("https://rooms.pbdevs.com/") == "https://rooms.pbdevs.com"


def test_nonsense_server_is_rejected_loudly():
    with pytest.raises(RoomDataError):
        http_base("rooms.pbdevs.com")


def test_room_url_upper_cases_the_code():
    assert room_url("wss://rooms.pbdevs.com", "msv5h3") == "https://rooms.pbdevs.com/room/MSV5H3"


# --- stan z pliku demona ---------------------------------------------------


def test_room_state_round_trips_from_the_daemon_document(tmp_path):
    path = tmp_path / "room.json"
    path.write_text(
        json.dumps({"code": "MSV5H3", "connected": True, "speaking": "Wojtek", "speaking_here": False}),
        encoding="utf-8",
    )

    assert read_room_state(path) == RoomState(
        code="MSV5H3", connected=True, speaking="Wojtek", speaking_here=False
    )


def test_missing_state_file_means_no_room(tmp_path):
    state = read_room_state(tmp_path / "nie-ma.json")

    assert state == RoomState()
    assert state.in_room is False


def test_broken_state_file_means_no_room(tmp_path):
    path = tmp_path / "room.json"
    path.write_text("{obcięty", encoding="utf-8")

    assert read_room_state(path) == RoomState()


def test_empty_speaker_is_silence_not_a_person_called_nothing(tmp_path):
    path = tmp_path / "room.json"
    path.write_text(json.dumps({"code": "MSV5H3", "speaking": ""}), encoding="utf-8")

    assert read_room_state(path).speaking is None


# --- historia sesji --------------------------------------------------------


@pytest.mark.parametrize(
    ("count", "expected"),
    [(0, "osób"), (1, "osoba"), (2, "osoby"), (4, "osoby"), (5, "osób"),
     (12, "osób"), (14, "osób"), (22, "osoby"), (25, "osób")],
)
def test_polish_plural_for_people(count, expected):
    from voiceflow_app.roomdata import people_word

    assert people_word(count) == expected


@pytest.mark.parametrize(
    ("count", "expected"),
    [(0, "sesji"), (1, "sesja"), (2, "sesje"), (5, "sesji"), (13, "sesji")],
)
def test_polish_plural_for_sessions(count, expected):
    from voiceflow_app.roomdata import sessions_word

    assert sessions_word(count) == expected


def test_closed_session_span_uses_its_own_end():
    from voiceflow_app.roomdata import session_span

    assert session_span("2026-08-10T18:00:00Z", "2026-08-10T20:35:00Z") == "2 godz. 35 min"


def test_open_session_span_runs_until_now():
    from voiceflow_app.roomdata import session_span

    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)

    assert session_span("2026-08-11T11:00:00Z", None, now) == "1 godz."


def test_session_span_without_a_start_is_unknown():
    from voiceflow_app.roomdata import session_span

    assert session_span("", None) == "—"
