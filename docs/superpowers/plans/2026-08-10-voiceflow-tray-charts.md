# Voiceflow Tray Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trim the tray label to `"58 min · 💬 7,8k"` (no more "słów" text) and
add two Cairo bar charts (today-by-hour, last-14-days) to the existing
click-open dropdown, alongside the week/month/year text lines already there.

**Architecture:** Extends the tray widget shipped earlier today
(`src/voiceflow/tray.py`, `src/voiceflow/statlib.py`,
`scripts/voiceflow-tray.py`, wired into `src/voiceflow/daemon.py`). Two new
pure aggregation functions in `statlib.py` feed a widened JSON protocol
between `Tray` (daemon side) and the AppIndicator subprocess; the subprocess
ports the existing bar-chart drawing code from the GTK4 settings app
(`app/voiceflow_app/pages/stats.py`) to GTK3.

**Tech Stack:** Python 3.13, PyGObject (GTK3, `AyatanaAppIndicator3` 0.1,
pycairo via `python3-gi-cairo` — already an installed system dependency),
pytest.

## Global Constraints

- All user-facing strings and log messages are Polish, matching every
  existing string in `src/voiceflow/*.py`. Code comments/docstrings stay
  English, matching this codebase's established convention (confirmed
  during the first tray iteration's reviews).
- Python target `>=3.13,<3.14`; `from __future__ import annotations`,
  modern union syntax (`X | None`).
