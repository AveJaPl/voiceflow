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
