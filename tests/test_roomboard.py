"""The package's room-board maths — the numbers the Windows window draws.

Deliberately the same battery as ``test_roomdata.py``, which covers the GTK
application's copy. Two windows showing different numbers for one room would be
the worst failure this feature has, so both are pinned to the same expectations.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from voiceflow.roomboard import (
    RoomDataError,
    board_rows,
    format_duration,
    http_base,
    people_word,
    plural,
    room_url,
    session_elapsed,
    session_span,
    sessions_word,
    words_word,
)


def _entry(name: str, words: int, **extra):
    base = {"name": name, "words": words, "seconds": 60, "dictations": 2, "averageWords": 5}
    base.update(extra)
    return base


# -- the board ---------------------------------------------------------------


def test_empty_ranking_produces_no_rows() -> None:
    assert board_rows([]) == []


def test_positions_follow_the_order_the_server_sent() -> None:
    rows = board_rows([_entry("Filip", 100), _entry("Jakub", 40)])
    assert [(row.position, row.name) for row in rows] == [(1, "Filip"), (2, "Jakub")]


def test_share_is_a_percentage_of_the_whole_session() -> None:
    rows = board_rows([_entry("Filip", 75), _entry("Jakub", 25)])
    assert [row.share for row in rows] == [75, 25]


def test_share_is_zero_when_nobody_has_said_anything() -> None:
    rows = board_rows([_entry("Filip", 0), _entry("Jakub", 0)])
    assert [row.share for row in rows] == [0, 0]


def test_distance_is_measured_from_the_leader_who_is_zero_behind() -> None:
    rows = board_rows([_entry("Filip", 100), _entry("Jakub", 40)])
    assert [row.behind for row in rows] == [0, 60]


def test_missing_numbers_read_as_zero_rather_than_crashing() -> None:
    row = board_rows([{"name": "Filip"}])[0]
    assert (row.words, row.seconds, row.dictations, row.average_words) == (0, 0, 0, 0)


def test_a_nameless_entry_is_shown_as_a_dash() -> None:
    assert board_rows([_entry(None, 10)])[0].name == "—"


# -- durations ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [(0, "0 min"), (59, "1 min"), (90, "2 min"), (3600, "1 godz."), (5400, "1 godz. 30 min")],
)
def test_speaking_time_reads_the_way_the_web_board_writes_it(seconds, expected) -> None:
    assert format_duration(seconds) == expected


def test_session_clock_counts_from_the_start_in_hours_minutes_seconds() -> None:
    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)
    started = "2026-08-11T10:30:15Z"
    assert session_elapsed(started, now) == "01:29:45"


def test_unparseable_start_is_unknown_rather_than_zero() -> None:
    assert session_elapsed("nie-data") == "—"
    assert session_elapsed("") == "—"


def test_a_naive_timestamp_is_read_as_utc() -> None:
    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)
    assert session_elapsed("2026-08-11T11:00:00", now) == "01:00:00"


def test_a_closed_session_is_measured_between_its_own_two_ends() -> None:
    span = session_span("2026-08-11T10:00:00Z", "2026-08-11T11:30:00Z")
    assert span == "1 godz. 30 min"


def test_an_open_session_is_measured_up_to_now() -> None:
    now = datetime(2026, 8, 11, 12, 0, 0, tzinfo=timezone.utc)
    assert session_span("2026-08-11T11:00:00Z", None, now) == "1 godz."


# -- Polish plurals ----------------------------------------------------------


@pytest.mark.parametrize(
    ("count", "expected"),
    [(0, "sesji"), (1, "sesja"), (2, "sesje"), (4, "sesje"), (5, "sesji"),
     (12, "sesji"), (13, "sesji"), (14, "sesji"), (22, "sesje"), (25, "sesji")],
)
def test_sessions_take_the_right_ending(count, expected) -> None:
    assert sessions_word(count) == expected


@pytest.mark.parametrize(
    ("count", "expected"), [(0, "osób"), (1, "osoba"), (3, "osoby"), (11, "osób")]
)
def test_people_take_the_right_ending(count, expected) -> None:
    assert people_word(count) == expected


@pytest.mark.parametrize(
    ("count", "expected"), [(0, "słów"), (1, "słowo"), (3, "słowa"), (13, "słów")]
)
def test_words_take_the_right_ending(count, expected) -> None:
    assert words_word(count) == expected


def test_a_negative_count_is_read_by_its_magnitude() -> None:
    assert plural(-2, "jeden", "dwa", "wiele") == "dwa"


# -- addresses ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("server", "expected"),
    [
        ("wss://rooms.example", "https://rooms.example"),
        ("ws://localhost:3000", "http://localhost:3000"),
        ("https://rooms.example/", "https://rooms.example"),
    ],
)
def test_a_websocket_address_becomes_the_rest_address(server, expected) -> None:
    assert http_base(server) == expected


@pytest.mark.parametrize("server", ["", "rooms.example", "gopher://rooms"])
def test_an_address_that_is_not_one_is_refused_rather_than_guessed(server) -> None:
    with pytest.raises(RoomDataError):
        http_base(server)


def test_the_room_link_is_upper_case_whatever_the_user_typed() -> None:
    assert room_url("wss://rooms.example", "k7qp2m") == "https://rooms.example/room/K7QP2M"


# -- people who have not spoken yet -------------------------------------------


def _member(device: str, name: str):
    return {"id": device, "name": name}


def test_somebody_who_joined_but_said_nothing_still_gets_a_line() -> None:
    rows = board_rows(
        [{"deviceId": "d1", "name": "Filip", "words": 100, "seconds": 60,
          "dictations": 2, "averageWords": 50}],
        [_member("d1", "Filip"), _member("d2", "Jakub")],
    )
    assert [(row.position, row.name, row.words) for row in rows] == [
        (1, "Filip", 100),
        (2, "Jakub", 0),
    ]


def test_a_silent_member_carries_zeroes_rather_than_blanks() -> None:
    row = board_rows([], [_member("d2", "Jakub")])[0]
    assert (row.words, row.seconds, row.dictations, row.average_words) == (0, 0, 0, 0)
    assert row.share == 0


def test_a_silent_member_is_shown_as_behind_the_leader() -> None:
    rows = board_rows(
        [{"deviceId": "d1", "name": "Filip", "words": 100}], [_member("d2", "Jakub")]
    )
    assert rows[1].behind == 100


def test_somebody_already_in_the_ranking_is_not_listed_twice() -> None:
    rows = board_rows(
        [{"deviceId": "d1", "name": "Filip", "words": 100}], [_member("d1", "Filip")]
    )
    assert len(rows) == 1


def test_two_people_sharing_a_name_stay_two_people() -> None:
    rows = board_rows(
        [{"deviceId": "d1", "name": "Jakub", "words": 40}],
        [_member("d1", "Jakub"), _member("d2", "Jakub")],
    )
    assert len(rows) == 2, "dopasowanie idzie po urządzeniu, nie po imieniu"


def test_a_member_without_a_name_is_skipped_rather_than_drawn_blank() -> None:
    assert board_rows([], [{"id": "d2", "name": "  "}]) == []


def test_silent_members_do_not_dilute_anybody_share() -> None:
    rows = board_rows(
        [{"deviceId": "d1", "name": "Filip", "words": 100}], [_member("d2", "Jakub")]
    )
    assert rows[0].share == 100, "zero słów nie zabiera procentów temu, kto mówił"


def test_no_ranking_and_no_members_is_still_an_empty_board() -> None:
    assert board_rows([], []) == []