- No new pip dependency. No new system package either — `python3-gi-cairo`
  is already installed by `scripts/install-system-deps.sh` (added earlier
  for the settings app's own charts) and `gir1.2-ayatanaappindicator3-0.1`
  is already installed for the tray itself.
- Every daemon-facing component stays best-effort: nothing in this change
  may raise out of `Tray.update()` or `VoiceflowDaemon._refresh_tray()` in
  a way that interrupts recording/transcription/injection.
- `src/voiceflow/statlib.py` stays a deliberate, self-contained sibling of
  `app/voiceflow_app/statlib.py` — do not import between the two packages
  (they run under different Python interpreters with no shared import
  path; see the first tray spec for the full reasoning).
- Tests via pytest, plain `test_*` functions, fakes as small local classes,
  no mocking framework.
- `scripts/voiceflow-tray.py` has no automated test coverage (needs
  PyGObject + a real GNOME display) — as with the first iteration, this is
  expected and verified manually, not a gap to fill with mocks.

---

### Task 1: `src/voiceflow/statlib.py` — hourly and daily series

**Files:**
- Modify: `src/voiceflow/statlib.py`
- Test: `tests/test_statlib.py`

**Interfaces:**
- Consumes: `voiceflow.history.Record` (existing).
- Produces (used by Task 2):
  - `hourly_word_totals(records: Iterable[Record], *, today: date | None = None) -> list[int]` — always exactly 24 elements, index = local hour (0–23), value = sum of `words` for today's records dictated in that hour.
  - `daily_series(records: Iterable[Record], days: int, *, today: date | None = None) -> list[tuple[date, int]]` — dense, oldest-first, length `days`, `(day, total_words)` per day, zero-filled for days with no dictation.
- `record_date()`'s existing public signature and behavior are unchanged — this task refactors its internals only.

- [ ] **Step 1: Write a failing test that pins `record_date`'s existing behavior through the refactor**

This isn't new behavior — it's a safety net for the internal refactor in Step 3. Add to `tests/test_statlib.py` (it duplicates the existing `test_record_date_reads_the_local_calendar_day` on purpose, as an explicit regression pin — do not remove the original):

```python
def test_record_date_still_works_after_the_hourly_refactor() -> None:
    record = _record("2026-08-10T23:30:00+02:00", 3, 12.0)
    assert record_date(record) == date(2026, 8, 10)
```

- [ ] **Step 2: Run it to verify it currently passes (it must — this step only proves the baseline before you touch anything)**

Run: `.venv/bin/pytest tests/test_statlib.py -v -k still_works`
Expected: PASS (unchanged behavior, no code touched yet).

- [ ] **Step 3: Write failing tests for `hourly_word_totals`**

```python
# append to tests/test_statlib.py

def test_hourly_word_totals_buckets_by_local_hour() -> None:
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
    result = hourly_word_totals([], today=date(2026, 8, 10))

    assert result == [0] * 24
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_statlib.py -v -k hourly`
Expected: FAIL — `ImportError: cannot import name 'hourly_word_totals'`

- [ ] **Step 5: Implement `_local_datetime`, refactor `record_date`, implement `hourly_word_totals`**

In `src/voiceflow/statlib.py`, replace the existing `record_date` function with:

```python
def _local_datetime(record: Record) -> datetime:
    """Parse a record's timestamp and convert it to local time."""
    parsed = datetime.fromisoformat(record.timestamp.replace("Z", "+00:00"))
    return parsed.astimezone() if parsed.tzinfo is not None else parsed


def record_date(record: Record) -> date:
    """Return the local calendar date a record was dictated on."""
    return _local_datetime(record).date()


def hourly_word_totals(records: Iterable[Record], *, today: date | None = None) -> list[int]:
    """Sum words per local hour (0-23) for records dictated today."""
    day = today or date.today()
    totals_by_hour = [0] * 24
    for record in records:
        local = _local_datetime(record)
        if local.date() != day:
            continue
        totals_by_hour[local.hour] += max(0, record.words)
    return totals_by_hour
```

(You need `import datetime` module's `datetime` class already imported at
the top of the file — it already is, alongside `date` and `timedelta`.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: all `record_date`/`hourly` tests PASS; `daily_series` tests (next) still fail with `ImportError`.

- [ ] **Step 7: Write failing tests for `daily_series`**

```python
# append to tests/test_statlib.py

def test_daily_series_is_dense_oldest_first_with_zero_fill() -> None:
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
    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 10.0),
        _record("2026-08-10T18:00:00+02:00", 4, 10.0),
    ]

    result = daily_series(records, 1, today=date(2026, 8, 10))

    assert result == [(date(2026, 8, 10), 7)]


def test_daily_series_of_zero_days_is_empty() -> None:
    assert daily_series([_record("2026-08-10T09:00:00+02:00", 3, 10.0)], 0, today=date(2026, 8, 10)) == []
```

- [ ] **Step 8: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_statlib.py -v -k daily_series`
Expected: FAIL — `ImportError: cannot import name 'daily_series'`

- [ ] **Step 9: Implement `daily_series`**

Append to `src/voiceflow/statlib.py`:

```python
def daily_series(
    records: Iterable[Record], days: int, *, today: date | None = None
) -> list[tuple[date, int]]:
    """Return a dense oldest-first daily word-count series ending today."""
    if days <= 0:
        return []
    end = today or date.today()
    start = end - timedelta(days=days - 1)
    totals_by_day: dict[date, int] = {}
    for record in records:
        day = record_date(record)
        if start <= day <= end:
            totals_by_day[day] = totals_by_day.get(day, 0) + max(0, record.words)
    return [
        (start + timedelta(days=offset), totals_by_day.get(start + timedelta(days=offset), 0))
        for offset in range(days)
    ]
```

- [ ] **Step 10: Run the full test file to verify everything passes**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: PASS, all tests green (including every test from the first tray iteration — nothing here should have broken them).

- [ ] **Step 11: Run the full suite once**

Run: `.venv/bin/pytest`
Expected: PASS, no warnings.

- [ ] **Step 12: Commit**

```bash
git add src/voiceflow/statlib.py tests/test_statlib.py
git commit -m "Add hourly_word_totals and daily_series to statlib"
```

---

### Task 2: `src/voiceflow/tray.py` — emoji label, wider payload, 4-arg `update()`

**Files:**
- Modify: `src/voiceflow/tray.py`
- Test: `tests/test_tray.py`

**Interfaces:**
- Consumes: `hourly_word_totals`, `daily_series` (Task 1); existing `compact_number`, `format_duration`, `period_bounds`, `record_date`, `totals`.
- Produces (used by Task 3):
  - `build_payload(records, *, today=None) -> dict[str, object]` — now returns `{"label": str, "summary": list[str], "hourly": list[int], "daily": list[tuple[date, int]]}`. The `"menu"` key is gone, replaced by `"summary"` (same three week/month/year strings, unchanged format). `"daily"` holds raw `(date, int)` tuples, NOT pre-serialized strings — serialization happens in `Tray.update()`.
  - `Tray.update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None` — was `update(self, label: str, menu: list[str])`.
  - `NullTray.update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None` — same signature, still a no-op.

- [ ] **Step 1: Update the existing `build_payload` tests for the new label format and key rename**

In `tests/test_tray.py`, replace these three existing tests (same names, new
expectations — do not add new test functions for this step, edit in place):

```python
def test_build_payload_label_is_todays_stats_only() -> None:
    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 60.0),
        _record("2026-08-09T09:00:00+02:00", 100, 600.0),  # yesterday, excluded
    ]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert payload["label"] == "1 min · 💬 3"


