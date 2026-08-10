"""Aggregated statistics export for the GNOME Shell extension.

The panel widget lives in the shell's own process, where parsing a
20,000-line JSONL history on every menu open would stutter the whole
desktop. So the daemon — which already recomputes these numbers after every
dictation — writes them out here as a small, ready-to-render JSON document,
and the extension only reads and draws.

Deliberately free of pre-formatted strings: the extension renders Polish
labels and rounded numbers itself, so this file stays a data document rather
than a presentation one.
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Iterable
from datetime import date, datetime
from pathlib import Path

from voiceflow.history import Record
from voiceflow.paths import stats_file
from voiceflow.statlib import daily_series, hourly_word_totals, period_bounds, record_date, totals

LOGGER = logging.getLogger(__name__)

#: Days shown in the extension's "words per day" chart.
DAILY_DAYS = 14

_PERIODS: tuple[str, ...] = ("day", "week", "month", "year")


def build_stats(records: Iterable[Record], *, today: date | None = None) -> dict[str, object]:
    """Aggregate history into the document the extension renders."""
    items = list(records)
    day = today or date.today()

    periods: dict[str, dict[str, float | int]] = {}
    for period in _PERIODS:
        start = period_bounds(period, today=day)
        subset = [record for record in items if record_date(record) >= start]
        stats = totals(subset)
        periods[period] = {
            "seconds": round(float(stats["audio_seconds"]), 1),
            "words": int(stats["words"]),
            "dictations": int(stats["dictations"]),
        }

    return {
        "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "periods": periods,
        "hourly": hourly_word_totals(items, today=day),
        "daily": [
            {"date": entry_day.isoformat(), "words": words}
            for entry_day, words in daily_series(items, DAILY_DAYS, today=day)
        ],
    }


def write_stats(stats: dict[str, object], path: Path | None = None) -> None:
    """Persist the statistics document, replacing it atomically.

    Atomic because the extension may read at any moment: a half-written file
    would give it truncated JSON and a blank panel. Failures are logged, never
    raised — losing a stats refresh must not disturb dictation.
    """
    target = path or stats_file()
    tmp = target.with_suffix(".json.tmp")
    try:
        tmp.write_text(json.dumps(stats, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, target)
    except OSError as exc:
        LOGGER.warning("Nie można zapisać statystyk do %s: %s", target, exc)
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
