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
