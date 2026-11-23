# Voiceflow Tray Stats Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GNOME top-bar indicator, driven by the Voiceflow daemon, showing
today's dictation stats (time spoken + word count, rounded) with a click-open
menu of this week/month/year.

**Architecture:** A new `Tray` controller in `src/voiceflow/tray.py` mirrors
the existing `Overlay` controller (`src/voiceflow/overlay.py`) exactly:
the daemon spawns a companion script with the *system* Python (the project's
`uv` virtualenv has no PyGObject) and feeds it one JSON object per line on
stdin. The companion script (`scripts/voiceflow-tray.py`) holds an
`AyatanaAppIndicator3` icon and just renders whatever label/menu text it is
told to show — all aggregation math happens daemon-side, in pure functions
that are unit tested normally.

**Tech Stack:** Python 3.13, dataclasses, PyGObject (`AyatanaAppIndicator3`
0.1, system Python only), pytest, PyYAML for config.

## Global Constraints

- All user-facing strings and log messages are Polish, matching every existing
  string in `src/voiceflow/*.py` (see `LOGGER.warning("Nie można...", ...)`
  throughout the codebase).
- Python target is `>=3.13,<3.14` (`pyproject.toml`); use `from __future__
  import annotations` and modern union syntax (`X | None`) as the rest of
  `src/voiceflow` does.
- No new pip dependency: `AyatanaAppIndicator3` is a system GI typelib
  (`gir1.2-ayatanaappindicator3-0.1`), loaded the same way GTK already is in
  `scripts/voiceflow-overlay.py` — never added to `pyproject.toml`.
- Every daemon-facing component must be best-effort: a missing script, a
  missing system Python, or a crashed child process must only log a warning
  and never interrupt recording/transcription/injection. This is the
  existing contract for `Overlay` (`src/voiceflow/overlay.py`) and applies
  identically to `Tray`.
- Tests live in `tests/`, run via `pytest` (`testpaths = ["tests"]`,
  `addopts = "-ra"` per `pyproject.toml`). Follow the existing test style:
  plain functions named `test_*`, fakes/stubs as small local classes (see
  `tests/test_daemon.py`, `tests/test_overlay.py`), no mocking framework.
- This feature is Linux-only (GNOME/AppIndicator). Do not touch
  `src/voiceflow/winplat/*`; on Windows the daemon must use a no-op tray.

---

### Task 1: `src/voiceflow/statlib.py` — pure aggregation for the daemon

**Files:**
- Create: `src/voiceflow/statlib.py`
- Test: `tests/test_statlib.py`

**Interfaces:**
- Consumes: `voiceflow.history.Record` (existing frozen dataclass with fields
  `timestamp: str`, `words: int`, `chars: int`, `audio_seconds: float`,
  `transcription_seconds: float`, `injected: bool`, `text: str | None`).
- Produces (used by Task 3):
  - `compact_number(value: int) -> str`
  - `record_date(record: Record) -> date`
  - `totals(records: Iterable[Record]) -> dict[str, float | int]` — keys
    `"words"` (int), `"dictations"` (int), `"audio_seconds"` (float).
  - `format_duration(seconds: float) -> str`
  - `period_bounds(period: str, *, today: date | None = None) -> date` —
    `period` is one of `"day" | "week" | "month" | "year"`; raises
    `ValueError` for anything else.

This module is a deliberate, small duplicate of four functions that already
exist in `app/voiceflow_app/statlib.py`. That module operates on raw
`Mapping`/`HistoryRecord` because the settings app runs under the system
Python via `scripts/voiceflow-app.py` (`sys.path.insert(0, .../app)`), which
never puts `src/voiceflow` on its import path — the same reason
`app/voiceflow_app/services.py` re-implements JSONL reading instead of
importing `voiceflow.history`. Do not attempt to import between the two
packages or merge the modules.

- [ ] **Step 1: Write failing tests for `compact_number` and `format_duration`**

```python
# tests/test_statlib.py
"""Tests for the daemon's own stats aggregation (Record-typed, not Mapping)."""

from __future__ import annotations

from datetime import date

from voiceflow.history import Record
from voiceflow.statlib import (
    compact_number,
    format_duration,
    period_bounds,
    record_date,
    totals,
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'voiceflow.statlib'`

- [ ] **Step 3: Implement `compact_number` and `format_duration`**