def test_build_payload_summary_has_week_month_year_in_order() -> None:
    records = [_record("2026-08-10T09:00:00+02:00", 3, 60.0)]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert len(payload["summary"]) == 3
    assert payload["summary"][0].startswith("Ten tydzień: ")
    assert payload["summary"][1].startswith("Ten miesiąc: ")
    assert payload["summary"][2].startswith("Ten rok: ")


def test_build_payload_of_no_history_is_all_zero() -> None:
    payload = build_payload([], today=date(2026, 8, 10))

    assert payload["label"] == "0 min · 💬 0"
    assert payload["summary"][0] == "Ten tydzień: 0 min · 0 słów"
```

- [ ] **Step 2: Write new failing tests for `hourly`/`daily` in `build_payload`**

```python
# append to tests/test_tray.py

def test_build_payload_hourly_is_24_values_for_today_only() -> None:
    records = [
        _record("2026-08-10T09:15:00+02:00", 3, 10.0),
        _record("2026-08-09T09:15:00+02:00", 999, 10.0),  # yesterday, excluded
    ]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert len(payload["hourly"]) == 24
    assert payload["hourly"][9] == 3
    assert sum(payload["hourly"]) == 3


def test_build_payload_daily_is_14_days_oldest_first() -> None:
    records = [_record("2026-08-10T09:15:00+02:00", 3, 10.0)]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert len(payload["daily"]) == 14
    assert payload["daily"][-1] == (date(2026, 8, 10), 3)
    assert payload["daily"][0][0] == date(2026, 7, 28)
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: FAIL — old label/summary assertions fail against current `"menu"`-keyed output; new `hourly`/`daily` tests fail with `KeyError`.

- [ ] **Step 4: Update `build_payload` in `src/voiceflow/tray.py`**

Replace the existing `build_payload` function and its imports:

```python
from voiceflow.statlib import (
    compact_number,
    daily_series,
    format_duration,
    hourly_word_totals,
    period_bounds,
    record_date,
    totals,
)
```

