"""Tests for the dictation history log."""

from __future__ import annotations

import json
from pathlib import Path

from voiceflow.config import HistoryConfig, parse_config
from voiceflow.history import History, Record, read_records


def _record(text: str = "zażółć gęślą jaźń", *, store_text: bool = True) -> Record:
    return Record.now(
        text,
        audio_seconds=3.21,
        transcription_seconds=0.045,
        injected=True,
        store_text=store_text,
    )


def test_append_and_read_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "history.jsonl"
    history = History(HistoryConfig(), path)

    history.append(_record())
    records = read_records(path)

    assert len(records) == 1
    assert records[0].text == "zażółć gęślą jaźń"
    assert records[0].words == 3
    assert records[0].injected is True


def test_store_text_false_keeps_counts_only(tmp_path: Path) -> None:
    """Privacy mode: statistics survive, transcripts do not."""
    path = tmp_path / "history.jsonl"
    History(HistoryConfig(store_text=False), path).append(_record(store_text=False))

    records = read_records(path)

    assert records[0].text is None
    assert records[0].words == 3
    assert "zażółć" not in path.read_text(encoding="utf-8")


def test_disabled_history_writes_nothing(tmp_path: Path) -> None:
    path = tmp_path / "history.jsonl"
    History(HistoryConfig(enabled=False), path).append(_record())

    assert not path.exists()


def test_prune_keeps_newest_entries(tmp_path: Path) -> None:
    path = tmp_path / "history.jsonl"
    grower = History(HistoryConfig(max_entries=1000), path)
    for index in range(5):
        grower.append(_record(f"wpis numer {index}"))

    History(HistoryConfig(max_entries=2), path)  # prune runs at construction

    records = read_records(path)
    assert [r.text for r in records] == ["wpis numer 3", "wpis numer 4"]


def test_unparseable_lines_are_skipped(tmp_path: Path) -> None:
    path = tmp_path / "history.jsonl"
    History(HistoryConfig(), path).append(_record())
    with path.open("a", encoding="utf-8") as handle:
        handle.write("to nie jest json\n")
        handle.write(json.dumps({"words": "czterdzieści"}) + "\n")

    records = read_records(path)

    assert len(records) == 1


def test_read_limit_returns_newest(tmp_path: Path) -> None:
    path = tmp_path / "history.jsonl"
    history = History(HistoryConfig(), path)
    for index in range(10):
        history.append(_record(f"wpis {index}"))

    records = read_records(path, limit=3)

    assert [r.text for r in records] == ["wpis 7", "wpis 8", "wpis 9"]


def test_missing_file_reads_empty(tmp_path: Path) -> None:
    assert read_records(tmp_path / "nie-ma.jsonl") == []


def test_config_parses_history_section() -> None:
    config = parse_config({"history": {"enabled": False, "store_text": False, "max_entries": 50}})

    assert config.history.enabled is False
    assert config.history.store_text is False
    assert config.history.max_entries == 50


def test_macos_written_line_is_readable_here(tmp_path: Path) -> None:
    """The macOS app writes this exact shape; the shared reader must accept it.

    macOS is a separate Swift implementation (`macos/VoiceFlow/Model/NotesStore.swift`)
    that persists history in this format so one dictation log works the same on
    every platform. It adds keys of its own — `id`, `raw_text`, `target_bundle_id`
    — which this reader has to ignore rather than choke on. If that stops being
    true, statistics and history silently break on the Mac and nowhere else.
    """
    path = tmp_path / "history.jsonl"
    path.write_text(
        '{"audio_seconds":2.35,"chars":19,"id":"7B1E1A3E-0000-4000-8000-000000000001",'
        '"injected":true,"raw_text":"dzień dobry panstwu","target_bundle_id":"com.apple.Safari",'
        '"text":"Dzień dobry państwu.","timestamp":"2026-08-11T14:03:21+02:00",'
        '"transcription_seconds":0,"words":3}\n',
        encoding="utf-8",
    )

    records = read_records(path)

    assert len(records) == 1
    record = records[0]
    assert record.text == "Dzień dobry państwu."
    assert record.words == 3
    assert record.chars == 19
    assert record.audio_seconds == 2.35
    assert record.injected is True


def test_macos_line_feeds_the_shared_statistics(tmp_path: Path) -> None:
    """The point of sharing the format: the same stats code works on the Mac."""
    from datetime import date

    from voiceflow.statlib import daily_series, totals

    path = tmp_path / "history.jsonl"
    path.write_text(
        '{"audio_seconds":4.0,"chars":10,"injected":true,"text":"raz dwa trzy",'
        '"timestamp":"2026-08-11T09:00:00+02:00","transcription_seconds":0,"words":3}\n'
        '{"audio_seconds":6.0,"chars":8,"injected":false,"text":"cztery piec",'
        '"timestamp":"2026-08-11T10:00:00+02:00","transcription_seconds":0,"words":2}\n',
        encoding="utf-8",
    )

    records = read_records(path)
    summary = totals(records)

    assert summary["words"] == 5
    assert summary["dictations"] == 2
    assert summary["audio_seconds"] == 10.0
    assert daily_series(records, 1, today=date(2026, 8, 11)) == [(date(2026, 8, 11), 5)]
