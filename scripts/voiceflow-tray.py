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
