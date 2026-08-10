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
    daily_series,
    format_duration,
    hourly_word_totals,
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


class NullTray:
    """No-op stand-in used on platforms without a GNOME top bar (Windows)."""

    def start(self) -> None:
        return

    def update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None:
        return

    def stop(self) -> None:
        return


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

    def update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]]) -> None:
        """Send one label/summary/chart update to the indicator."""
        payload = {
            "label": label,
            "summary": summary,
            "hourly": hourly,
            "daily": [{"date": day.isoformat(), "words": words} for day, words in daily],
        }
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