```python
def build_payload(records: Iterable[Record], *, today: date | None = None) -> dict[str, object]:
    """Aggregate history into the tray label, summary text, and chart series."""
    items = list(records)
    day = today or date.today()

    def duration_and_words(period: str) -> tuple[str, str]:
        start = period_bounds(period, today=day)
        subset = [record for record in items if record_date(record) >= start]
        stats = totals(subset)
        duration = format_duration(float(stats["audio_seconds"]))
        words = compact_number(int(stats["words"]))
        return duration, words

    today_duration, today_words = duration_and_words("day")
    label = f"{today_duration} · 💬 {today_words}"

    summary = []
    for period, title in _PERIODS:
        duration, words = duration_and_words(period)
        summary.append(f"{title}: {duration} · {words} słów")

    return {
        "label": label,
        "summary": summary,
        "hourly": hourly_word_totals(items, today=day),
        "daily": daily_series(items, 14, today=day),
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: the `build_payload` tests PASS; `Tray`/`NullTray` tests (next) still use the old 2-arg `update()` and will be updated in the next steps.

- [ ] **Step 6: Update the `Tray`/`NullTray` process tests for the new 4-arg `update()`**

In `tests/test_tray.py`, replace these existing tests in place (same names):

```python
def test_update_sends_label_summary_hourly_daily_preserving_polish_characters(tmp_path: Path) -> None:
    tray = _tray(tmp_path)
    tray.start()
    try:
        tray.update(
            "12 min · 💬 340",
            ["Ten tydzień: 3 godz. 10 min · 1,2 k słów"],
            [0] * 23 + [3],
            [(date(2026, 8, 10), 3)],
        )
        messages = _wait_for(tray.log, 1)
    finally:
        tray.stop()

    assert messages[0] == {
        "label": "12 min · 💬 340",
        "summary": ["Ten tydzień: 3 godz. 10 min · 1,2 k słów"],
        "hourly": [0] * 23 + [3],
        "daily": [{"date": "2026-08-10", "words": 3}],
    }
```

```python
def test_update_after_stop_does_not_raise(tmp_path: Path) -> None:
    """A dead indicator must never break the dictation flow."""
    tray = _tray(tmp_path)
    tray.start()
    tray.stop()

    tray.update("12 min · 💬 340", [], [0] * 24, [])

    assert tray.is_running is False
```

```python
def test_null_tray_methods_are_all_no_ops() -> None:
    tray = NullTray()

    tray.start()
    tray.update("x", ["y"], [0] * 24, [])
    tray.stop()
```

(The `test_update_sends_label_and_menu_preserving_polish_characters` test is
renamed and replaced by the first block above — delete the old one, don't
leave both.)

- [ ] **Step 7: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: FAIL — `Tray.update()` still takes 2 arguments.

- [ ] **Step 8: Update `Tray.update` and `NullTray.update` in `src/voiceflow/tray.py`**

Replace `Tray.update`:

```python
    def update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None:
        """Send one label/summary/chart update to the indicator."""
        payload = {
            "label": label,
            "summary": summary,
            "hourly": hourly,
            "daily": [{"date": day.isoformat(), "words": words} for day, words in daily],
        }
        self._write(json.dumps(payload, ensure_ascii=False) + "\n")
```

Replace `NullTray.update`:

```python
    def update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None:
        return
