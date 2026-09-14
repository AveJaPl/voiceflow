"""Overview page with live daemon controls and local activity summary."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from datetime import datetime, timedelta
from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QPushButton, QVBoxLayout, QWidget

from voiceflow import statlib
from voiceflow.gui import theme
from voiceflow.gui.widgets import (
    Card,
    ClampedLabel,
    RecordingDot,
    Sparkline,
    StatCard,
    clear_layout,
    empty_state,
    hbox,
    icon_label,
    label,
    page_body,
    page_header,
    page_scroll,
    plain,
    section_label,
    vbox,
)

_STATE_TITLES = {
    "IDLE": "Gotowy",
    "RECORDING": "Nagrywanie",
    "TRANSCRIBING": "Przetwarzanie",
}
_DEVICE_NAMES = {"cuda": "GPU", "cpu": "CPU", "auto": "Automatycznie"}


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


class DashboardPage(QWidget):
    """Live landing page for the most common voiceflow actions."""

    def __init__(
        self,
        on_toggle: Callable[[], None],
        on_service: Callable[[], None],
        on_copy: Callable[[str], None],
    ) -> None:
        super().__init__()
        self._on_toggle = on_toggle
        self._on_service = on_service
        self._on_copy = on_copy
        self._daemon_online = False
        self._daemon_state = "OFFLINE"

        clamp, layout = page_body()
        layout.addWidget(page_header("Przegląd", "Twoje lokalne centrum dyktowania."))
        layout.addWidget(self._build_hero())
        layout.addWidget(self._build_stat_cards())

        latest_group = plain(vbox(theme.SPACE_16))
        latest_group.layout().addWidget(section_label("Ostatnie dyktowanie"))
        self.latest_holder = vbox(0)
        latest_group.layout().addLayout(self.latest_holder)
        layout.addWidget(latest_group)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))
        self.update_history([])

    # -- construction --------------------------------------------------------

    def _build_hero(self) -> QWidget:
        card = Card(horizontal=True, spacing=theme.SPACE_12)
        card.setMinimumHeight(128)

        shell = QWidget()
        shell.setObjectName("hero-icon-shell")
        shell.setFixedSize(48, 48)
        shell_layout = hbox(0)
        shell_layout.addWidget(
            icon_label("audio-input-microphone-symbolic", 24), 0, Qt.AlignmentFlag.AlignCenter
        )
        shell.setLayout(shell_layout)
        card.body.addWidget(shell, 0, Qt.AlignmentFlag.AlignVCenter)

        state_box = plain(vbox(theme.SPACE_8))
        title_row = plain(hbox(theme.SPACE_8))
        self.recording_dot = RecordingDot()
        self.recording_dot.setVisible(False)
        self.state_label = label("Sprawdzanie…", "hero-state")
        title_row.layout().addWidget(self.recording_dot)
        title_row.layout().addWidget(self.state_label)
        title_row.layout().addStretch(1)
        state_box.layout().addWidget(title_row)
        self.meta_label = label("Łączenie z demonem voiceflow", "hero-meta")
        state_box.layout().addWidget(self.meta_label)
        # Windows registers the shortcut inside the daemon, so it can be refused
        # by another application. Saying which, here, is the only place the user
        # would ever find out.
        self.hotkey_label = label("", "hero-meta", wrap=True)
        self.hotkey_label.setVisible(False)
        state_box.layout().addWidget(self.hotkey_label)
        card.body.addWidget(state_box, 1)

        actions = plain(hbox(theme.SPACE_8))
        self.toggle_button = QPushButton("Dyktuj")
        self.toggle_button.setObjectName("primary-button")
        self.toggle_button.clicked.connect(lambda: self._on_toggle())
        actions.layout().addWidget(self.toggle_button)
        self.service_button = QPushButton("Uruchom demona")
        self.service_button.setObjectName("secondary-button")
        self.service_button.clicked.connect(lambda: self._on_service())
        actions.layout().addWidget(self.service_button)
        card.body.addWidget(actions, 0, Qt.AlignmentFlag.AlignVCenter)
        return card

    def _build_stat_cards(self) -> QWidget:
        holder = plain(hbox(theme.SPACE_16))
        self.today_card = StatCard("Dzisiaj", "słów")
        self.total_card = StatCard("Łącznie", "słów")
        self.streak_card = StatCard("Seria", "dni")
        for card in (self.today_card, self.total_card, self.streak_card):
            holder.layout().addWidget(card, 1)

        week = Card(padding=theme.SPACE_16, spacing=theme.SPACE_8)
        week.setMinimumHeight(88)
        week.body.setContentsMargins(theme.SPACE_20, theme.SPACE_16, theme.SPACE_20, theme.SPACE_16)
        week.body.addWidget(label("TEN TYDZIEŃ", "stat-label"))
        self.week_chart = Sparkline()
        week.body.addWidget(self.week_chart)
        holder.layout().addWidget(week, 1)
        return holder

    # -- status --------------------------------------------------------------

    def set_status(self, response: Mapping[str, Any] | None, *, starting: bool = False) -> None:
        """Render a daemon status response or a clean offline state.

        ``starting`` is its own state rather than a flavour of offline, because
        a daemon takes half a minute to load its model and answers nothing in
        the meantime. Reporting that as "not running" invited the one thing that
        must not happen — a second launch, and a second copy of the model.
        """
        self.toggle_button.setObjectName("primary-button")
        if response is None:
            self._daemon_online = False
            self._daemon_state = "OFFLINE"
            self.state_label.setText("Demon się uruchamia" if starting else "Demon nie działa")
            self.meta_label.setText(
                "Wczytuję model — to trwa kilkadziesiąt sekund"
                if starting
                else "Usługa jest zatrzymana lub nie odpowiada"
            )
            self.hotkey_label.setVisible(False)
            self.recording_dot.setVisible(False)
            self.toggle_button.setEnabled(False)
            self.toggle_button.setText("Dyktuj")
            self.service_button.setText("Uruchamianie…" if starting else "Uruchom demona")
            self.service_button.setEnabled(not starting)
            self._repolish()
            return
        self.service_button.setEnabled(True)

        self._daemon_online = True
        state = str(response.get("state", ""))
        self._daemon_state = state
        self.state_label.setText(_STATE_TITLES.get(state, f"Nieznany stan: {state or '?'}"))
        model = str(response.get("model", "?"))
        device = str(response.get("device", "?"))
        self.meta_label.setText(f"{model} · {_DEVICE_NAMES.get(device, device)}")
        self._apply_hotkey(response)

        recording = state == "RECORDING"
        self.recording_dot.setVisible(recording)
        self.toggle_button.setEnabled(state != "TRANSCRIBING")
        self.toggle_button.setText("Zatrzymaj" if recording else "Dyktuj")
        if recording:
            self.toggle_button.setObjectName("recording-action")
        self.service_button.setText("Zatrzymaj demona")
        self._repolish()

    def _apply_hotkey(self, status: Mapping[str, Any]) -> None:
        """Say whether the shortcut works, not merely what it is set to.

        ``hotkey_active`` is absent on older daemons and during the moment
        before registration settles; there the configured name is all we can
        honestly show.
        """
        hotkey = status.get("hotkey")
        if not hotkey:
            self.hotkey_label.setVisible(False)
            return
        self.hotkey_label.setVisible(True)
        if status.get("hotkey_active") is False:
            reason = status.get("hotkey_error") or "zajmuje go inna aplikacja"
            self.hotkey_label.setText(f"Skrót {hotkey} NIE działa — {reason}")
            self.hotkey_label.setStyleSheet(f"color: {theme.RECORDING}; background: transparent;")
            return
        self.hotkey_label.setText(f"Skrót: {hotkey} — wciśnij, mów, wciśnij ponownie")
        self.hotkey_label.setStyleSheet("")

    def _repolish(self) -> None:
        from voiceflow.gui.widgets import repolish

        repolish(self.toggle_button)

    def set_service_busy(self, busy: bool) -> None:
        """Prevent duplicate service actions while a worker is active."""
        self.service_button.setEnabled(not busy)

    @property
    def daemon_online(self) -> bool:
        """Whether the most recent status request reached the daemon."""
        return self._daemon_online

    # -- history -------------------------------------------------------------

    def update_history(self, records: list[dict[str, Any]]) -> None:
        """Refresh activity counts, trends, and the latest dictation card."""
        totals = statlib.daily_word_totals(records)
        today = datetime.now().astimezone().date()
        yesterday = today - timedelta(days=1)
        summary = statlib.totals(records)
        today_words = totals.get(today, 0)
        yesterday_words = totals.get(yesterday, 0)
        streak = statlib.current_streak(records, today=today)

        self.today_card.set_value(statlib.compact_number(today_words))
        self.total_card.set_value(statlib.compact_number(int(summary["words"])))
        self.streak_card.set_value(str(streak))
        self.week_chart.set_series(statlib.daily_series(records, 7, today=today))

        difference = today_words - yesterday_words
        if difference > 0:
            self.today_card.set_trend(f"+{difference} vs wczoraj")
        elif difference < 0:
            self.today_card.set_trend(f"−{abs(difference)} vs wczoraj")
        else:
            self.today_card.set_trend("Tyle samo co wczoraj")
        self.total_card.set_trend(f"{int(summary['dictations'])} dyktowań")
        active_days = sum(1 for words in totals.values() if words > 0)
        self.streak_card.set_trend(f"{active_days} aktywnych dni")

        clear_layout(self.latest_holder)
        if not records:
            self.latest_holder.addWidget(
                empty_state(
                    "audio-input-microphone-symbolic",
                    "Pierwsze zakończone dyktowanie pojawi się tutaj.",
                )
            )
            return
        self.latest_holder.addWidget(self._latest_card(records[-1]))

    def _latest_card(self, record: Mapping[str, Any]) -> QWidget:
        card = Card(horizontal=True, spacing=theme.SPACE_16)
        text_box = plain(vbox(theme.SPACE_8))
        meta = (
            f"{_relative_time(str(record['timestamp']))} · {record.get('words', 0)} słów"
        )
        text_box.layout().addWidget(label(meta, "latest-meta"))
        text = record.get("text")
        value = text if isinstance(text, str) and text else "(treść nie była zapisywana)"
        text_box.layout().addWidget(ClampedLabel(value, "history-preview", lines=3))
        card.body.addWidget(text_box, 1)

        if isinstance(text, str) and text:
            from voiceflow.gui import icons

            copy_button = QPushButton()
            copy_button.setObjectName("icon-button")
            copy_button.setIcon(icons.icon("edit-copy-symbolic", 16, theme.TEXT_SECONDARY_SOLID))
            copy_button.setToolTip("Kopiuj tekst")
            copy_button.clicked.connect(lambda _checked=False, value=text: self._on_copy(value))
            card.body.addWidget(copy_button, 0, Qt.AlignmentFlag.AlignVCenter)
        return card
