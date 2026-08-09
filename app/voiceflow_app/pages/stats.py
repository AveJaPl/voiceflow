"""Statistics page with compact local-history visualizations."""

from __future__ import annotations

from datetime import date, timedelta

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402

from voiceflow_app import charts, statlib, style
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.services import HistoryRecord


DAY_NAMES = ("pn", "wt", "śr", "cz", "pt", "sob", "nd")
MONTH_NAMES = (
    "",
    "sty",
    "lut",
    "mar",
    "kwi",
    "maj",
    "cze",
    "lip",
    "sie",
    "wrz",
    "paź",
    "lis",
    "gru",
)
cairo = charts.context_type()


def _rounded_top_bar(
    context: cairo.Context,
    x: float,
    y: float,
    width: float,
    height: float,
    radius: float,
) -> None:
    """Build a bar path with square lower and rounded upper corners."""
    radius = min(radius, width / 2, height)
    context.new_sub_path()
    context.move_to(x, y + height)
    context.line_to(x, y + radius)
    context.arc(x + radius, y + radius, radius, 3.14159, 4.71239)
    context.line_to(x + width - radius, y)
    context.arc(x + width - radius, y + radius, radius, 4.71239, 6.28318)
    context.line_to(x + width, y + height)
    context.close_path()


def _rounded_square(
    context: cairo.Context,
    x: float,
    y: float,
    size: float,
    radius: float,
) -> None:
    """Build a compact rounded square path."""
    context.new_sub_path()
    context.arc(x + size - radius, y + radius, radius, -1.5708, 0)
    context.arc(x + size - radius, y + size - radius, radius, 0, 1.5708)
    context.arc(x + radius, y + size - radius, radius, 1.5708, 3.14159)
    context.arc(x + radius, y + radius, radius, 3.14159, 4.71239)
    context.close_path()


def _snap(value: float, scale: int) -> float:
    """Align a logical coordinate to a physical device pixel."""
    return round(value * scale) / scale


