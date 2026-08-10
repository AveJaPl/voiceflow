"""Tests for the daemon's own stats aggregation (Record-typed, not Mapping)."""

from __future__ import annotations

from datetime import date

from voiceflow.history import Record
from voiceflow.statlib import (
    compact_number,
    format_duration,
)


def test_compact_number_below_a_thousand_is_unchanged() -> None:
    assert compact_number(0) == "0"
    assert compact_number(999) == "999"


def test_compact_number_thousands_get_one_decimal_below_a_hundred() -> None:
    assert compact_number(1_600) == "1,6 k"
    assert compact_number(12_300) == "12,3 k"


def test_compact_number_three_digit_thousands_drop_the_decimal() -> None:
    assert compact_number(999_000) == "999 k"


def test_compact_number_rounds_up_into_millions() -> None:
    assert compact_number(999_600) == "1 mln"


def test_format_duration_hours_and_minutes() -> None:
    assert format_duration(60) == "1 min"
    assert format_duration(3600) == "1 godz."
    assert format_duration(3600 + 15 * 60) == "1 godz. 15 min"


def _record(timestamp: str, words: int, audio_seconds: float) -> Record:
    return Record(
        timestamp=timestamp,
        words=words,
        chars=words * 5,
        audio_seconds=audio_seconds,
        transcription_seconds=0.1,
        injected=True,
    )


def test_record_date_reads_the_local_calendar_day() -> None:
    from voiceflow.statlib import record_date

    record = _record("2026-08-10T09:30:00+02:00", 3, 12.0)
    assert record_date(record) == date(2026, 8, 10)


def test_totals_sums_words_and_audio_seconds() -> None:
    from voiceflow.statlib import totals

    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 10.0),
        _record("2026-08-10T10:00:00+02:00", 5, 20.0),
    ]

    result = totals(records)

    assert result == {"words": 8, "dictations": 2, "audio_seconds": 30.0}


def test_totals_of_empty_list_is_all_zero() -> None:
    from voiceflow.statlib import totals

    assert totals([]) == {"words": 0, "dictations": 0, "audio_seconds": 0.0}


def test_period_bounds_day_is_today() -> None:
    from voiceflow.statlib import period_bounds

    assert period_bounds("day", today=date(2026, 8, 10)) == date(2026, 8, 10)


def test_period_bounds_week_starts_on_monday() -> None:
    from voiceflow.statlib import period_bounds

    # 2026-08-10 is a Monday; 2026-08-13 (Thursday) must map back to it.
    assert period_bounds("week", today=date(2026, 8, 13)) == date(2026, 8, 10)


def test_period_bounds_week_can_cross_into_the_previous_month() -> None:
    from voiceflow.statlib import period_bounds

    # 2026-08-01 is a Saturday; its Monday is 2026-07-27.
    assert period_bounds("week", today=date(2026, 8, 1)) == date(2026, 7, 27)


def test_period_bounds_month_is_the_first_day() -> None:
    from voiceflow.statlib import period_bounds

    assert period_bounds("month", today=date(2026, 8, 13)) == date(2026, 8, 1)


def test_period_bounds_year_is_january_first() -> None:
    from voiceflow.statlib import period_bounds

    assert period_bounds("year", today=date(2026, 8, 13)) == date(2026, 1, 1)


def test_period_bounds_rejects_unknown_period() -> None:
    from voiceflow.statlib import period_bounds

    import pytest

    with pytest.raises(ValueError):
        period_bounds("decade", today=date(2026, 8, 13))
