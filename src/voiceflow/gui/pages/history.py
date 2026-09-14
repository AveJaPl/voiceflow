"""Searchable, expandable, local-only dictation history page."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from datetime import date, timedelta
from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QLineEdit, QPushButton, QVBoxLayout, QWidget

from voiceflow import statlib
from voiceflow.gui import theme
from voiceflow.gui.widgets import (
    Card,
    Chevron,
    ClampedLabel,
    Separator,
    clear_layout,
    empty_state,
    hbox,
    label,
    page_body,
    page_header,
    page_scroll,
    plain,
    repolish,
    section_label,
    vbox,
)

#: How much of the file the page shows. Older entries are still on disk; this
#: is a window into it, not a database browser.
VISIBLE_RECORDS = 200


def _day_title(day: date) -> str:
    today = date.today()
    if day == today:
        return "DZISIAJ"
    if day == today - timedelta(days=1):
        return "WCZORAJ"
    return day.strftime("%d.%m.%Y")


def _time_title(timestamp: str) -> str:
    return statlib.local_datetime(timestamp).strftime("%H:%M")


def _record_key(record: Mapping[str, Any]) -> str:
    return "\x1f".join(
        (
            str(record.get("timestamp", "")),
            str(record.get("words", 0)),
            str(record.get("chars", 0)),
            str(record.get("text") or ""),
        )
    )


class HistoryPage(QWidget):
    """Render the newest two hundred records grouped by day."""

    def __init__(
        self,
        on_copy: Callable[[str], None],
        on_delete: Callable[[Mapping[str, Any]], None],
    ) -> None:
        super().__init__()
        self._on_copy = on_copy
        self._on_delete = on_delete
        self._records: list[dict[str, Any]] = []
        self._expanded: set[str] = set()

        clamp, layout = page_body()
        layout.addWidget(
            page_header("Historia", "Wyszukuj, rozwijaj i ponownie kopiuj lokalne dyktowania.")
        )

        self.search = QLineEdit()
        self.search.setPlaceholderText("Szukaj w historii…")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(lambda _text: self._render())
        layout.addWidget(self.search)

        self._list = vbox(theme.SPACE_32)
        layout.addLayout(self._list)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))
        self._render()

    def update_history(self, records: list[dict[str, Any]]) -> None:
        """Replace current records with the newest-first view source."""
        self._records = list(reversed(records[-VISIBLE_RECORDS:]))
        available = {_record_key(record) for record in self._records}
        self._expanded.intersection_update(available)
        self._render()

    def _render(self) -> None:
        clear_layout(self._list)
        query = self.search.text().strip().casefold()
        visible = [
            record
            for record in self._records
            if not query or query in str(record.get("text") or "").casefold()
        ]
        if not visible:
            message = (
                "Brak wyników. Spróbuj innego wyszukiwania."
                if query
                else "Historia jest pusta. Zakończone dyktowania pojawią się tutaj."
            )
            self._list.addWidget(empty_state("document-open-recent-symbolic", message))
            return

        grouped: dict[date, list[dict[str, Any]]] = {}
        for record in visible:
            grouped.setdefault(statlib.record_date(record), []).append(record)
        for day, records in grouped.items():
            group = plain(vbox(theme.SPACE_16))
            group.layout().addWidget(section_label(_day_title(day)))
            for record in records:
                group.layout().addWidget(_RecordCard(record, self))
            self._list.addWidget(group)

    # -- called by the cards --------------------------------------------------

    def is_expanded(self, key: str) -> bool:
        return key in self._expanded

    def set_expanded(self, key: str, expanded: bool) -> None:
        if expanded:
            self._expanded.add(key)
        else:
            self._expanded.discard(key)

    def copy(self, text: str) -> None:
        self._on_copy(text)

    def delete(self, record: Mapping[str, Any], key: str) -> None:
        self._expanded.discard(key)
        self._on_delete(record)


class _RecordCard(Card):
    """One dictation: a summary that toggles, and details behind it."""

    def __init__(self, record: Mapping[str, Any], page: HistoryPage) -> None:
        super().__init__(padding=0, spacing=0)
        self._record = record
        self._page = page
        self._key = _record_key(record)
        self._confirming = False

        text = record.get("text")
        self._text = text if isinstance(text, str) and text else ""
        content = self._text or "(treść nie była zapisywana)"

        self._toggle = QPushButton()
        self._toggle.setObjectName("history-toggle")
        self._toggle.clicked.connect(self._on_toggle)
        summary = hbox(theme.SPACE_16)
        summary.setContentsMargins(theme.SPACE_20, theme.SPACE_20, theme.SPACE_20, theme.SPACE_20)
        body = vbox(theme.SPACE_8)
        body.addWidget(
            label(
                f"{_time_title(str(record['timestamp']))} · {record.get('words', 0)} słów",
                "history-meta",
            )
        )
        body.addWidget(ClampedLabel(content, "history-preview", lines=2))
        summary.addLayout(body, 1)
        self._chevron = Chevron()
        summary.addWidget(self._chevron, 0, Qt.AlignmentFlag.AlignVCenter)
        self._toggle.setLayout(summary)
        self.body.addWidget(self._toggle)

        self._detail = plain(vbox(theme.SPACE_16))
        self._detail.setObjectName("history-detail")
        detail_layout = self._detail.layout()
        detail_layout.setContentsMargins(
            theme.SPACE_20, theme.SPACE_20, theme.SPACE_20, theme.SPACE_20
        )
        detail_layout.addWidget(label(content, "history-full-text", wrap=True, selectable=True))

        actions = plain(hbox(theme.SPACE_8))
        if self._text:
            copy_button = QPushButton("Kopiuj")
            copy_button.setObjectName("secondary-button")
            copy_button.clicked.connect(lambda: self._page.copy(self._text))
            actions.layout().addWidget(copy_button)
        self._delete_button = QPushButton("Usuń wpis")
        self._delete_button.setObjectName("destructive-button")
        self._delete_button.clicked.connect(self._on_delete)
        actions.layout().addWidget(self._delete_button)
        actions.layout().addStretch(1)
        detail_layout.addWidget(actions)

        self.body.addWidget(Separator())
        self.body.addWidget(self._detail)
        self._apply_expanded(page.is_expanded(self._key))

    def _apply_expanded(self, expanded: bool) -> None:
        self._detail.setVisible(expanded)
        # The hairline belongs to the detail panel, so it goes with it.
        self.body.itemAt(1).widget().setVisible(expanded)
        self._chevron.set_expanded(expanded)
        self._toggle.setToolTip(
            "Zwiń szczegóły wpisu" if expanded else "Rozwiń szczegóły wpisu"
        )

    def _on_toggle(self) -> None:
        expanded = not self._detail.isVisible()
        self._page.set_expanded(self._key, expanded)
        self._apply_expanded(expanded)
        if not expanded:
            self._reset_confirmation()

    def _on_delete(self) -> None:
        # Two presses, in place. A modal dialog for one history line is heavier
        # than the action it guards.
        if not self._confirming:
            self._confirming = True
            self._delete_button.setText("Potwierdź usunięcie")
            self._delete_button.setProperty("confirming", "true")
            repolish(self._delete_button)
            return
        self._page.delete(self._record, self._key)

    def _reset_confirmation(self) -> None:
        self._confirming = False
        self._delete_button.setText("Usuń wpis")
        self._delete_button.setProperty("confirming", "false")
        repolish(self._delete_button)
