"""Searchable local dictation history: expand, copy, delete."""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from voiceflow import statlib
from voiceflow.gui import service
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    label,
    page_header,
    page_scroll,
    section_label,
)

#: Rendering every record would build thousands of widgets for no benefit.
VISIBLE_LIMIT = 200


class HistoryPage(QWidget):
    """Newest first, grouped by day."""

    def __init__(self, window) -> None:
        super().__init__()
        self._window = window
        self._records: list[dict[str, Any]] = []
        self._query = ""

        body = QWidget()
        self._layout = QVBoxLayout(body)
        self._layout.setContentsMargins(36, 32, 36, 36)
        self._layout.setSpacing(18)
        self._layout.addWidget(
            page_header("Historia", "Wyszukuj, rozwijaj i ponownie kopiuj lokalne dyktowania.")
        )

        self._search = QLineEdit()
        self._search.setPlaceholderText("Szukaj w historii…")
        self._search.setClearButtonEnabled(True)
        self._search.textChanged.connect(self._on_search)
        self._layout.addWidget(self._search)

        self._list_host = QWidget()
        self._list = QVBoxLayout(self._list_host)
        self._list.setContentsMargins(0, 0, 0, 0)
        self._list.setSpacing(10)
        self._layout.addWidget(self._list_host)
        self._layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(body))

    def refresh(self) -> None:
        BackgroundCall(service.history_records, self._apply)

    def _apply(self, records: object) -> None:
        if isinstance(records, list):
            self._records = list(reversed(records))
        self._render()

    def _on_search(self, text: str) -> None:
        self._query = text.strip().casefold()
        self._render()

    def _matching(self) -> list[dict[str, Any]]:
        if not self._query:
            return self._records[:VISIBLE_LIMIT]
        matched = [
            record
            for record in self._records
            if self._query in str(record.get("text") or "").casefold()
        ]
        return matched[:VISIBLE_LIMIT]

    def _render(self) -> None:
        while self._list.count():
            item = self._list.takeAt(0)
            if item.widget() is not None:
                item.widget().deleteLater()

        records = self._matching()
        if not records:
            message = (
                "Brak wyników. Spróbuj innego wyszukiwania."
                if self._query
                else "Historia jest pusta. Zakończone dyktowania pojawią się tutaj."
            )
            self._list.addWidget(label(message, name="muted", wrap=True))
            return

        current_day = None
        for record in records:
            day = statlib.record_date(record)
            if day != current_day:
                current_day = day
                self._list.addWidget(section_label(day.strftime("%d.%m.%Y")))
            self._list.addWidget(_HistoryCard(record, self))


class _HistoryCard(Card):
    """One dictation; the text collapses to two lines until asked otherwise."""

    def __init__(self, record: dict[str, Any], page: HistoryPage) -> None:
        super().__init__(padding=16)
        self._record = record
        self._page = page
        self._expanded = False
        self.body.setSpacing(8)

        moment = statlib.local_datetime(str(record["timestamp"]))
        delivered = "wklejone" if record.get("injected") else "niewklejone"
        audio = float(record.get("audio_seconds", 0.0))
        meta = (
            f"{moment.strftime('%H:%M')} · {record['words']} słów · "
            f"{audio:.1f} s nagrania · {delivered}"
        )
        self.body.addWidget(label(meta, name="faint"))

        self._text = str(record.get("text") or "")
        self._text_label = label(
            self._text or "Tekst nie został zapisany.", name="muted", wrap=True
        )
        self._text_label.setMaximumHeight(44)
        self.body.addWidget(self._text_label)

        actions = QHBoxLayout()
        actions.setSpacing(8)
        if self._text:
            self._toggle = QPushButton("Rozwiń")
            self._toggle.setObjectName("ghost")
            self._toggle.clicked.connect(self._toggle_expanded)
            actions.addWidget(self._toggle)
        actions.addStretch(1)
        if self._text:
            copy_button = QPushButton("Kopiuj")
            copy_button.clicked.connect(self._copy)
            actions.addWidget(copy_button)
        delete_button = QPushButton("Usuń")
        delete_button.setObjectName("danger")
        delete_button.clicked.connect(self._delete)
        actions.addWidget(delete_button)
        self.body.addLayout(actions)

    def _toggle_expanded(self) -> None:
        self._expanded = not self._expanded
        self._text_label.setMaximumHeight(16777215 if self._expanded else 44)
        self._toggle.setText("Zwiń" if self._expanded else "Rozwiń")

    def _copy(self) -> None:
        try:
            service.copy_to_clipboard(self._text)
        except RuntimeError as exc:
            self._page._window.notify(str(exc), tone="error")
            return
        self._page._window.notify("Skopiowano do schowka")

    def _delete(self) -> None:
        confirm = QMessageBox(self)
        confirm.setWindowTitle("Potwierdź usunięcie")
        confirm.setText("Usunąć ten wpis z lokalnej historii?")
        confirm.setInformativeText("Tej operacji nie można cofnąć.")
        confirm.setStandardButtons(
            QMessageBox.StandardButton.Cancel | QMessageBox.StandardButton.Yes
        )
        confirm.setDefaultButton(QMessageBox.StandardButton.Cancel)
        if confirm.exec() != QMessageBox.StandardButton.Yes:
            return

        record = self._record

        def done(removed: object) -> None:
            if removed:
                self._page._window.notify("Wpis usunięty")
            self._page.refresh()

        BackgroundCall(
            lambda: service.delete_history_record(record),
            done,
            lambda message: self._page._window.notify(message, tone="error"),
        )
