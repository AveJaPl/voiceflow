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


def test_record_date_still_works_after_the_hourly_refactor() -> None:
    from voiceflow.statlib import record_date

    record = _record("2026-08-10T23:30:00+02:00", 3, 12.0)
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


def test_hourly_word_totals_buckets_by_local_hour() -> None:
    from voiceflow.statlib import hourly_word_totals

    records = [
        _record("2026-08-10T09:15:00+02:00", 3, 10.0),
        _record("2026-08-10T09:45:00+02:00", 5, 10.0),   # same hour, same day
        _record("2026-08-10T14:00:00+02:00", 7, 10.0),   # different hour
        _record("2026-08-09T09:00:00+02:00", 100, 10.0),  # yesterday, excluded
    ]

    result = hourly_word_totals(records, today=date(2026, 8, 10))

    assert len(result) == 24
    assert result[9] == 8
    assert result[14] == 7
    assert result[0] == 0
    assert sum(result) == 15


def test_hourly_word_totals_of_no_history_is_24_zeros() -> None:
    from voiceflow.statlib import hourly_word_totals

    result = hourly_word_totals([], today=date(2026, 8, 10))

    assert result == [0] * 24


def test_daily_series_is_dense_oldest_first_with_zero_fill() -> None:
    from voiceflow.statlib import daily_series

    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 10.0),
        _record("2026-08-08T09:00:00+02:00", 5, 10.0),
        _record("2026-08-01T09:00:00+02:00", 999, 10.0),  # outside the 3-day window
    ]

    result = daily_series(records, 3, today=date(2026, 8, 10))

    assert result == [
        (date(2026, 8, 8), 5),
        (date(2026, 8, 9), 0),
        (date(2026, 8, 10), 3),
    ]


def test_daily_series_sums_multiple_records_on_the_same_day() -> None:
    from voiceflow.statlib import daily_series

    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 10.0),
        _record("2026-08-10T18:00:00+02:00", 4, 10.0),
    ]

    result = daily_series(records, 1, today=date(2026, 8, 10))

    assert result == [(date(2026, 8, 10), 7)]


def test_daily_series_of_zero_days_is_empty() -> None:
    from voiceflow.statlib import daily_series

    assert daily_series([_record("2026-08-10T09:00:00+02:00", 3, 10.0)], 0, today=date(2026, 8, 10)) == []