class StatsPage(Gtk.ScrolledWindow):
    """Aggregate and visualize the local JSONL history."""

    def __init__(self, *, cairo_available: bool) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._records: list[HistoryRecord] = []
        self._bar_series: list[tuple[date, int]] = []
        self._activity_series: list[tuple[date, int]] = []
        self._activity_levels: dict[date, int] = {}
        self._activity_cells: list[tuple[float, float, float, date, int]] = []
        self._cairo_available = cairo_available

        content = page_content(self)
        content.append(
            page_header(
                "Statystyki",
                "Twój rytm dyktowania, liczony wyłącznie z lokalnej historii.",
            )
        )
        self.data_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(self.data_holder)

        self.data_content = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_32,
        )
        self.data_content.append(self._build_summary())
        self.data_content.append(self._build_bar_chart())
        self.data_content.append(self._build_activity_chart())
        self.update_history([])

    def _build_summary(self) -> Gtk.Widget:
        row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_16,
            homogeneous=True,
        )
        self.words_value = self._summary_card(row, "Łącznie słów")
        self.dictations_value = self._summary_card(row, "Dyktowań")
        self.duration_value = self._summary_card(row, "Czas mówienia")
        self.average_value = self._summary_card(row, "Średnio słów")
        return row

    @staticmethod
    def _summary_card(parent: Gtk.Box, title: str) -> Gtk.Label:
        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        card.add_css_class("card")
        card.add_css_class("stat-card")
        card.append(label(title.upper(), "stat-label"))
        value = label("0", "stat-value")
        card.append(value)
        parent.append(card)
        return value

    def _build_bar_chart(self) -> Gtk.Widget:
        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_16,
        )
        card.add_css_class("card")
        card.add_css_class("chart-card")
        card.append(label("Słowa dziennie", "card-title"))
        if self._cairo_available:
            self.bar_chart = Gtk.DrawingArea(content_height=200)
            self.bar_chart.set_hexpand(True)
            self.bar_chart.set_draw_func(self._draw_bars)
            card.append(self.bar_chart)
        else:
            self.bar_chart = None
            card.append(charts.unavailable_label())
        return card

    def _build_activity_chart(self) -> Gtk.Widget:
        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_16,
        )
        card.add_css_class("card")
        card.add_css_class("chart-card")
        card.append(label("Aktywność · 26 tygodni", "card-title"))
        if self._cairo_available:
            self.activity_chart = Gtk.DrawingArea(content_height=160)
            self.activity_chart.set_hexpand(True)
            self.activity_chart.set_has_tooltip(True)
            self.activity_chart.set_draw_func(self._draw_activity)
            self.activity_chart.connect("query-tooltip", self._query_activity_tooltip)
            card.append(self.activity_chart)
        else:
            self.activity_chart = None
            card.append(charts.unavailable_label())
        return card

    def update_history(self, records: list[HistoryRecord]) -> None:
        """Recalculate statistics, update the empty state, and redraw charts."""
        self._records = list(records)
        summary = statlib.totals(records)
        self.words_value.set_label(statlib.compact_number(int(summary["words"])))
        self.dictations_value.set_label(
            statlib.compact_number(int(summary["dictations"]))
        )
        self.duration_value.set_label(statlib.format_duration(float(summary["audio_seconds"])))
        self.average_value.set_label(f"{float(summary['average_words']):.0f}")

        today = date.today()
        self._bar_series = statlib.daily_series(records, 14, today=today)
        week_start = today - timedelta(days=today.weekday())
        activity_start = week_start - timedelta(weeks=25)
        totals = statlib.daily_word_totals(records)
        self._activity_series = [
            (
                activity_start + timedelta(days=index),
                totals.get(activity_start + timedelta(days=index), 0),
            )
            for index in range(26 * 7)
        ]
        self._activity_levels = statlib.activity_levels(self._activity_series)
        if self.bar_chart is not None:
            self.bar_chart.queue_draw()
        if self.activity_chart is not None:
            self.activity_chart.queue_draw()

        while child := self.data_holder.get_first_child():
            self.data_holder.remove(child)
        if records:
            self.data_holder.append(self.data_content)
        else:
            self.data_holder.append(
                empty_state(
                    "view-grid-symbolic",
                    "Brak statystyk. Pierwsze dyktowanie uruchomi podsumowania i wykresy.",
                )
            )

    def _draw_bars(
        self,
        area: Gtk.DrawingArea,
        context: cairo.Context,
        width: int,
        height: int,
    ) -> None:
        scale = max(1, area.get_scale_factor())
        left, right, top, bottom = 8.0, 8.0, 24.0, 32.0
        usable_width = max(1.0, width - left - right)
        baseline = _snap(height - bottom, scale)
        chart_height = max(1.0, baseline - top)
        slot = usable_width / 14
        bar_width = max(8.0, min(24.0, slot * 0.48))
        maximum = max((value for _day, value in self._bar_series), default=0)
        peak_index = max(
            range(len(self._bar_series)),
            key=lambda index: self._bar_series[index][1],
            default=0,
        )

        context.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        for index, (day, value) in enumerate(self._bar_series):
            x = _snap(left + index * slot + (slot - bar_width) / 2, scale)
            if value > 0 and maximum > 0:
                bar_height = max(4.0, (value / maximum) * (chart_height - 16.0))
                alpha = 0.55
            else:
                bar_height = _snap(4.0, scale)
                alpha = 0.07
            y = _snap(baseline - bar_height, scale)
            context.set_source_rgba(1, 1, 1, alpha)
            _rounded_top_bar(context, x, y, bar_width, bar_height, 3.0)
            context.fill()

            context.set_font_size(11)
            context.set_source_rgba(1, 1, 1, 1.0 if day == date.today() else 0.35)
            day_label = DAY_NAMES[day.weekday()]
            extents = context.text_extents(day_label)
            context.move_to(
                x + (bar_width - extents.width) / 2 - extents.x_bearing,
                height - 8,
            )
            context.show_text(day_label)

            if index == peak_index and value > 0:
                peak_label = f"{value:,}".replace(",", " ")
                context.set_font_size(11)
                context.set_source_rgba(1, 1, 1, 0.55)
                peak_extents = context.text_extents(peak_label)
                context.move_to(
                    x + (bar_width - peak_extents.width) / 2 - peak_extents.x_bearing,
                    max(12, y - 8),
                )
                context.show_text(peak_label)

    def _draw_activity(
        self,
        area: Gtk.DrawingArea,
        context: cairo.Context,
        width: int,
        _height: int,
    ) -> None:
        scale = max(1, area.get_scale_factor())
        size, gap = 12.0, 4.0
        step = size + gap
        grid_width = 26 * size + 25 * gap
        left = max(48.0, (width - grid_width) / 2)
        top = 32.0
        alphas = (0.07, 0.35, 0.55, 0.55, 1.0)
        self._activity_cells = []

        context.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        context.set_font_size(11)
        context.set_source_rgba(1, 1, 1, 0.35)
        for row, day_label in ((0, "pn"), (2, "śr"), (4, "pt")):
            context.move_to(left - 24, top + row * step + 12)
            context.show_text(day_label)

        previous_month = 0
        for week in range(26):
            week_day = self._activity_series[week * 7][0]
            if week_day.month != previous_month:
                context.set_font_size(11)
                context.set_source_rgba(1, 1, 1, 0.35)
                context.move_to(left + week * step, 12)
                context.show_text(MONTH_NAMES[week_day.month])
                previous_month = week_day.month

        for index, (day, value) in enumerate(self._activity_series):
            week, weekday = divmod(index, 7)
            x = _snap(left + week * step, scale)
            y = _snap(top + weekday * step, scale)
            level = self._activity_levels.get(day, 0)
            alpha = alphas[level]
            if day > date.today():
                alpha = 0.07
            context.set_source_rgba(1, 1, 1, alpha)
            _rounded_square(context, x, y, size, 3.0)
            context.fill()
            self._activity_cells.append((x, y, size, day, value))

    def _query_activity_tooltip(
        self,
        _area: Gtk.DrawingArea,
        x: int,
        y: int,
        _keyboard_mode: bool,
        tooltip: Gtk.Tooltip,
    ) -> bool:
        for cell_x, cell_y, size, day, value in self._activity_cells:
            if cell_x <= x <= cell_x + size and cell_y <= y <= cell_y + size:
                if day > date.today():
                    return False
                tooltip.set_text(f"{day.strftime('%d.%m.%Y')} · {value} słów")
                return True
        return False
