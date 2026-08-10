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