```python
# src/voiceflow/statlib.py
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: the 5 tests written so far PASS; remaining tests in the file still
FAIL with `ImportError` (`record_date`, `period_bounds`, `totals` not yet
defined) — that is expected at this point.

- [ ] **Step 5: Write failing tests for `record_date` and `totals`**

```python
# append to tests/test_statlib.py

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
    record = _record("2026-08-10T09:30:00+02:00", 3, 12.0)
    assert record_date(record) == date(2026, 8, 10)


def test_totals_sums_words_and_audio_seconds() -> None:
    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 10.0),
        _record("2026-08-10T10:00:00+02:00", 5, 20.0),
    ]

    result = totals(records)

    assert result == {"words": 8, "dictations": 2, "audio_seconds": 30.0}


def test_totals_of_empty_list_is_all_zero() -> None:
    assert totals([]) == {"words": 0, "dictations": 0, "audio_seconds": 0.0}
```

- [ ] **Step 6: Run tests to verify the new ones fail**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: FAIL — `ImportError: cannot import name 'record_date'`

- [ ] **Step 7: Implement `record_date` and `totals`**

```python
# append to src/voiceflow/statlib.py

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
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: all tests except `period_bounds` ones PASS (still one `ImportError`
left for `period_bounds`).

- [ ] **Step 9: Write failing tests for `period_bounds`**

```python
# append to tests/test_statlib.py

def test_period_bounds_day_is_today() -> None:
    assert period_bounds("day", today=date(2026, 8, 10)) == date(2026, 8, 10)


def test_period_bounds_week_starts_on_monday() -> None:
    # 2026-08-10 is a Monday; 2026-08-13 (Thursday) must map back to it.
    assert period_bounds("week", today=date(2026, 8, 13)) == date(2026, 8, 10)


def test_period_bounds_week_can_cross_into_the_previous_month() -> None:
    # 2026-08-01 is a Saturday; its Monday is 2026-07-27.
    assert period_bounds("week", today=date(2026, 8, 1)) == date(2026, 7, 27)


def test_period_bounds_month_is_the_first_day() -> None:
    assert period_bounds("month", today=date(2026, 8, 13)) == date(2026, 8, 1)


def test_period_bounds_year_is_january_first() -> None:
    assert period_bounds("year", today=date(2026, 8, 13)) == date(2026, 1, 1)


def test_period_bounds_rejects_unknown_period() -> None:
    import pytest

    with pytest.raises(ValueError):
        period_bounds("decade", today=date(2026, 8, 13))
```

- [ ] **Step 10: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: FAIL — `ImportError: cannot import name 'period_bounds'`

- [ ] **Step 11: Implement `period_bounds`**

```python
# append to src/voiceflow/statlib.py

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
```

- [ ] **Step 12: Run the full test file to verify everything passes**

Run: `.venv/bin/pytest tests/test_statlib.py -v`
Expected: PASS, all tests green.

- [ ] **Step 13: Commit**

```bash
git add src/voiceflow/statlib.py tests/test_statlib.py
git commit -m "Add daemon-side stats aggregation (day/week/month/year)"
```

---

### Task 2: `TrayConfig`

**Files:**
- Modify: `src/voiceflow/config.py`
- Test: `tests/test_config.py`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 3 and Task 5): `TrayConfig` dataclass with field
  `enabled: bool = True`; `Config.tray: TrayConfig` field.

- [ ] **Step 1: Write a failing test for the new config section**

```python
# append to tests/test_config.py

def test_tray_defaults_to_enabled() -> None:
    config = parse_config({})

    assert config.tray.enabled is True


def test_tray_can_be_disabled() -> None:
    config = parse_config({"tray": {"enabled": False}})

    assert config.tray.enabled is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_config.py -v -k tray`
Expected: FAIL — `AttributeError: 'Config' object has no attribute 'tray'`

- [ ] **Step 3: Add `TrayConfig`, wire it into `Config`, `_SCHEMA`, `_parse`, and `DEFAULT_CONFIG`**

In `src/voiceflow/config.py`, immediately after the existing `OverlayConfig`
class (around line 246-247):

```python
@dataclass(frozen=True, slots=True)
class TrayConfig:
    """GNOME top-bar dictation-stats indicator settings."""

    enabled: bool = True
```

In the `Config` dataclass, add a field right after `overlay`:

```python
    overlay: OverlayConfig = field(default_factory=OverlayConfig)
    tray: TrayConfig = field(default_factory=TrayConfig)
```

In `_SCHEMA`, add a line right after `"overlay": {"enabled"},`:

```python
    "overlay": {"enabled"},
    "tray": {"enabled"},
```

In the parsing function, add a `_section` call next to the `overlay` one:

```python
    overlay = _section(root, "overlay")
    tray = _section(root, "tray")
```

And in the `Config(...)` construction, right after the `overlay=OverlayConfig(...)` block:

```python
        overlay=OverlayConfig(
            enabled=_boolean(overlay.get("enabled", True), True, "overlay.enabled"),
        ),
        tray=TrayConfig(
            enabled=_boolean(tray.get("enabled", True), True, "tray.enabled"),
        ),
```

Finally, in `DEFAULT_CONFIG`, add a section right after the `overlay:` block
(before `notifications:`):

```yaml
tray:
  # Top-bar icon showing today's speaking time and word count; click for
  # this week/month/year. Needs gir1.2-ayatanaappindicator3-0.1 (installed
  # automatically by install.sh); silently absent if that package is missing.
  enabled: true
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_config.py -v`
Expected: PASS, including the two new tests and all pre-existing ones
(watch for `test_first_load_creates_commented_file`, which reads
`DEFAULT_CONFIG` back through `parse_config` — the new section must parse
cleanly).

- [ ] **Step 5: Commit**

```bash
git add src/voiceflow/config.py tests/test_config.py
git commit -m "Add TrayConfig for the GNOME stats indicator"
```

---

### Task 3: `src/voiceflow/tray.py` — the `Tray` controller

**Files:**
- Create: `src/voiceflow/tray.py`
- Test: `tests/test_tray.py`

**Interfaces:**
- Consumes: `TrayConfig` (Task 2), `voiceflow.history.Record` and
  `voiceflow.statlib.{compact_number, format_duration, period_bounds,
  record_date, totals}` (Task 1).
- Produces (used by Task 5):
  - `tray_script_path() -> Path`
  - `build_payload(records: Iterable[Record], *, today: date | None = None) -> dict[str, object]` — returns `{"label": str, "menu": list[str]}`.
  - `class Tray`: `__init__(self, config: TrayConfig, script: Path | None = None) -> None`, `is_running: bool` (property), `start(self) -> None`, `update(self, label: str, menu: list[str]) -> None`, `stop(self) -> None`.
  - `class NullTray`: same three methods (`start`, `update`, `stop`) as
    no-ops, no constructor arguments — used on Windows.

- [ ] **Step 1: Write failing tests for `build_payload`**

```python
# tests/test_tray.py
"""Tests for the tray controller, using a stub script instead of a real icon."""

from __future__ import annotations

import json
import time
from datetime import date
from pathlib import Path

from voiceflow.config import TrayConfig
from voiceflow.history import Record
from voiceflow.tray import NullTray, Tray, build_payload


def _record(timestamp: str, words: int, audio_seconds: float) -> Record:
    return Record(
        timestamp=timestamp,
        words=words,
        chars=words * 5,
        audio_seconds=audio_seconds,
        transcription_seconds=0.1,
        injected=True,
    )


def test_build_payload_label_is_todays_stats_only() -> None:
    records = [
        _record("2026-08-10T09:00:00+02:00", 3, 60.0),
        _record("2026-08-09T09:00:00+02:00", 100, 600.0),  # yesterday, excluded
    ]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert payload["label"] == "1 min · 3 słów"


def test_build_payload_menu_has_week_month_year_in_order() -> None:
    records = [_record("2026-08-10T09:00:00+02:00", 3, 60.0)]

    payload = build_payload(records, today=date(2026, 8, 10))

    assert len(payload["menu"]) == 3
    assert payload["menu"][0].startswith("Ten tydzień: ")
    assert payload["menu"][1].startswith("Ten miesiąc: ")
    assert payload["menu"][2].startswith("Ten rok: ")


def test_build_payload_of_no_history_is_all_zero() -> None:
    payload = build_payload([], today=date(2026, 8, 10))

    assert payload["label"] == "0 min · 0 słów"
    assert payload["menu"][0] == "Ten tydzień: 0 min · 0 słów"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'voiceflow.tray'`

- [ ] **Step 3: Implement `build_payload`, `tray_script_path`, and `NullTray`**

