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


# --- licznik tokenów z transkryptów -----------------------------------------

from voiceflow.claudeusage import TokenCounter, current_payload  # noqa: E402

import time as _time  # noqa: E402

NOW = _time.time()  # realny zegar: mtime świeżo zapisanych plików musi być „dziś"


def _line(request_id, timestamp, usage, **extra):
    entry = {"type": "assistant", "timestamp": timestamp,
             "requestId": request_id, "message": {"usage": usage}, **extra}
    return json.dumps(entry) + "\n"


def _usage(inp=10, cache_new=100, cache_read=1000, out=50):
    return {"input_tokens": inp, "cache_creation_input_tokens": cache_new,
            "cache_read_input_tokens": cache_read, "output_tokens": out}


def _write(tmp_path, name, text):
    target = tmp_path / "projekt" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    return target


def _today_iso(now=NOW):
    import datetime
    return datetime.datetime.fromtimestamp(now, tz=datetime.UTC).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z")


def test_counts_input_with_cache_and_output(tmp_path):
    _write(tmp_path, "a.jsonl", _line("req-1", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    assert counter.tokens_today(now=NOW) == (1110, 50)


def test_one_api_response_split_over_many_lines_counts_once(tmp_path):
    """Zmierzono w prawdziwym transkrypcie: ta sama odpowiedź (requestId)
    leży w trzech liniach z identycznym usage. Bez deduplikacji wszystko
    liczyłoby się potrójnie."""
    _write(tmp_path, "a.jsonl",
           _line("req-1", _today_iso(), _usage()) * 3)
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    assert counter.tokens_today(now=NOW) == (1110, 50)


def test_yesterdays_entries_do_not_count(tmp_path):
    _write(tmp_path, "a.jsonl",
           _line("req-old", "2026-08-01T10:00:00.000Z", _usage())
           + _line("req-new", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    assert counter.tokens_today(now=NOW) == (1110, 50)


def test_broken_lines_and_lines_without_usage_are_skipped(tmp_path):
    _write(tmp_path, "a.jsonl",
           '{obcięta linia\n'
           + json.dumps({"type": "user", "timestamp": _today_iso()}) + "\n"
           + _line("req-1", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    assert counter.tokens_today(now=NOW) == (1110, 50)


def test_appended_lines_are_added_incrementally(tmp_path):
    path = _write(tmp_path, "a.jsonl", _line("req-1", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)
    assert counter.tokens_today(now=NOW) == (1110, 50)

    with path.open("a", encoding="utf-8") as handle:
        handle.write(_line("req-2", _today_iso(), _usage(out=7)))

    assert counter.tokens_today(now=NOW) == (2220, 57)


def test_missing_projects_dir_means_zero(tmp_path):
    counter = TokenCounter(tmp_path / "nie-ma", refresh_seconds=0)

    assert counter.tokens_today(now=NOW) == (0, 0)


def test_full_payload_carries_percentages_and_token_counts_only(tmp_path):
    statusline = tmp_path / "statusline.json"
    statusline.write_text(json.dumps(SNAPSHOT), encoding="utf-8")
    _write(tmp_path, "a.jsonl", _line("req-1", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    payload = current_payload(path=statusline, counter=counter, now=NOW)

    assert set(payload) == {"fiveHour", "sevenDay", "resetsAt", "tokensIn", "tokensOut"}
    assert payload["tokensIn"] == 1110
    assert payload["tokensOut"] == 50
    assert "dialogpro" not in json.dumps(payload)


def test_tokens_alone_still_make_a_payload_when_statusline_is_stale(tmp_path):
    _write(tmp_path, "a.jsonl", _line("req-1", _today_iso(), _usage()))
    counter = TokenCounter(tmp_path, refresh_seconds=0)

    payload = current_payload(path=tmp_path / "nie-ma.json", counter=counter, now=NOW)

    assert payload["tokensIn"] == 1110
    assert payload["fiveHour"] == 0


def test_nothing_at_all_means_no_payload(tmp_path):
    counter = TokenCounter(tmp_path / "pusto", refresh_seconds=0)

    assert current_payload(path=tmp_path / "nie-ma.json", counter=counter, now=NOW) is None