```

- [ ] **Step 9: Run the full test file to verify everything passes**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: PASS, all tests green.

- [ ] **Step 10: Run the full suite once**

Run: `.venv/bin/pytest`
Expected: FAIL is expected here, but only in `tests/test_daemon.py` (Task 3 updates the daemon's call site and its `_Tray` fake — those tests still call the old 2-arg shape until Task 3 lands). Confirm the *only* failures are in `tests/test_daemon.py` and that `tests/test_tray.py`/`tests/test_statlib.py` are fully green; if anything else fails, stop and investigate before committing.

- [ ] **Step 11: Commit**

```bash
git add src/voiceflow/tray.py tests/test_tray.py
git commit -m "Widen Tray payload to summary/hourly/daily, drop 'słów' from the label"
```

---

### Task 3: Wire the new payload shape into `VoiceflowDaemon`

**Files:**
- Modify: `src/voiceflow/daemon.py`
- Modify: `tests/test_daemon.py`

**Interfaces:**
- Consumes: `Tray.update(label, summary, hourly, daily)` (Task 2).
- Produces: no new public interface — `_refresh_tray()`'s internal call site changes shape only.

- [ ] **Step 1: Update the `_Tray` fake in `tests/test_daemon.py`**

Replace the existing `_Tray` class (currently right after the `_Overlay`
class):

```python
class _Tray:
    """Records tray calls instead of spawning a real indicator process."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def start(self) -> None:
        self.calls.append(("start", None, None))

    def update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple]) -> None:
        self.calls.append(("update", label, list(summary), list(hourly), list(daily)))

    def stop(self) -> None:
        self.calls.append(("stop", None, None))
```

- [ ] **Step 2: Update the tray-related test assertions**

`test_daemon_starts_the_tray_and_shows_zero_stats`: replace its final
assertion —

```python
    assert tray.calls[0] == ("start", None, None)
    call = tray.calls[1]
    assert call[0] == "update"
    assert call[1] == "0 min · 💬 0"
    assert call[2] == ["Ten tydzień: 0 min · 0 słów", "Ten miesiąc: 0 min · 0 słów", "Ten rok: 0 min · 0 słów"]
    assert call[3] == [0] * 24
    assert len(call[4]) == 14
    assert all(words == 0 for _day, words in call[4])
```

`test_dictation_pushes_fresh_stats_to_the_tray`: replace its final
assertion —

```python
    call = tray.calls[-1]
    assert call[0] == "update"
    assert call[1] == "1 min · 💬 3"
    assert call[2] == ["Ten tydzień: 1 min · 3 słów", "Ten miesiąc: 1 min · 3 słów", "Ten rok: 1 min · 3 słów"]
    assert len(call[3]) == 24
    assert sum(call[3]) == 3
    assert len(call[4]) == 14
    assert call[4][-1][1] == 3
```

`test_failed_injection_still_refreshes_the_tray`: same replacement as
`test_dictation_pushes_fresh_stats_to_the_tray` above (identical
expectations — the point of this test is that the failure path produces
the same refreshed call as the success path).

`test_disabled_tray_does_no_background_work` and `test_cleanup_stops_the_tray`
need no changes — they only assert on `"start"`/`"stop"` tuples, which are
unaffected by this task.

- [ ] **Step 3: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: FAIL — `TypeError: _refresh_tray.<locals>... update() missing 2 required positional arguments` (or similar), since `daemon.py`'s call site still passes 2 arguments.

- [ ] **Step 4: Update `_refresh_tray` in `src/voiceflow/daemon.py`**

Find the existing method (currently):

```python
    def _refresh_tray(self) -> None:
        try:
            records = read_records(self.history.path)
            payload = build_payload(records)
            self.tray.update(str(payload["label"]), list(payload["menu"]))  # type: ignore[arg-type]
        except Exception:
            LOGGER.exception("Nie można przeliczyć statystyk wskaźnika")
```

Replace it with:

```python
    def _refresh_tray(self) -> None:
        try:
            records = read_records(self.history.path)
            payload = build_payload(records)
            self.tray.update(
                str(payload["label"]),
                list(payload["summary"]),  # type: ignore[arg-type]
                list(payload["hourly"]),  # type: ignore[arg-type]
                list(payload["daily"]),  # type: ignore[arg-type]
            )
        except Exception:
            LOGGER.exception("Nie można przeliczyć statystyk wskaźnika")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_daemon.py -v`
Expected: PASS, all tests green.

- [ ] **Step 6: Run the full suite once**

Run: `.venv/bin/pytest`
Expected: PASS, no warnings, no hangs.

- [ ] **Step 7: Commit**

```bash
git add src/voiceflow/daemon.py tests/test_daemon.py
git commit -m "Pass summary/hourly/daily through to the tray on every refresh"
```

---

### Task 4: `scripts/voiceflow-tray.py` — render the two charts

**Files:**
- Modify: `scripts/voiceflow-tray.py` (full-file rewrite — small file, easier to replace wholesale than patch)

**Interfaces:**
- Consumes: JSON lines on stdin, each `{"label": str, "summary": list[str], "hourly": list[int] (24), "daily": list[{"date": "YYYY-MM-DD", "words": int}] (14)}`, written by `Tray.update()` (Task 2).
- Produces: nothing importable — standalone subprocess entry point, as before.

This task has no automated test coverage (documented in Global Constraints).
Verification is a syntax check plus, ideally, a manual run on a real GNOME
session (Step 2 below) — do not attempt the interactive run in a sandboxed
environment without a display; a syntax check is sufficient to complete
this task.

- [ ] **Step 1: Replace the full contents of `scripts/voiceflow-tray.py`**

```python
#!/usr/bin/python3
"""GNOME top-bar indicator for Voiceflow's dictation stats.