```python
# src/voiceflow/tray.py
"""Daemon-side controller for the GNOME top-bar dictation-stats indicator.

The indicator itself is a separate process (scripts/voiceflow-tray.py)
because it needs PyGObject from the system Python, which this project's uv
virtualenv does not carry — same reason src/voiceflow/overlay.py exists as a
subprocess controller. Communication is one JSON object per line on the
child's stdin; closing stdin (stop()) ends the child.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
from collections.abc import Iterable
from datetime import date
from pathlib import Path

from voiceflow.config import TrayConfig
from voiceflow.history import Record
from voiceflow.statlib import (
    compact_number,
    format_duration,
    period_bounds,
    record_date,
    totals,
)

LOGGER = logging.getLogger(__name__)

#: PyGObject lives in the system interpreter, never in the project virtualenv.
SYSTEM_PYTHON = "/usr/bin/python3"

_PERIODS: tuple[tuple[str, str], ...] = (
    ("week", "Ten tydzień"),
    ("month", "Ten miesiąc"),
    ("year", "Ten rok"),
)


def tray_script_path() -> Path:
    """Return the bundled tray script shipped next to the package."""
    return Path(__file__).resolve().parent.parent.parent / "scripts" / "voiceflow-tray.py"


def build_payload(records: Iterable[Record], *, today: date | None = None) -> dict[str, object]:
    """Aggregate history into the tray label and dropdown menu text."""
    items = list(records)
    day = today or date.today()

    def summarize(period: str) -> str:
        start = period_bounds(period, today=day)
        subset = [record for record in items if record_date(record) >= start]
        stats = totals(subset)
        duration = format_duration(float(stats["audio_seconds"]))
        words = compact_number(int(stats["words"]))
        return f"{duration} · {words} słów"

    return {
        "label": summarize("day"),
        "menu": [f"{title}: {summarize(period)}" for period, title in _PERIODS],
    }


class NullTray:
    """No-op stand-in used on platforms without a GNOME top bar (Windows)."""

    def start(self) -> None:
        return

    def update(self, label: str, menu: list[str]) -> None:
        return

    def stop(self) -> None:
        return
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: the 3 `build_payload` tests PASS; `Tray`-based tests (added next)
do not exist yet in the file.

- [ ] **Step 5: Write failing tests for the `Tray` process controller**

```python
# append to tests/test_tray.py

STUB = """\
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as target:
    for line in sys.stdin:
        target.write(line)
        target.flush()
"""


class _LoggingTray(Tray):
    """Runs the stub script and tells it where to log the protocol it receives."""

    def __init__(self, config: TrayConfig, script: Path, log: Path) -> None:
        super().__init__(config, script)
        self.log = log

    def _build_command(self, python: str) -> list[str]:
        return [python, str(self.script), str(self.log)]


def _tray(tmp_path: Path, *, enabled: bool = True) -> _LoggingTray:
    script = tmp_path / "stub.py"
    script.write_text(STUB, encoding="utf-8")
    return _LoggingTray(TrayConfig(enabled=enabled), script, tmp_path / "sent.jsonl")


def _wait_for(log: Path, count: int, timeout: float = 5.0) -> list[dict]:
    deadline = time.monotonic() + timeout
    lines: list[str] = []
    while time.monotonic() < deadline:
        if log.exists():
            lines = [line for line in log.read_text(encoding="utf-8").splitlines() if line.strip()]
            if len(lines) >= count:
                return [json.loads(line) for line in lines]
        time.sleep(0.02)
    raise AssertionError(f"oczekiwano {count} linii, jest {len(lines)}: {lines!r}")


def test_start_leaves_the_process_running(tmp_path: Path) -> None:
    tray = _tray(tmp_path)

    tray.start()
    try:
        assert tray.is_running is True
    finally:
        tray.stop()


def test_update_sends_label_and_menu_preserving_polish_characters(tmp_path: Path) -> None:
    tray = _tray(tmp_path)
    tray.start()
    try:
        tray.update("12 min · 340 słów", ["Ten tydzień: 3 godz. 10 min · 1,2 k słów"])
        messages = _wait_for(tray.log, 1)
    finally:
        tray.stop()

    assert messages[0] == {
        "label": "12 min · 340 słów",
        "menu": ["Ten tydzień: 3 godz. 10 min · 1,2 k słów"],
    }


def test_stop_ends_the_process(tmp_path: Path) -> None:
    tray = _tray(tmp_path)
    tray.start()
    assert tray.is_running is True

    tray.stop()

    assert tray.is_running is False


def test_disabled_tray_never_spawns_a_process(tmp_path: Path) -> None:
    tray = _tray(tmp_path, enabled=False)

    tray.start()

    assert tray.is_running is False
    assert not tray.log.exists()


