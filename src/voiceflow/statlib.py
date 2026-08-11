"""Pure aggregation helpers over dictation history.

Two callers with different data shapes share this module, which is why every
function here accepts either one. The tray and the stats export work with
:class:`voiceflow.history.Record` objects; the desktop window reads the JSONL
file itself and passes raw mappings straight through. Converting on one side
would mean the other pays for a translation it does not need, so the field
access is what bends instead — see :func:`_field`.

Everything here is pure: no clock beyond an injectable ``today``, no I/O. That
is what makes the numbers on screen testable without a history file.
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable, Mapping
from datetime import date, datetime, timedelta
from typing import Any


def _field(record: Any, name: str, default: Any) -> Any:
    """Read a field from a Record dataclass or a raw history mapping."""
    if isinstance(record, Mapping):
        return record.get(name, default)
    return getattr(record, name, default)


def compact_number(value: int) -> str:
    """Format a count with a compact Polish suffix and at most three digits.

    Thousands below 100 use one decimal (``1,6 k`` / ``12,3 k``), three-digit
    thousands use none (``999 k``). Values from 999,500 round into the
    millions band instead of displaying the misleading ``1 000 k``.
    """
    number = int(value)
    sign = "−" if number < 0 else ""
    magnitude = abs(number)
    if magnitude < 1_000:
        return f"{sign}{magnitude}"

    if magnitude < 999_500:
        scaled = magnitude / 1_000
        decimals = 1 if scaled < 100 else 0
        return f"{sign}{_compact_scaled(scaled, decimals)} k"

    scaled = magnitude / 1_000_000
    decimals = 1 if scaled < 100 else 0
    return f"{sign}{_compact_scaled(scaled, decimals)} mln"


def _compact_scaled(value: float, decimals: int) -> str:
    rendered = f"{value:.{decimals}f}"
    if decimals:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered.replace(".", ",")


def format_duration(seconds: float) -> str:
    """Format a duration as compact Polish hours and minutes."""
    total_minutes = max(0, round(seconds / 60))
    hours, minutes = divmod(total_minutes, 60)
    if hours and minutes:
        return f"{hours} godz. {minutes} min"
    if hours:
        return f"{hours} godz."
    return f"{minutes} min"


def local_datetime(timestamp: str) -> datetime:
    """Parse an ISO timestamp and convert aware values to local time."""
    parsed = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
    return parsed.astimezone() if parsed.tzinfo is not None else parsed


def _record_datetime(record: Any) -> datetime:
    return local_datetime(str(_field(record, "timestamp", "")))


def record_date(record: Any) -> date:
    """Return the local calendar date a record was dictated on."""
    return _record_datetime(record).date()


def _words(record: Any) -> int:
    try:
        return max(0, int(_field(record, "words", 0)))
    except (TypeError, ValueError):
        return 0


def hourly_word_totals(records: Iterable[Any], *, today: date | None = None) -> list[int]:
    """Sum words per local hour (0-23) for records dictated today."""
    day = today or date.today()
    totals_by_hour = [0] * 24
    for record in records:
        try:
            local = _record_datetime(record)
        except (KeyError, TypeError, ValueError):
            continue
        if local.date() != day:
            continue
        totals_by_hour[local.hour] += _words(record)
    return totals_by_hour


def daily_word_totals(records: Iterable[Any]) -> dict[date, int]:
    """Aggregate recognized words per local calendar day."""
    totals_by_day: defaultdict[date, int] = defaultdict(int)
    for record in records:
        try:
            totals_by_day[record_date(record)] += _words(record)
        except (KeyError, TypeError, ValueError):
            continue
    return dict(totals_by_day)


def totals(records: Iterable[Any]) -> dict[str, float | int]:
    """Return total words, dictation count, audio duration, and the average."""
    items = list(records)
    words = sum(_words(item) for item in items)
    audio = 0.0
    for item in items:
        try:
            audio += max(0.0, float(_field(item, "audio_seconds", 0.0)))
        except (TypeError, ValueError):
            continue
    return {
        "words": words,
        "dictations": len(items),
        "audio_seconds": audio,
        "average_words": words / len(items) if items else 0.0,
    }


def period_bounds(period: str, *, today: date | None = None) -> date:
    """Return the local calendar start date of a period ending today.

    "week" starts on Monday (ISO), matching the activity calendar.
    """
    day = today or date.today()
    if period == "day":
        return day
    if period == "week":
        return day - timedelta(days=day.weekday())
    if period == "month":
        return day.replace(day=1)
    if period == "year":
        return day.replace(month=1, day=1)
    raise ValueError(f"nieznany okres: {period!r}")


def daily_series(
    records: Iterable[Any], days: int, *, today: date | None = None
) -> list[tuple[date, int]]:
    """Return a dense oldest-first daily word-count series ending today."""
    if days <= 0:
        return []
    end = today or date.today()
    by_day = daily_word_totals(records)
    start = end - timedelta(days=days - 1)
    return [
        (start + timedelta(days=index), by_day.get(start + timedelta(days=index), 0))
        for index in range(days)
    ]


def current_streak(records: Iterable[Any], *, today: date | None = None) -> int:
    """Count consecutive active days backwards from today."""
    current = today or date.today()
    active = {day for day, words in daily_word_totals(records).items() if words > 0}
    streak = 0
    while current in active:
        streak += 1
        current -= timedelta(days=1)
    return streak


def quantile_thresholds(values: Iterable[int]) -> tuple[int, int, int]:
    """Return nearest-rank 25th, 50th, and 75th percentiles of positive values."""
    ordered = sorted(value for value in values if value > 0)
    if not ordered:
        return (0, 0, 0)

    def percentile(fraction: float) -> int:
        index = max(0, math.ceil(fraction * len(ordered)) - 1)
        return ordered[index]

    return percentile(0.25), percentile(0.50), percentile(0.75)


def activity_level(value: int, thresholds: tuple[int, int, int]) -> int:
    """Map a word count to one of five activity levels (zero through four)."""
    if value <= 0:
        return 0
    q1, q2, q3 = thresholds
    if value <= q1:
        return 1
    if value <= q2:
        return 2
    if value <= q3:
        return 3
    return 4


def activity_levels(series: Iterable[tuple[date, int]]) -> dict[date, int]:
    """Calculate quantile-based activity levels for a dense daily series."""
    items = list(series)
    thresholds = quantile_thresholds(value for _day, value in items)
    return {day: activity_level(value, thresholds) for day, value in items}
