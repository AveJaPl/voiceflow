"""Reading Claude Code limit usage. No files, no Claude Code."""

from __future__ import annotations

import json

from voiceflow.claudeusage import ClaudeUsage, current_usage, parse

SNAPSHOT = {
    "session_name": "Audyt projektu",
    "cwd": "/home/aveja/projects/dialogpro-v2",
    "cost": {"total_cost_usd": 190.25},
    "rate_limits": {
        "five_hour": {"used_percentage": 57.99999, "resets_at": 1783881000},
        "seven_day": {"used_percentage": 5, "resets_at": 1784469600},
    },
}


def test_reads_both_windows_and_rounds_them():
    usage = parse(SNAPSHOT)

    assert usage == ClaudeUsage(five_hour=58, seven_day=5, resets_at=1783881000)


def test_payload_carries_only_the_numbers():
    """Nazwa sesji, katalog i koszt w dolarach mówią, NAD CZYM ktoś pracował.
    Do pokoju idą wyłącznie procenty limitów."""
    payload = parse(SNAPSHOT).as_payload()

    assert set(payload) == {"fiveHour", "sevenDay", "resetsAt"}
    assert "dialogpro" not in json.dumps(payload)
    assert "190" not in json.dumps(payload)


def test_stale_snapshot_is_no_tile_rather_than_an_old_number():
    """Wczorajsza liczba pokazana jako dzisiejsza jest gorsza niż brak kafelka."""
    assert parse(SNAPSHOT, age_seconds=7 * 3600) is None


def test_fresh_enough_snapshot_still_counts():
    assert parse(SNAPSHOT, age_seconds=3600) is not None


def test_percentages_are_clamped():
    usage = parse({"rate_limits": {"five_hour": {"used_percentage": 140},
                                   "seven_day": {"used_percentage": -3}}})

    assert usage.five_hour == 100
    assert usage.seven_day == 0


def test_shape_that_changed_in_an_update_gives_nothing():
    assert parse({"rate_limits": "kiedyś to była mapa"}) is None
    assert parse({"rate_limits": {}}) is None
    assert parse("to nie jest dokument") is None
    assert parse({}) is None


def test_missing_reset_time_is_zero_not_a_crash():
    usage = parse({"rate_limits": {"five_hour": {"used_percentage": 10}}})

    assert usage.resets_at == 0
    assert usage.seven_day == 0


def test_missing_file_means_no_tile(tmp_path):
    assert current_usage(tmp_path / "nie-ma.json") is None


def test_broken_file_means_no_tile(tmp_path):
    path = tmp_path / "statusline.json"
    path.write_text("{obcięty", encoding="utf-8")

    assert current_usage(path) is None


def test_real_file_round_trip(tmp_path):
    path = tmp_path / "statusline.json"
    path.write_text(json.dumps(SNAPSHOT), encoding="utf-8")

    assert current_usage(path) == ClaudeUsage(five_hour=58, seven_day=5, resets_at=1783881000)
