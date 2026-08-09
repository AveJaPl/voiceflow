"""Daemon-side controller for the on-screen dictation indicator.

The indicator itself is a separate process (``scripts/voiceflow-overlay.py``)
because it needs PyGObject from the system Python, which this project's uv
virtualenv does not carry. Communication is one JSON object per line on its
stdin, so the overlay dies with the daemon and needs no cleanup protocol.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
from pathlib import Path

from voiceflow.config import OverlayConfig

LOGGER = logging.getLogger(__name__)

#: PyGObject lives in the system interpreter, never in the project virtualenv.
SYSTEM_PYTHON = "/usr/bin/python3"


def overlay_script_path() -> Path:
    """Return the bundled overlay script shipped next to the package."""
    return Path(__file__).resolve().parent.parent.parent / "scripts" / "voiceflow-overlay.py"


def _find_xwayland_auth_file() -> Path | None:
    """Locate Mutter's XWayland authority file for the current session.

    Newest first: after a relogin an older sibling may briefly survive, and only
    the freshest cookie matches the running X server.
    """
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    candidates = sorted(
        runtime.glob(".mutter-Xwaylandauth.*"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


class Overlay:
    """Start, feed, and stop the indicator process.

    Every method is best-effort: a missing or crashed indicator degrades the
    experience but must never interfere with recording or injection.
    """

    def __init__(self, config: OverlayConfig, script: Path | None = None) -> None:
        self.config = config
        self.script = script or overlay_script_path()
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()

    @property
    def is_running(self) -> bool:
        """Return whether an indicator process is currently alive."""
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def _environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        # Force the X11 backend: an override-redirect window is the only kind
        # GNOME will neither focus nor reposition, and it exists only on X11.
        environment["GDK_BACKEND"] = "x11"
        environment.setdefault("DISPLAY", ":0")
        # A daemon started at boot races the login and inherits no XAUTHORITY,
        # and without that cookie the X server refuses the connection outright
        # ("Authorization required"). Mutter names the file freshly on every
        # login, so a stored path would go stale — resolve it at spawn time.
        if "XAUTHORITY" not in environment:
            cookie = _find_xwayland_auth_file()
            if cookie is not None:
                environment["XAUTHORITY"] = str(cookie)
            else:
                LOGGER.warning(
                    "Brak XAUTHORITY i pliku .mutter-Xwaylandauth.*; okno podglądu może się nie pokazać"
                )
        return environment

    def _build_command(self, python: str) -> list[str]:
        """Return the argv for the indicator process. Overridden in tests."""
        return [python, str(self.script)]

    def start(self, state: str = "listening", text: str | None = None) -> None:
        """Launch the indicator, replacing any process left over from before."""
        if not self.config.enabled:
            return
        if not self.script.is_file():
            LOGGER.warning("Brak skryptu podglądu %s; pomijam okno", self.script)
            return
        python = shutil.which(SYSTEM_PYTHON) or shutil.which("python3")
        if python is None:
            LOGGER.warning("Nie znaleziono systemowego Pythona; pomijam okno podglądu")
            return
        self.stop()
        try:
            process = subprocess.Popen(
                self._build_command(python),
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=self._environment(),
                shell=False,
            )
        except OSError as exc:
            LOGGER.warning("Nie można uruchomić okna podglądu: %s", exc)
            return
        with self._lock:
            self._process = process
        self.update(state, text)

    def update(self, state: str, text: str | None = None) -> None:
        """Send one state update to the indicator."""
        payload: dict[str, object] = {"state": state}
        if text is not None:
            payload["text"] = text
        self._write(json.dumps(payload, ensure_ascii=False) + "\n")

    def stop(self) -> None:
        """Ask the indicator to close, then make sure it is gone."""
        with self._lock:
            process = self._process
            self._process = None
        if process is None:
            return
        if process.poll() is None:
            self._send_to(process, '{"state": "hide"}\n')
            try:
                process.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                LOGGER.warning("Okno podglądu nie zamknęło się; kończę je")
                process.kill()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    LOGGER.warning("Nie można zakończyć procesu okna podglądu")
        self._close_stdin(process)

    def _write(self, line: str) -> None:
        with self._lock:
            process = self._process
        if process is None or process.poll() is not None:
            return
        self._send_to(process, line)

    def _send_to(self, process: subprocess.Popen[bytes], line: str) -> None:
        if process.stdin is None:
            return
        try:
            process.stdin.write(line.encode("utf-8"))
            process.stdin.flush()
        except (OSError, ValueError) as exc:
            # BrokenPipeError when the overlay died on its own; not worth raising.
            LOGGER.debug("Nie można pisać do okna podglądu: %s", exc)

    @staticmethod
    def _close_stdin(process: subprocess.Popen[bytes]) -> None:
        if process.stdin is None:
            return
        try:
            process.stdin.close()
        except OSError as exc:
            LOGGER.debug("Nie można zamknąć stdin okna podglądu: %s", exc)
