"""Overview page with live daemon controls and local activity summary."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from datetime import datetime, timedelta
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango  # noqa: E402

from voiceflow_app import charts, statlib, style
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.services import HistoryRecord


def _relative_time(timestamp: str) -> str:
    moment = statlib.local_datetime(timestamp)
    now = datetime.now().astimezone()
    if moment.tzinfo is None:
        now = now.replace(tzinfo=None)
    seconds = max(0, int((now - moment).total_seconds()))
    if seconds < 60:
        return "przed chwilą"
    if seconds < 3600:
        return f"{seconds // 60} min temu"
    if seconds < 86400:
        return f"{seconds // 3600} godz. temu"
    if seconds < 172800:
        return "wczoraj"
    return moment.strftime("%d.%m.%Y")


class DashboardPage(Gtk.ScrolledWindow):
    """Live landing page for the most common voiceflow actions."""

    def __init__(
        self,
        on_toggle: Callable[[], None],
        on_service: Callable[[], None],
        on_copy: Callable[[str], None],
        *,
        cairo_available: bool,
    ) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_toggle = on_toggle
        self._on_service = on_service
        self._on_copy = on_copy
        self._daemon_online = False
        self._daemon_state = "OFFLINE"
        self._cairo_available = cairo_available
        self._week_series: list[tuple[object, int]] = []

        content = page_content(self)
        content.append(page_header("Przegląd", "Twoje lokalne centrum dyktowania."))
        content.append(self._build_hero())
        content.append(self._build_stat_cards())

        latest_group = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_16,
        )
        latest_group.append(label("OSTATNIE DYKTOWANIE", "section-label"))
        self.latest_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        latest_group.append(self.latest_holder)
        content.append(latest_group)
        self.update_history([])

    def _build_hero(self) -> Gtk.Widget:
        card = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_12,
        )
        card.add_css_class("card")
        card.add_css_class("hero-card")

        icon_shell = Gtk.Overlay()
        icon_shell.set_halign(Gtk.Align.CENTER)
        icon_shell.set_valign(Gtk.Align.CENTER)
        icon_shell.add_css_class("hero-icon-shell")
        icon = Gtk.Image.new_from_icon_name("audio-input-microphone-symbolic")
        icon.add_css_class("hero-icon")
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon_shell.set_child(icon)
        card.append(icon_shell)

        state_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        state_box.set_hexpand(True)
        state_box.set_valign(Gtk.Align.CENTER)
        title_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        self.recording_dot = label("●", "recording-dot")
        self.recording_dot.set_visible(False)
        self.state_label = label("Sprawdzanie…", "hero-state")
        title_row.append(self.recording_dot)
        title_row.append(self.state_label)
        state_box.append(title_row)
        self.meta_label = label("Łączenie z demonem voiceflow", "hero-meta")
        state_box.append(self.meta_label)
        card.append(state_box)

        actions = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        actions.set_valign(Gtk.Align.CENTER)
        self.toggle_button = Gtk.Button(label="Dyktuj")
        self.toggle_button.add_css_class("primary-button")
        self.toggle_button.connect("clicked", lambda _button: self._on_toggle())
        actions.append(self.toggle_button)
        self.service_button = Gtk.Button(label="Uruchom demona")
        self.service_button.add_css_class("secondary-button")
        self.service_button.connect("clicked", lambda _button: self._on_service())
        actions.append(self.service_button)
        card.append(actions)
        return card

    def _build_stat_cards(self) -> Gtk.Widget:
        row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_16,
            homogeneous=True,
        )
        self.today_value, self.today_trend = self._stat_card(row, "Dzisiaj", "słów")
        self.total_value, self.total_trend = self._stat_card(row, "Łącznie", "słów")
        self.streak_value, self.streak_trend = self._stat_card(row, "Seria", "dni")
        self._build_week_card(row)
        return row

    @staticmethod
    def _stat_card(
        parent: Gtk.Box,
        title: str,
        suffix: str,
    ) -> tuple[Gtk.Label, Gtk.Label]:
        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        card.add_css_class("card")
        card.add_css_class("stat-card")

        card.append(label(title.upper(), "stat-label"))

        value_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        value_label = label("0", "stat-value")
        value_row.append(value_label)
        suffix_label = label(suffix, "stat-suffix")
        suffix_label.set_valign(Gtk.Align.END)
        value_row.append(suffix_label)
        card.append(value_row)

        trend_label = label("", "stat-trend")
        card.append(trend_label)
        parent.append(card)
        return value_label, trend_label

    def _build_week_card(self, parent: Gtk.Box) -> None:
        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        card.add_css_class("card")
        card.add_css_class("stat-card")
        card.add_css_class("week-card")
        card.append(label("TEN TYDZIEŃ", "stat-label"))
        if self._cairo_available:
            self.week_chart = Gtk.DrawingArea(content_height=48)
            self.week_chart.set_hexpand(True)
            self.week_chart.set_draw_func(self._draw_week)
            card.append(self.week_chart)
        else:
            self.week_chart = None
            warning = charts.unavailable_label()
            warning.add_css_class("compact")
            card.append(warning)
        parent.append(card)

    def _draw_week(
        self,
        _area: Gtk.DrawingArea,
        context: Any,
        width: int,
        height: int,
    ) -> None:
        if not self._week_series:
            return
        maximum = max((value for _day, value in self._week_series), default=0)
        slot = width / 7
        bar_width = max(4.0, min(18.0, slot * 0.48))
        baseline = height - 2.0
        for index, (_day, value) in enumerate(self._week_series):
            bar_height = (
                max(3.0, (value / maximum) * (height - 4.0))
                if value > 0 and maximum > 0
                else 3.0
            )
            x = index * slot + (slot - bar_width) / 2
            context.set_source_rgba(1, 1, 1, 0.55 if value else 0.07)
            context.rectangle(x, baseline - bar_height, bar_width, bar_height)
            context.fill()

    def set_status(self, response: Mapping[str, Any] | None) -> None:
        """Render a daemon status response or a clean offline state."""
        self.toggle_button.remove_css_class("recording-action")
        self.toggle_button.add_css_class("primary-button")
        if response is None:
            self._daemon_online = False
            self._daemon_state = "OFFLINE"
            self.state_label.set_label("Demon nie działa")
            self.meta_label.set_label("Usługa jest zatrzymana lub nie odpowiada")
            self.recording_dot.set_visible(False)
            self.toggle_button.set_sensitive(False)
            self.toggle_button.set_label("Dyktuj")
            self.service_button.set_label("Uruchom demona")
            return

        self._daemon_online = True
        state = str(response.get("state", ""))
        self._daemon_state = state
        titles = {
            "IDLE": "Gotowy",
            "RECORDING": "Nagrywanie",
            "TRANSCRIBING": "Przetwarzanie",
        }
        self.state_label.set_label(titles.get(state, f"Nieznany stan: {state or '?'}"))
        model = str(response.get("model", "?"))
        device = str(response.get("device", "?"))
        device_name = {"cuda": "GPU", "cpu": "CPU", "auto": "Automatycznie"}.get(
            device, device
        )
        self.meta_label.set_label(f"{model} · {device_name}")
        recording = state == "RECORDING"
        self.recording_dot.set_visible(recording)
        self.toggle_button.set_sensitive(state != "TRANSCRIBING")
        self.toggle_button.set_label("Zatrzymaj" if recording else "Dyktuj")
        if recording:
            self.toggle_button.remove_css_class("primary-button")
            self.toggle_button.add_css_class("recording-action")
        self.service_button.set_label("Zatrzymaj demona")

    def set_service_busy(self, busy: bool) -> None:
        """Prevent duplicate service actions while a worker is active."""
        self.service_button.set_sensitive(not busy)

    @property
    def daemon_online(self) -> bool:
        """Whether the most recent status request reached the daemon."""
        return self._daemon_online

    def update_history(self, records: list[HistoryRecord]) -> None:
        """Refresh activity counts, trends, and the latest dictation card."""
        totals = statlib.daily_word_totals(records)
        today = datetime.now().astimezone().date()
        yesterday = today - timedelta(days=1)
        summary = statlib.totals(records)
        today_words = totals.get(today, 0)
        yesterday_words = totals.get(yesterday, 0)
        streak = statlib.current_streak(records, today=today)

        self.today_value.set_label(statlib.compact_number(today_words))
        self.total_value.set_label(statlib.compact_number(int(summary["words"])))
        self.streak_value.set_label(str(streak))
        self._week_series = statlib.daily_series(records, 7, today=today)
        if self.week_chart is not None:
            self.week_chart.queue_draw()
        difference = today_words - yesterday_words
        if difference > 0:
            self.today_trend.set_label(f"+{difference} vs wczoraj")
        elif difference < 0:
            self.today_trend.set_label(f"−{abs(difference)} vs wczoraj")
        else:
            self.today_trend.set_label("Tyle samo co wczoraj")
        self.total_trend.set_label(f"{int(summary['dictations'])} dyktowań")
        active_days = sum(1 for words in totals.values() if words > 0)
        self.streak_trend.set_label(f"{active_days} aktywnych dni")

        while child := self.latest_holder.get_first_child():
            self.latest_holder.remove(child)
        if not records:
            self.latest_holder.append(
                empty_state(
                    "audio-input-microphone-symbolic",
                    "Pierwsze zakończone dyktowanie pojawi się tutaj.",
                )
            )
            return

        record = records[-1]
        card = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_16,
        )
        card.add_css_class("card")
        card.add_css_class("latest-card")
        text_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        text_box.set_hexpand(True)
        meta = f"{_relative_time(str(record['timestamp']))} · {record.get('words', 0)} słów"
        text_box.append(label(meta, "latest-meta"))
        text = record.get("text")
        value = text if isinstance(text, str) and text else "(treść nie była zapisywana)"
        text_label = label(value, "history-preview")
        text_label.set_wrap(True)
        text_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        text_label.set_lines(3)
        text_label.set_ellipsize(Pango.EllipsizeMode.END)
        text_box.append(text_label)
        card.append(text_box)
        if isinstance(text, str) and text:
            copy_button = Gtk.Button(icon_name="edit-copy-symbolic")
            copy_button.add_css_class("icon-button")
            copy_button.set_tooltip_text("Kopiuj tekst")
            copy_button.set_valign(Gtk.Align.CENTER)
            copy_button.connect("clicked", lambda _button, text=text: self._on_copy(text))
            card.append(copy_button)
        self.latest_holder.append(card)
