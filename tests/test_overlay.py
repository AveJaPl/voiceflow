"""Tests for the overlay controller, using a stub script instead of a real window."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from voiceflow.config import OverlayConfig
from voiceflow.overlay import Overlay

#: This is the GTK/XWayland controller, which spawns the system python. Windows
#: uses voiceflow.winplat.overlay instead — see tests/test_winplat.py.
pytestmark = pytest.mark.skipif(
    os.name == "nt", reason="overlay przez podproces jest backendem linuksowym"
)

#: Stands in for the GTK indicator: logs the protocol and, like the real one,
#: exits on "hide" as well as on end of stdin.
STUB = """\
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as target:
    for line in sys.stdin:
        target.write(line)
        target.flush()
        try:
            if json.loads(line).get("state") == "hide":
                break
        except (ValueError, AttributeError):
            pass
"""


class _LoggingOverlay(Overlay):
    """Runs the stub script and tells it where to log the protocol it receives."""

    def __init__(self, config: OverlayConfig, script: Path, log: Path) -> None:
        super().__init__(config, script)
        self.log = log

    def _build_command(self, python: str) -> list[str]:
        return [python, str(self.script), str(self.log)]


def _overlay(tmp_path: Path, *, enabled: bool = True) -> _LoggingOverlay:
    script = tmp_path / "stub.py"
    script.write_text(STUB, encoding="utf-8")
    return _LoggingOverlay(OverlayConfig(enabled=enabled), script, tmp_path / "sent.jsonl")


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


def test_start_announces_the_listening_state(tmp_path: Path) -> None:
    overlay = _overlay(tmp_path)

    overlay.start()
    try:
        assert _wait_for(overlay.log, 1)[0] == {"state": "listening"}
    finally:
        overlay.stop()


def test_update_preserves_polish_characters(tmp_path: Path) -> None:
    """ensure_ascii=False matters: escaped codepoints would render as garbage."""
    overlay = _overlay(tmp_path)
    overlay.start()
    try:
        overlay.update("listening", "zażółć gęślą jaźń")
        messages = _wait_for(overlay.log, 2)
    finally:
        overlay.stop()

    assert messages[1] == {"state": "listening", "text": "zażółć gęślą jaźń"}


def test_stop_sends_hide_and_ends_the_process(tmp_path: Path) -> None:
    overlay = _overlay(tmp_path)
    overlay.start()
    _wait_for(overlay.log, 1)
    assert overlay.is_running is True

    overlay.stop()

    assert overlay.is_running is False
    assert {"state": "hide"} in _wait_for(overlay.log, 2)


def test_disabled_overlay_never_spawns_a_process(tmp_path: Path) -> None:
    overlay = _overlay(tmp_path, enabled=False)

    overlay.start()

    assert overlay.is_running is False
    assert not overlay.log.exists()


def test_missing_script_is_survivable(tmp_path: Path) -> None:
    overlay = Overlay(OverlayConfig(), tmp_path / "nie-ma.py")

    overlay.start()

    assert overlay.is_running is False


def test_update_after_stop_does_not_raise(tmp_path: Path) -> None:
    """A dead indicator must never break the dictation flow."""
    overlay = _overlay(tmp_path)
    overlay.start()
    _wait_for(overlay.log, 1)
    overlay.stop()

    overlay.update("listening", "po zamknięciu")

    assert overlay.is_running is False


def test_starting_twice_replaces_the_first_process(tmp_path: Path) -> None:
    overlay = _overlay(tmp_path)
    overlay.start()
    _wait_for(overlay.log, 1)
    first = overlay._process  # noqa: SLF001

    overlay.start()
    try:
        assert overlay._process is not first  # noqa: SLF001
        assert first is not None and first.poll() is not None
    finally:
        overlay.stop()
