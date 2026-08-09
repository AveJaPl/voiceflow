"""Landing page: is it running, what did it just hear, how much today."""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QHBoxLayout, QPushButton, QVBoxLayout, QWidget

from voiceflow import statlib
from voiceflow.gui import service, theme
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    StatTile,
    StatusDot,
    label,
    page_header,
    page_scroll,
    section_label,
)

_STATE_TEXT = {
    "IDLE": "Gotowy",
    "RECORDING": "Nagrywanie",
    "TRANSCRIBING": "Przetwarzanie",
}
_STATE_COLOUR = {
    "IDLE": theme.POSITIVE,
    "RECORDING": theme.ACCENT,
    "TRANSCRIBING": theme.WARNING,
}


class DashboardPage(QWidget):
    """Live status plus the numbers that answer "is this thing helping?"."""

    def __init__(self, window) -> None:
        super().__init__()
        self._window = window
        self._busy = False
        self._last_text: str | None = None

        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(36, 32, 36, 36)
        layout.setSpacing(22)
        layout.addWidget(page_header("Przegląd", "Twoje lokalne centrum dyktowania."))

        layout.addWidget(self._build_status_card())
        layout.addWidget(section_label("Ten tydzień"))
        layout.addWidget(self._build_tiles())
        layout.addWidget(section_label("Ostatnie dyktowanie"))
        layout.addWidget(self._build_last_card())
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(body))

    # -- construction --------------------------------------------------------

    def _build_status_card(self) -> Card:
        card = Card()
        top = QHBoxLayout()
        top.setSpacing(12)
        self._dot = StatusDot()
        self._state_label = label("Sprawdzanie…", name="card-title")
        top.addWidget(self._dot)
        top.addWidget(self._state_label)
        top.addStretch(1)

        self._toggle_button = QPushButton("Uruchom demona")
        self._toggle_button.setObjectName("primary")
        self._toggle_button.clicked.connect(self._toggle_service)
        self._restart_button = QPushButton("Uruchom ponownie")
        self._restart_button.clicked.connect(self._restart_service)
        top.addWidget(self._restart_button)
        top.addWidget(self._toggle_button)
        card.body.addLayout(top)

        self._detail_label = label("", name="muted", wrap=True)
        card.body.addWidget(self._detail_label)
        self._hint_label = label("", name="faint", wrap=True)
        card.body.addWidget(self._hint_label)
        return card

    def _build_tiles(self) -> QWidget:
        container = QWidget()
        layout = QHBoxLayout(container)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)
        self._tiles = {
            "words": StatTile("Słowa"),
            "dictations": StatTile("Dyktowań"),
            "audio": StatTile("Czas mówienia"),
            "streak": StatTile("Dni z rzędu"),
        }
        for tile in self._tiles.values():
            layout.addWidget(tile, 1)
        return container

    def _build_last_card(self) -> Card:
        card = Card()
        self._last_meta = label("", name="faint")
        self._last_body = label(
            "Pierwsze zakończone dyktowanie pojawi się tutaj.", name="muted", wrap=True
        )
        card.body.addWidget(self._last_meta)
        card.body.addWidget(self._last_body)

        actions = QHBoxLayout()
        actions.addStretch(1)
        self._copy_button = QPushButton("Kopiuj tekst")
        self._copy_button.setEnabled(False)
        self._copy_button.clicked.connect(self._copy_last)
        actions.addWidget(self._copy_button)
        card.body.addLayout(actions)
        return card

    # -- refreshing ----------------------------------------------------------

    def refresh(self) -> None:
        """Poll the daemon and re-read history, both off the UI thread."""
        BackgroundCall(service.daemon_status, self._apply_status)
        BackgroundCall(lambda: statlib_summary(), self._apply_history)

    def _apply_status(self, status: object) -> None:
        if self._busy:
            return
        if not isinstance(status, dict):
            self._dot.set_colour(theme.FAINT)
            self._state_label.setText("Demon nie działa")
            self._detail_label.setText("Usługa jest zatrzymana lub nie odpowiada.")
            self._hint_label.setText("")
            self._toggle_button.setText("Uruchom demona")
            self._toggle_button.setEnabled(True)
            self._restart_button.setEnabled(False)
            return
        state = str(status.get("state", "?"))
        self._dot.set_colour(_STATE_COLOUR.get(state, theme.WARNING))
        self._state_label.setText(_STATE_TEXT.get(state, f"Nieznany stan: {state}"))
        self._detail_label.setText(
            f"Model {status.get('model', '?')} — {status.get('device', '?')}"
            f"/{status.get('compute_type', '?')}"
        )
        hotkey = status.get("hotkey")
        self._hint_label.setText(
            f"Skrót: {hotkey} — wciśnij, mów, wciśnij ponownie." if hotkey else ""
        )
        self._toggle_button.setText("Zatrzymaj demona")
        self._toggle_button.setEnabled(True)
        self._restart_button.setEnabled(True)

    def _apply_history(self, summary: object) -> None:
        if not isinstance(summary, dict):
            return
        self._tiles["words"].set_value(statlib.compact_number(summary["words"]))
        self._tiles["dictations"].set_value(statlib.compact_number(summary["dictations"]))
        self._tiles["audio"].set_value(statlib.format_duration(summary["audio_seconds"]))
        self._tiles["streak"].set_value(str(summary["streak"]))

        last = summary["last"]
        if last is None:
            self._last_meta.setText("")
            self._last_body.setText("Pierwsze zakończone dyktowanie pojawi się tutaj.")
            self._copy_button.setEnabled(False)
            self._last_text = None
            return
        moment = statlib.local_datetime(str(last["timestamp"]))
        delivered = "wklejone" if last.get("injected") else "niewklejone"
        self._last_meta.setText(
            f"{moment.strftime('%d.%m.%Y %H:%M')} · {last['words']} słów · {delivered}"
        )
        text = last.get("text")
        self._last_text = text if isinstance(text, str) and text else None
        self._last_body.setText(
            self._last_text or "Tekst nie jest zapisywany (history.store_text = false)."
        )
        self._copy_button.setEnabled(self._last_text is not None)

    # -- actions -------------------------------------------------------------

    def _toggle_service(self) -> None:
        running = self._toggle_button.text().startswith("Zatrzymaj")
        self._run_service(service.stop_daemon if running else service.start_daemon,
                          "Zatrzymano demona" if running else "Uruchomiono demona")

    def _restart_service(self) -> None:
        self._run_service(service.restart_daemon, "Demon uruchomiony ponownie")

    def _run_service(self, action, success: str) -> None:
        # One service action at a time, and the status poll must not overwrite
        # the button mid-flight — restarting takes seconds.
        self._busy = True
        self._toggle_button.setEnabled(False)
        self._restart_button.setEnabled(False)
        self._state_label.setText("Chwileczkę…")

        def finished(_result: object = None, error: str | None = None) -> None:
            self._busy = False
            if error:
                self._window.notify(error, tone="error")
            else:
                self._window.notify(success)
            self.refresh()

        BackgroundCall(action, lambda result: finished(result), lambda message: finished(error=message))

    def _copy_last(self) -> None:
        if not self._last_text:
            return
        try:
            service.copy_to_clipboard(self._last_text)
        except RuntimeError as exc:
            self._window.notify(str(exc), tone="error")
            return
        self._window.notify("Skopiowano do schowka")


def statlib_summary() -> dict[str, Any]:
    """Aggregate the last week plus the newest record, in one file read."""
    records = service.history_records()
    week_start = date.today() - timedelta(days=6)
    recent = [
        record
        for record in records
        if statlib.record_date(record) >= week_start
    ]
    aggregate = statlib.totals(recent)
    return {
        "words": int(aggregate["words"]),
        "dictations": int(aggregate["dictations"]),
        "audio_seconds": float(aggregate["audio_seconds"]),
        "streak": statlib.current_streak(records),
        "last": records[-1] if records else None,
    }
