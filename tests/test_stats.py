"""Tests for the statistics document the GNOME Shell extension reads."""

from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path

from voiceflow.history import Record
from voiceflow.stats import build_stats, write_stats


def _record(timestamp: str, words: int, audio_seconds: float) -> Record:
    return Record(
        timestamp=timestamp,
        words=words,
        chars=words * 5,
        audio_seconds=audio_seconds,
        transcription_seconds=0.1,
        injected=True,
    )


def test_build_stats_reports_every_period() -> None:
    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 60.0),
        _record("2026-08-03T09:00:00+02:00", 100, 600.0),  # earlier month-to-date
    ]

    stats = build_stats(records, today=date(2026, 8, 10))

    assert stats["periods"]["day"] == {"seconds": 60.0, "words": 3, "dictations": 1}
    assert stats["periods"]["week"] == {"seconds": 60.0, "words": 3, "dictations": 1}
    assert stats["periods"]["month"] == {"seconds": 660.0, "words": 103, "dictations": 2}
    assert stats["periods"]["year"] == {"seconds": 660.0, "words": 103, "dictations": 2}


def test_build_stats_carries_raw_chart_series() -> None:
    records = [_record("2026-08-10T09:30:00+02:00", 3, 60.0)]

    stats = build_stats(records, today=date(2026, 8, 10))

    assert len(stats["hourly"]) == 24
    assert stats["hourly"][9] == 3
    assert len(stats["daily"]) == 14
    assert stats["daily"][-1] == {"date": "2026-08-10", "words": 3}
    assert stats["daily"][0]["date"] == "2026-07-28"


def test_build_stats_of_no_history_is_all_zero() -> None:
    stats = build_stats([], today=date(2026, 8, 10))

    assert stats["periods"]["year"] == {"seconds": 0.0, "words": 0, "dictations": 0}
    assert stats["hourly"] == [0] * 24
    assert all(entry["words"] == 0 for entry in stats["daily"])


def test_build_stats_timestamps_in_unix_seconds() -> None:
    """The extension subtracts this from its own clock to show "N min temu"."""
    before = int(datetime.now().timestamp())

    stats = build_stats([], today=date(2026, 8, 10))

    assert isinstance(stats["updated_at"], int)
    assert before <= int(stats["updated_at"]) <= before + 5


def test_write_stats_round_trips_through_the_file(tmp_path: Path) -> None:
    target = tmp_path / "stats.json"
    stats = build_stats([_record("2026-08-10T09:00:00+02:00", 3, 60.0)], today=date(2026, 8, 10))

    write_stats(stats, target)

    assert json.loads(target.read_text(encoding="utf-8")) == stats


def test_write_stats_replaces_previous_content_without_leaving_a_temp_file(tmp_path: Path) -> None:
    target = tmp_path / "stats.json"
    write_stats(build_stats([], today=date(2026, 8, 10)), target)

    write_stats(build_stats([_record("2026-08-10T09:00:00+02:00", 7, 60.0)], today=date(2026, 8, 10)), target)

    assert json.loads(target.read_text(encoding="utf-8"))["periods"]["day"]["words"] == 7
    assert list(tmp_path.iterdir()) == [target]


def test_write_stats_survives_an_unwritable_target(tmp_path: Path) -> None:
    """A stats write failure must never break the dictation that triggered it."""
    unwritable = tmp_path / "nie-ma" / "stats.json"

    write_stats(build_stats([], today=date(2026, 8, 10)), unwritable)

    assert not unwritable.exists()