def test_missing_script_is_survivable(tmp_path: Path) -> None:
    tray = Tray(TrayConfig(), tmp_path / "nie-ma.py")

    tray.start()

    assert tray.is_running is False


def test_update_after_stop_does_not_raise(tmp_path: Path) -> None:
    """A dead indicator must never break the dictation flow."""
    tray = _tray(tmp_path)
    tray.start()
    tray.stop()

    tray.update("12 min · 340 słów", [])

    assert tray.is_running is False


def test_starting_twice_replaces_the_first_process(tmp_path: Path) -> None:
    tray = _tray(tmp_path)
    tray.start()
    first = tray._process  # noqa: SLF001

    tray.start()
    try:
        assert tray._process is not first  # noqa: SLF001
        assert first is not None and first.poll() is not None
    finally:
        tray.stop()


def test_null_tray_methods_are_all_no_ops() -> None:
    tray = NullTray()

    tray.start()
    tray.update("x", ["y"])
    tray.stop()
```

- [ ] **Step 6: Run tests to verify the new ones fail**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: FAIL — `ImportError: cannot import name 'Tray'`

- [ ] **Step 7: Implement the `Tray` class**

Append to `src/voiceflow/tray.py`:

```python
class Tray:
    """Start, feed, and stop the tray indicator process.

    Every method is best-effort: a missing or crashed indicator degrades the
    experience but must never interfere with recording or injection.
    """

    def __init__(self, config: TrayConfig, script: Path | None = None) -> None:
        self.config = config
        self.script = script or tray_script_path()
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()

    @property
    def is_running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def _build_command(self, python: str) -> list[str]:
        """Return the argv for the indicator process. Overridden in tests."""
        return [python, str(self.script)]

    def start(self) -> None:
        """Launch the indicator, replacing any process left over from before."""
        if not self.config.enabled:
            return
        if not self.script.is_file():
            LOGGER.warning("Brak skryptu wskaźnika statystyk %s; pomijam ikonę", self.script)
            return
        python = shutil.which(SYSTEM_PYTHON) or shutil.which("python3")
        if python is None:
            LOGGER.warning("Nie znaleziono systemowego Pythona; pomijam ikonę statystyk")
            return
        self.stop()
        try:
            process = subprocess.Popen(
                self._build_command(python),
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=os.environ.copy(),
                shell=False,
            )
        except OSError as exc:
            LOGGER.warning("Nie można uruchomić ikony statystyk: %s", exc)
            return
        with self._lock:
            self._process = process

    def update(self, label: str, menu: list[str]) -> None:
        """Send one label/menu update to the indicator."""
        payload = {"label": label, "menu": menu}
        self._write(json.dumps(payload, ensure_ascii=False) + "\n")

    def stop(self) -> None:
        """Close the indicator's stdin and make sure the process is gone."""
        with self._lock:
            process = self._process
            self._process = None
        if process is None:
            return
        self._close_stdin(process)
        if process.poll() is None:
            try:
                process.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                LOGGER.warning("Ikona statystyk nie zamknęła się; kończę ją")
                process.kill()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    LOGGER.warning("Nie można zakończyć procesu ikony statystyk")

    def _write(self, line: str) -> None:
        with self._lock:
            process = self._process
        if process is None or process.poll() is not None:
            return
        if process.stdin is None:
            return
        try:
            process.stdin.write(line.encode("utf-8"))
            process.stdin.flush()
        except (OSError, ValueError) as exc:
            # BrokenPipeError when the indicator died on its own; not worth raising.
            LOGGER.debug("Nie można pisać do ikony statystyk: %s", exc)

    @staticmethod
    def _close_stdin(process: subprocess.Popen[bytes]) -> None:
        if process.stdin is None:
            return
        try:
            process.stdin.close()
        except OSError as exc:
            LOGGER.debug("Nie można zamknąć stdin ikony statystyk: %s", exc)
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_tray.py -v`
Expected: PASS, all tests green.

- [ ] **Step 9: Commit**

```bash
git add src/voiceflow/tray.py tests/test_tray.py
git commit -m "Add Tray controller for the GNOME stats indicator"
```

---

### Task 4: `scripts/voiceflow-tray.py` — the system-Python indicator process

**Files:**
- Create: `scripts/voiceflow-tray.py`

**Interfaces:**
- Consumes: JSON lines on stdin, each `{"label": str, "menu": list[str]}`,
  written by `Tray.update()` (Task 3).
- Produces: nothing importable — this runs as a subprocess only. Not covered
  by pytest (needs PyGObject + a display, exactly like
  `scripts/voiceflow-overlay.py`); verified manually in Step 2 below.

This script is intentionally dumb: it does zero aggregation or formatting,
only renders whatever text it is handed.

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/python3
"""GNOME top-bar indicator for Voiceflow's dictation stats.

Reads one JSON object per stdin line — {"label": str, "menu": list[str]} —
and replaces the indicator's label and dropdown menu each time. Exits when
stdin closes (the daemon calls Tray.stop(), which closes its end of the
pipe). Runs on the system Python because PyGObject / AyatanaAppIndicator3
are not available in the project's uv virtualenv — see
src/voiceflow/tray.py's module docstring.
"""

from __future__ import annotations

import json
import sys
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3, GLib, Gtk  # noqa: E402

APP_ID = "io.github.avejapl.voiceflow-tray"


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

    def apply(self, payload: dict) -> None:
        label = str(payload.get("label", ""))
        items = [str(item) for item in payload.get("menu", [])]
        GLib.idle_add(self._apply_in_main_loop, label, items)

    def _apply_in_main_loop(self, label: str, items: list[str]) -> bool:
        self.indicator.set_label(label, "")
        menu = Gtk.Menu()
        for text in items:
            entry = Gtk.MenuItem(label=text)
            entry.set_sensitive(False)
            entry.show()
            menu.append(entry)
        menu.show_all()
        self.indicator.set_menu(menu)
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

- [ ] **Step 2: Manual smoke test (no pytest coverage for this file)**

Prerequisite: `gir1.2-ayatanaappindicator3-0.1` installed (Task 6 automates
this; for a manual check right now: `dpkg -s gir1.2-ayatanaappindicator3-0.1
|| sudo apt install gir1.2-ayatanaappindicator3-0.1`).

Run in a terminal on the actual GNOME session (not over SSH):

```bash
/usr/bin/python3 scripts/voiceflow-tray.py
```

Then, in the same terminal, type a line and press Enter:

```json
{"label": "12 min · 340 słów", "menu": ["Ten tydzień: 3 godz. 10 min · 1,2 k słów", "Ten miesiąc: 5 godz. · 3,4 k słów", "Ten rok: 12 godz. · 9,1 k słów"]}
```

Expected: a new icon appears in the top bar reading `12 min · 340 słów`;
clicking it opens a 3-line disabled-text dropdown with the week/month/year
figures. Press Ctrl+D (EOF) — the icon disappears and the process exits.

- [ ] **Step 3: Commit**

```bash
chmod +x scripts/voiceflow-tray.py
git add scripts/voiceflow-tray.py
git commit -m "Add the GNOME AppIndicator process for dictation stats"
```

---

### Task 5: Wire `Tray` into `VoiceflowDaemon`

**Files:**
- Modify: `src/voiceflow/daemon.py`
- Test: `tests/test_daemon.py`

**Interfaces:**
- Consumes: `Tray`, `NullTray`, `build_payload` (Task 3);
  `voiceflow.history.read_records` (existing function, currently only used
  by the CLI/settings app — signature `read_records(path: Path | None =
  None, *, limit: int | None = None) -> list[Record]`).
- Produces: `VoiceflowDaemon.__init__` gains a `tray: Tray | None = None`
  keyword parameter (same pattern as the existing `overlay`/`history`
  parameters) and a `self.tray` attribute.

- [ ] **Step 1: Write a failing test for the initial tray state on daemon startup**

Add a fake next to the existing `_Overlay` fake in `tests/test_daemon.py`
(place it right after the `_Overlay` class, around line 88):

```python
class _Tray:
    """Records tray calls instead of spawning a real indicator process."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str | None, list[str] | None]] = []

    def start(self) -> None:
        self.calls.append(("start", None, None))

    def update(self, label: str, menu: list[str]) -> None:
        self.calls.append(("update", label, list(menu)))

    def stop(self) -> None:
        self.calls.append(("stop", None, None))
```

Then add the test itself (near the end of the file, alongside the other
daemon-behavior tests):

```python
def test_daemon_starts_the_tray_and_shows_zero_stats(tmp_path: Path) -> None:
    tray = _Tray()
    VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    assert tray.calls[0] == ("start", None, None)
    assert tray.calls[1] == ("update", "0 min · 0 słów", ["Ten tydzień: 0 min · 0 słów", "Ten miesiąc: 0 min · 0 słów", "Ten rok: 0 min · 0 słów"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: FAIL — `TypeError: VoiceflowDaemon.__init__() got an unexpected
keyword argument 'tray'`

- [ ] **Step 3: Add the `tray` parameter and start-up wiring in `daemon.py`**

Add imports near the top of `src/voiceflow/daemon.py`, alongside the
existing `from voiceflow.history import History, Record` line:

```python
from voiceflow.history import History, Record, read_records
from voiceflow.tray import NullTray, Tray, build_payload
```

In `VoiceflowDaemon.__init__`, add the parameter to the signature (right
after `history: History | None = None,`):

```python
        history: History | None = None,
        tray: Tray | None = None,
```

Then, right after the existing `self.history = history or History(config.history)`
line (line 124), add:

```python
        if _WINDOWS and tray is None:
            self.tray = NullTray()
        else:
            self.tray = tray or Tray(config.tray)
        self.tray.start()
        self._refresh_tray()
        threading.Thread(
            target=self._tray_refresh_loop, name="voiceflow-tray-refresh", daemon=True
        ).start()
```

Add the two new methods anywhere among the other private helpers (a natural
spot is right after `_announce_update`, since both are startup background
threads):

```python
    def _refresh_tray(self) -> None:
        try:
            records = read_records(self.history.path)
            payload = build_payload(records)
        except Exception:
            LOGGER.exception("Nie można przeliczyć statystyk wskaźnika")
            return
        self.tray.update(str(payload["label"]), list(payload["menu"]))  # type: ignore[arg-type]

    def _tray_refresh_loop(self) -> None:
        # Recomputes on a timer (not only after a dictation) so the "today"
        # label actually rolls over to zero at local midnight even if
        # nothing gets dictated right around then.
        while not self._shutdown_requested.wait(300):
            self._refresh_tray()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: PASS.

- [ ] **Step 5: Write a failing test for the live update after a dictation**

```python
class _ThreeWordTranscriber:
    device = "cuda"
    compute_type = "float16"

    def transcribe(self, _audio_path: Path) -> TranscriptionResult:
        return TranscriptionResult("trzy słowa tutaj", "pl", 60.0, 0.1)

    def transcribe_preview(self, _audio: object) -> str | None:
        return None


def test_dictation_pushes_fresh_stats_to_the_tray(tmp_path: Path) -> None:
    tray = _Tray()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_ThreeWordTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    daemon.handle_command("start")
    daemon.handle_command("stop")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    assert tray.calls[-1] == (
        "update",
        "1 min · 3 słów",
        ["Ten tydzień: 1 min · 3 słów", "Ten miesiąc: 1 min · 3 słów", "Ten rok: 1 min · 3 słów"],
    )
```

- [ ] **Step 6: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: FAIL — the last recorded call is still the startup `"update"` with
`"0 min · 0 słów"` (no refresh happens after a dictation yet).

- [ ] **Step 7: Call `_refresh_tray()` after every completed dictation**

In `_transcribe_and_inject`, the history write happens in a `finally` block
around line 312-323:

```python
            finally:
                # Record even failed injections: the text is exactly what the
                # user needs to recover via `voiceflow last` or the app.
                self.history.append(
                    Record.now(
                        result.text,
                        audio_seconds=result.audio_seconds,
                        transcription_seconds=result.transcription_seconds,
                        injected=injected,
                        store_text=self.config.history.store_text,
                    )
                )
```

Add the refresh call immediately after that `finally` block closes (still
inside the outer `try`, before the `if injection.fallback_reason:` line):

```python
                self.history.append(
                    Record.now(
                        result.text,
                        audio_seconds=result.audio_seconds,
                        transcription_seconds=result.transcription_seconds,
                        injected=injected,
                        store_text=self.config.history.store_text,
                    )
                )
            self._refresh_tray()
            if injection.fallback_reason:
```

- [ ] **Step 8: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: PASS.

- [ ] **Step 9: Write a failing test for shutdown cleanup**

```python
def test_cleanup_stops_the_tray(tmp_path: Path) -> None:
    tray = _Tray()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    daemon._cleanup(None)  # noqa: SLF001

    assert tray.calls[-1] == ("stop", None, None)
```

- [ ] **Step 10: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_daemon.py -v -k tray`
Expected: FAIL — last call is still `"update"`, `_cleanup` never touches
`self.tray`.

- [ ] **Step 11: Stop the tray in `_cleanup`**

In `_cleanup` (around line 428-436), add a line next to the existing
`self.overlay.stop()`:

```python
        self._stop_preview()
        self.overlay.stop()
        self.tray.stop()
```

- [ ] **Step 12: Run the full daemon test file to verify everything passes**

Run: `.venv/bin/pytest tests/test_daemon.py -v`
Expected: PASS, all tests green (including every pre-existing test — the
`tray` parameter defaults to `None` so untouched tests keep constructing a
real `Tray`/`NullTray` that never spawns a process in the sandboxed test
environment, since `/usr/bin/python3` running the *real*
`scripts/voiceflow-tray.py` would need a display; verify no test hangs — if
any pre-existing test now blocks, it means a real `Tray` tried to spawn:
double-check every daemon construction in the untouched tests still goes
through fine because `Tray.start()` only fails soft when the display/GI
typelib is unavailable, never raises).

- [ ] **Step 13: Commit**

```bash
git add src/voiceflow/daemon.py tests/test_daemon.py
git commit -m "Wire the stats tray into the daemon lifecycle"
```

---

### Task 6: Install the system dependency

**Files:**
- Modify: `scripts/install-system-deps.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: nothing (shell only).
- Produces: nothing importable — `gir1.2-ayatanaappindicator3-0.1` present
  on the system after install/update.

- [ ] **Step 1: Add the package to `scripts/install-system-deps.sh`**

Current relevant lines:

```bash
#   ydotool      - key injection through /dev/uinput (the only path that works
#                  on GNOME Wayland, which implements no virtual-keyboard protocol)
#   wl-clipboard - wl-copy/wl-paste, used for pasting the transcribed text
#   python3-gi-cairo - Cairo context converter used by GTK application charts
```

```bash
apt-get install -y ydotool wl-clipboard python3-gi-cairo
```

Change to:

```bash
#   ydotool      - key injection through /dev/uinput (the only path that works
#                  on GNOME Wayland, which implements no virtual-keyboard protocol)
#   wl-clipboard - wl-copy/wl-paste, used for pasting the transcribed text
#   python3-gi-cairo - Cairo context converter used by GTK application charts
#   gir1.2-ayatanaappindicator3-0.1 - top-bar icon for the dictation-stats
#                  tray widget (scripts/voiceflow-tray.py)
```

```bash
apt-get install -y ydotool wl-clipboard python3-gi-cairo gir1.2-ayatanaappindicator3-0.1
```

- [ ] **Step 2: Trigger the sudo step in `install.sh` when the package is missing**

Current line 68:

```bash
if ! command -v ydotool >/dev/null || [ ! -e /dev/uinput ]; then
```

Change to:

```bash
if ! command -v ydotool >/dev/null || [ ! -e /dev/uinput ] || ! dpkg -s gir1.2-ayatanaappindicator3-0.1 >/dev/null 2>&1; then
```

- [ ] **Step 3: Verify the script is still syntactically valid**

Run: `bash -n install.sh && bash -n scripts/install-system-deps.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add install.sh scripts/install-system-deps.sh
git commit -m "Install gir1.2-ayatanaappindicator3-0.1 for the stats tray"
```

---

### Task 7: Update `CHANGELOG.md`

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Read the current top of the file to match its format**

Run: `head -20 CHANGELOG.md`

- [ ] **Step 2: Add an entry following the existing style/section for unreleased changes**

Add a bullet describing the feature in the same voice as neighboring entries,
e.g. "Dodano wskaźnik statystyk dyktowania w pasku GNOME (dziś w etykiecie,
tydzień/miesiąc/rok w menu)." — match whatever heading structure
(`## [Unreleased]` or similar) the file already uses; do not invent a new
format.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "Note the stats tray widget in the changelog"
```

---

## Manual End-to-End Verification (after all tasks)

Not automatable — run once, on the real machine, after Task 6:

1. `systemctl --user restart voiceflow.service`
2. Confirm a new icon appears in the top bar within a couple seconds, reading
   `0 min · 0 słów` (or today's real totals if you already dictated today).
3. Press `Super+G`, say a short sentence, press `Super+G` again.
4. Confirm the label updates within ~1 second of the text landing in focus.
5. Click the icon; confirm the dropdown shows three lines
   (Ten tydzień / Ten miesiąc / Ten rok) with plausible numbers.
6. `systemctl --user stop voiceflow.service`; confirm the icon disappears.
