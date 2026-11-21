"""Make the desktop app importable from the test suite.

The app deliberately lives outside the ``src/voiceflow`` package — it runs on
the system interpreter for PyGObject while the daemon runs in the project's
virtualenv — so it is not on the path by default. Only its GTK-free logic is
tested; anything importing Gtk stays out of the suite.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

APP_ROOT = Path(__file__).resolve().parent.parent / "app"
if str(APP_ROOT) not in sys.path:
    sys.path.insert(0, str(APP_ROOT))


@pytest.fixture(autouse=True)
def _no_real_tray_indicator(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep the real top-bar indicator out of the test suite.

    ``VoiceflowDaemon`` built from a plain ``Config()`` has ``tray.enabled``
    defaulting to True, and its constructor spawns the real
    ``scripts/voiceflow-tray.py`` subprocess — every such test run littered
    the GNOME top bar with duplicate microphone indicators until pytest
    exited. Tests that care about tray behaviour inject their own recording
    stub, so replacing the daemon's default is safe; ``test_tray.py`` still
    exercises the real ``Tray`` class directly (with a stub script).
    """
    from voiceflow.tray import NullTray

    monkeypatch.setattr("voiceflow.daemon.Tray", lambda *_args, **_kwargs: NullTray())
