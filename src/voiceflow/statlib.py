"""Pure aggregation helpers for local dictation statistics.

Twin of ``app/voiceflow_app/statlib.py``. The two are deliberately separate
copies: the GTK application runs on the system Python so it can reach
PyGObject and must not import this package, while the Qt window ships inside
it. Both are pure functions over history records — keep them in step.
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable, Mapping
from datetime import date, datetime, timedelta
from typing import Any


def compact_number(value: int) -> str:
    """Format a count with a compact Polish suffix and at most three digits.

    Thousands below 100 use one decimal (``1,6 k``), three-digit thousands use
    none (``999 k``). Values from 999,500 round up into the millions band
    rather than showing a misleading ``1 000 k``.
    """
    number = int(value)
    sign = "−" if number < 0 else ""
    magnitude = abs(number)
    if magnitude < 1_000:
        return f"{sign}{magnitude}"
    if magnitude < 999_500:
        scaled = magnitude / 1_000
        return f"{sign}{_compact_scaled(scaled, 1 if scaled < 100 else 0)} k"
    scaled = magnitude / 1_000_000
    return f"{sign}{_compact_scaled(scaled, 1 if scaled < 100 else 0)} mln"


def _compact_scaled(value: float, decimals: int) -> str:
    """Render a scaled positive number without a redundant decimal zero."""
    rendered = f"{value:.{decimals}f}"
    if decimals:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered.replace(".", ",")


def local_datetime(timestamp: str) -> datetime:
    """Parse an ISO timestamp and convert aware values to local time."""
    parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return parsed.astimezone() if parsed.tzinfo is not None else parsed


def record_date(record: Mapping[str, Any]) -> date:
    """Return the local calendar date of a record."""
    return local_datetime(str(record["timestamp"])).date()


def daily_word_totals(records: Iterable[Mapping[str, Any]]) -> dict[date, int]:
    """Aggregate recognized words per local calendar day."""
    totals: defaultdict[date, int] = defaultdict(int)
    for record in records:
        try:
            totals[record_date(record)] += max(0, int(record.get("words", 0)))
        except (KeyError, TypeError, ValueError):
            continue
    return dict(totals)


def daily_series(
    records: Iterable[Mapping[str, Any]], days: int, *, today: date | None = None
) -> list[tuple[date, int]]:
    """Return a dense oldest-first daily series ending today."""
    if days <= 0:
        return []
    end = today or date.today()
    totals = daily_word_totals(records)
    start = end - timedelta(days=days - 1)
    return [
        (start + timedelta(days=index), totals.get(start + timedelta(days=index), 0))
        for index in range(days)
    ]


def current_streak(records: Iterable[Mapping[str, Any]], *, today: date | None = None) -> int:
    """Count consecutive active days backwards from today."""
    current = today or date.today()
    active = {day for day, words in daily_word_totals(records).items() if words > 0}
    streak = 0
    while current in active:
        streak += 1
        current -= timedelta(days=1)
    return streak


def totals(records: Iterable[Mapping[str, Any]]) -> dict[str, float | int]:
    """Return total words, dictations, audio duration, and average words."""
    items = list(records)
    words = sum(max(0, int(item.get("words", 0))) for item in items)
    audio = sum(max(0.0, float(item.get("audio_seconds", 0.0))) for item in items)
    return {
        "words": words,
        "dictations": len(items),
        "audio_seconds": audio,
        "average_words": words / len(items) if items else 0.0,
    }


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


def format_duration(seconds: float) -> str:
    """Format a duration as compact Polish hours and minutes."""
    total_minutes = max(0, round(seconds / 60))
    hours, minutes = divmod(total_minutes, 60)
    if hours and minutes:
        return f"{hours} godz. {minutes} min"
    if hours:
        return f"{hours} godz."
    return f"{minutes} min"
