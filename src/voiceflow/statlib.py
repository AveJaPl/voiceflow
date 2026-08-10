"""Pure aggregation helpers for the tray widget's day/week/month/year stats.

A deliberate sibling of app/voiceflow_app/statlib.py, not a shared import:
see the module docstring notes in the implementation plan / design spec for
why the two packages cannot import each other.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import date, datetime, timedelta

from voiceflow.history import Record


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


def record_date(record: Record) -> date:
    """Return the local calendar date a record was dictated on."""
    parsed = datetime.fromisoformat(record.timestamp.replace("Z", "+00:00"))
    local = parsed.astimezone() if parsed.tzinfo is not None else parsed
    return local.date()


def totals(records: Iterable[Record]) -> dict[str, float | int]:
    """Return total words, dictation count, and audio duration."""
    items = list(records)
    words = sum(max(0, item.words) for item in items)
    audio = sum(max(0.0, item.audio_seconds) for item in items)
    return {"words": words, "dictations": len(items), "audio_seconds": audio}


def period_bounds(period: str, *, today: date | None = None) -> date:
    """Return the local calendar start date of a period ending today.

    "week" starts on Monday (ISO), matching the activity calendar in
    app/voiceflow_app/statlib.py.
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
