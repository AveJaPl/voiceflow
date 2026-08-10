"""Make the desktop app importable from the test suite.

The app deliberately lives outside the ``src/voiceflow`` package — it runs on
the system interpreter for PyGObject while the daemon runs in the project's
virtualenv — so it is not on the path by default. Only its GTK-free logic is
tested; anything importing Gtk stays out of the suite.
"""

from __future__ import annotations

import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent.parent / "app"
if str(APP_ROOT) not in sys.path:
    sys.path.insert(0, str(APP_ROOT))