Reads one JSON object per stdin line —
{"label": str, "summary": list[str], "hourly": list[int] (24 entries),
 "daily": list[{"date": "YYYY-MM-DD", "words": int}] (14 entries)} —
and replaces the indicator's label and dropdown menu each time: the three
summary lines first, then two Cairo bar charts (today by hour, the last 14
days). Exits when stdin closes (the daemon calls Tray.stop(), which closes
its end of the pipe). Runs on the system Python because PyGObject /
AyatanaAppIndicator3 / pycairo are not available in the project's uv
virtualenv — see src/voiceflow/tray.py's module docstring.
"""

from __future__ import annotations

import json
import sys
import threading
from datetime import date, datetime

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3, GLib, Gtk  # noqa: E402

APP_ID = "io.github.avejapl.voiceflow-tray"

#: Matches app/voiceflow_app/pages/stats.py's DAY_NAMES exactly.
DAY_NAMES = ("pn", "wt", "śr", "cz", "pt", "sob", "nd")

HOURLY_WIDTH = 260
HOURLY_HEIGHT = 90
DAILY_WIDTH = 260
DAILY_HEIGHT = 110


def _rounded_top_bar(
    cr: cairo.Context, x: float, y: float, width: float, height: float, radius: float
) -> None:
    """Build a bar path with square lower and rounded upper corners.

    Ported from app/voiceflow_app/pages/stats.py's _rounded_top_bar — same
    geometry, GTK3's cairo.Context instead of GTK4's.
    """
    radius = min(radius, width / 2, height)
    cr.new_sub_path()
    cr.move_to(x, y + height)
    cr.line_to(x, y + radius)
    cr.arc(x + radius, y + radius, radius, 3.14159, 4.71239)
    cr.line_to(x + width - radius, y)
    cr.arc(x + width - radius, y + radius, radius, 4.71239, 6.28318)
    cr.line_to(x + width, y + height)
    cr.close_path()


class TrayApp:
    """Owns the AppIndicator and applies updates on the GLib main loop."""

    def __init__(self) -> None:
        self.indicator = AyatanaAppIndicator3.Indicator.new(
            APP_ID,
            "audio-input-microphone-symbolic",
            AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_label("…", "")
        empty_menu = Gtk.Menu()
        empty_menu.show_all()
        self.indicator.set_menu(empty_menu)
        self._hourly: list[int] = [0] * 24
        self._daily: list[tuple[date, int]] = []

    def apply(self, payload: dict) -> None:
        label = str(payload.get("label", ""))
        summary = [str(item) for item in payload.get("summary", [])]
        hourly = [int(value) for value in payload.get("hourly", [])]
        daily: list[tuple[date, int]] = []
        for entry in payload.get("daily", []):
            try:
                day = date.fromisoformat(str(entry["date"]))
                words = int(entry["words"])
            except (KeyError, TypeError, ValueError):
                continue
            daily.append((day, words))
        GLib.idle_add(self._apply_in_main_loop, label, summary, hourly, daily)

    def _apply_in_main_loop(
        self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]
    ) -> bool:
        self.indicator.set_label(label, "")
        self._hourly = hourly if len(hourly) == 24 else [0] * 24
        self._daily = daily

        menu = Gtk.Menu()
        for text in summary:
            entry = Gtk.MenuItem(label=text)
            entry.set_sensitive(False)
            entry.show()
            menu.append(entry)

        hourly_item = Gtk.MenuItem()
        hourly_item.set_sensitive(False)
        hourly_area = Gtk.DrawingArea()
        hourly_area.set_size_request(HOURLY_WIDTH, HOURLY_HEIGHT)
        hourly_area.connect("draw", self._draw_hourly)
        hourly_item.add(hourly_area)
        hourly_item.show_all()
        menu.append(hourly_item)

        daily_item = Gtk.MenuItem()
        daily_item.set_sensitive(False)
        daily_area = Gtk.DrawingArea()
        daily_area.set_size_request(DAILY_WIDTH, DAILY_HEIGHT)
        daily_area.connect("draw", self._draw_daily)
        daily_item.add(daily_area)
        daily_item.show_all()
        menu.append(daily_item)

        menu.show_all()
        self.indicator.set_menu(menu)
        return False

    def _draw_hourly(self, widget: Gtk.DrawingArea, cr: cairo.Context) -> bool:
        width = widget.get_allocated_width()
        height = widget.get_allocated_height()
        left, right, top, bottom = 4.0, 4.0, 6.0, 18.0
        usable_width = max(1.0, width - left - right)
        baseline = height - bottom
        chart_height = max(1.0, baseline - top)
        slot = usable_width / 24
        bar_width = max(2.0, slot * 0.6)
        maximum = max(self._hourly, default=0)
        current_hour = datetime.now().hour

        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(9)
        for hour, value in enumerate(self._hourly):
            x = left + hour * slot + (slot - bar_width) / 2
            if value > 0 and maximum > 0:
                bar_height = max(2.0, (value / maximum) * (chart_height - 4.0))
                alpha = 1.0 if hour == current_hour else 0.55
            else:
                bar_height = 2.0
                alpha = 0.35 if hour == current_hour else 0.07
            y = baseline - bar_height
            cr.set_source_rgba(1, 1, 1, alpha)
            _rounded_top_bar(cr, x, y, bar_width, bar_height, 1.5)
            cr.fill()

            if hour % 4 == 0:
                cr.set_source_rgba(1, 1, 1, 0.35)
                hour_label = f"{hour:02d}"
                extents = cr.text_extents(hour_label)
                cr.move_to(x + (bar_width - extents.width) / 2 - extents.x_bearing, height - 6)
                cr.show_text(hour_label)
        return False

    def _draw_daily(self, widget: Gtk.DrawingArea, cr: cairo.Context) -> bool:
        width = widget.get_allocated_width()
        height = widget.get_allocated_height()
        left, right, top, bottom = 4.0, 4.0, 16.0, 20.0
        usable_width = max(1.0, width - left - right)
        baseline = height - bottom
        chart_height = max(1.0, baseline - top)
        slot = usable_width / 14
        bar_width = max(4.0, min(16.0, slot * 0.5))
        maximum = max((value for _day, value in self._daily), default=0)
        today = date.today()
        peak_index = (
            max(range(len(self._daily)), key=lambda index: self._daily[index][1])
            if self._daily
            else 0
        )

        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        for index, (day, value) in enumerate(self._daily):
            x = left + index * slot + (slot - bar_width) / 2
            if value > 0 and maximum > 0:
                bar_height = max(2.0, (value / maximum) * (chart_height - 10.0))
                alpha = 0.55
            else:
                bar_height = 2.0
                alpha = 0.07
            y = baseline - bar_height
            cr.set_source_rgba(1, 1, 1, alpha)
            _rounded_top_bar(cr, x, y, bar_width, bar_height, 2.0)
            cr.fill()

            cr.set_font_size(8)
            cr.set_source_rgba(1, 1, 1, 1.0 if day == today else 0.35)
            day_label = DAY_NAMES[day.weekday()]
            extents = cr.text_extents(day_label)
            cr.move_to(x + (bar_width - extents.width) / 2 - extents.x_bearing, height - 6)
            cr.show_text(day_label)

            if index == peak_index and value > 0:
                peak_label = str(value)
                cr.set_font_size(8)
                cr.set_source_rgba(1, 1, 1, 0.55)
                peak_extents = cr.text_extents(peak_label)
                cr.move_to(
                    x + (bar_width - peak_extents.width) / 2 - peak_extents.x_bearing,
                    max(10, y - 4),
                )
                cr.show_text(peak_label)
        return False


def _read_stdin(app: TrayApp) -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        if isinstance(payload, dict):
            app.apply(payload)
    GLib.idle_add(Gtk.main_quit)


def main() -> int:
    app = TrayApp()
    threading.Thread(target=_read_stdin, args=(app,), daemon=True).start()
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Static verification**

Run: `/usr/bin/python3 -m py_compile scripts/voiceflow-tray.py`
Expected: no output, exit code 0.

If a real GNOME session with `gir1.2-ayatanaappindicator3-0.1` and
`python3-gi-cairo` is available (it is, on the machine this ships to — not
necessarily in a sandboxed implementer environment), also try running it
interactively and piping a payload with real `hourly`/`daily` data:

```bash
/usr/bin/python3 scripts/voiceflow-tray.py
```
then type (as one line):
```json
{"label": "58 min · 💬 7,8k", "summary": ["Ten tydzień: 3 godz. 10 min · 1,2 k słów", "Ten miesiąc: 5 godz. · 3,4 k słów", "Ten rok: 12 godz. · 9,1 k słów"], "hourly": [0,0,0,0,0,0,0,0,0,12,45,30,0,60,20,0,0,15,80,40,0,0,0,0], "daily": [{"date": "2026-07-28", "words": 120}, {"date": "2026-07-29", "words": 0}, {"date": "2026-07-30", "words": 340}, {"date": "2026-07-31", "words": 90}, {"date": "2026-08-01", "words": 0}, {"date": "2026-08-02", "words": 210}, {"date": "2026-08-03", "words": 0}, {"date": "2026-08-04", "words": 400}, {"date": "2026-08-05", "words": 150}, {"date": "2026-08-06", "words": 0}, {"date": "2026-08-07", "words": 300}, {"date": "2026-08-08", "words": 60}, {"date": "2026-08-09", "words": 500}, {"date": "2026-08-10", "words": 250}]}
```
Expected: icon shows `58 min · 💬 7,8k`; clicking it opens a menu with the
three text lines, then an hourly bar chart (peak visible around hours
10–13 and 18), then a 14-day bar chart with day labels. Press Ctrl+D to
exit.

If no display is available, the syntax check alone is sufficient to
complete this task — note in your report that the interactive check was
skipped and why.

- [ ] **Step 3: Run the full Python test suite once (docs-only-adjacent sanity check)**

Run: `.venv/bin/pytest`
Expected: PASS — this task doesn't touch any file the suite imports, so this just confirms nothing else regressed.

- [ ] **Step 4: Commit**

```bash
chmod +x scripts/voiceflow-tray.py
git add scripts/voiceflow-tray.py
git commit -m "Render hourly and 14-day bar charts in the tray dropdown"
```

---

## Manual End-to-End Verification (after all tasks)

Not automatable — run once, on the real machine:

1. `systemctl --user restart voiceflow.service`
2. Confirm the tray label reads like `"0 min · 💬 0"` (or today's real
   totals) — no "słów" text.
3. Dictate a couple of short sentences at different times if possible (or
   just once — the hourly chart will show a single bar).
4. Click the icon. Confirm: three text lines (week/month/year, unchanged
   format), then an hourly bar chart with the current hour visibly
   brighter than the rest, then a 14-day bar chart with day-of-week labels
   and today highlighted.
5. Check both charts render fully inside the dropdown without clipping —
   if the menu is too narrow/wide for `HOURLY_WIDTH`/`DAILY_WIDTH` (260px)
   on the actual panel theme, adjust those two constants in
   `scripts/voiceflow-tray.py` and restart the service again.
6. `systemctl --user stop voiceflow.service`; confirm the icon disappears.
