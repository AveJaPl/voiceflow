"""The decoding-bias vocabulary: proper nouns Whisper otherwise mangles."""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import service
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    label,
    page_header,
    page_scroll,
)

#: Mirrors MAX_PROMPT_CHARS in the transcriber: past this the prompt starts
#: crowding out the audio and leaking into transcripts.
PROMPT_BUDGET = 600
COLUMNS = 4
#: How long to wait for the user to stop editing before reloading the daemon.
RESTART_DEBOUNCE_MS = 3000


class VocabularyPage(QWidget):
    """Add and remove terms; saved into model.vocabulary."""

    def __init__(self, window) -> None:
        super().__init__()
        self._window = window
        self._raw: dict[str, Any] = {}
        self._terms: list[str] = []
        self._restart_timer = QTimer(self)
        self._restart_timer.setSingleShot(True)
        self._restart_timer.timeout.connect(self._restart_daemon)

        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(36, 32, 36, 36)
        layout.setSpacing(20)
        layout.addWidget(
            page_header(
                "Słownik",
                "Nazwy własne i żargon, w stronę których ma się skłaniać model. "
                "To tylko podpowiedź — voiceflow nigdy nie przepisuje Twoich słów.",
            )
        )

        entry_row = QHBoxLayout()
        self._entry = QLineEdit()
        self._entry.setPlaceholderText("Dodaj termin…")
        self._entry.returnPressed.connect(self._add)
        entry_row.addWidget(self._entry, 1)
        add_button = QPushButton("Dodaj")
        add_button.setObjectName("primary")
        add_button.clicked.connect(self._add)
        entry_row.addWidget(add_button)
        layout.addLayout(entry_row)

        self._budget = label("", name="faint")
        layout.addWidget(self._budget)

        self._grid_host = QWidget()
        self._grid = QVBoxLayout(self._grid_host)
        self._grid.setContentsMargins(0, 0, 0, 0)
        self._grid.setSpacing(10)
        layout.addWidget(self._grid_host)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(body))

    def refresh(self) -> None:
        BackgroundCall(service.load_raw_config, self._apply, self._failed)

    def _failed(self, message: str) -> None:
        self._window.notify(message, tone="error")

    def _apply(self, raw: object) -> None:
        if not isinstance(raw, dict):
            return
        self._raw = raw
        self._terms = service.string_list_value(service.section(raw, "model"), "vocabulary")
        self._render()

    def _render(self) -> None:
        while self._grid.count():
            item = self._grid.takeAt(0)
            if item.widget() is not None:
                item.widget().deleteLater()

        used = sum(len(term) + 2 for term in self._terms)
        self._budget.setText(
            f"{len(self._terms)} terminów · {used}/{PROMPT_BUDGET} znaków podpowiedzi"
            + ("  — nadmiar zostanie pominięty" if used > PROMPT_BUDGET else "")
        )

        if not self._terms:
            self._grid.addWidget(
                label("Słownik jest pusty. Dodaj pierwszy termin powyżej.", name="muted")
            )
            return

        row: QHBoxLayout | None = None
        for index, term in enumerate(self._terms):
            if index % COLUMNS == 0:
                container = QWidget()
                row = QHBoxLayout(container)
                row.setContentsMargins(0, 0, 0, 0)
                row.setSpacing(10)
                self._grid.addWidget(container)
            assert row is not None
            row.addWidget(self._build_tile(term), 1)
        # Keep the last row's tiles the same width as full rows.
        remainder = len(self._terms) % COLUMNS
        if remainder and row is not None:
            for _ in range(COLUMNS - remainder):
                row.addWidget(QWidget(), 1)

    def _build_tile(self, term: str) -> Card:
        tile = Card(padding=12)
        line = QHBoxLayout()
        line.setSpacing(8)
        line.addWidget(label(term))
        line.addStretch(1)
        remove = QPushButton("×")
        remove.setObjectName("ghost")
        remove.setFixedWidth(30)
        remove.setToolTip(f"Usuń termin {term}")
        remove.clicked.connect(lambda: self._remove(term))
        line.addWidget(remove)
        tile.body.addLayout(line)
        return tile

    def _add(self) -> None:
        term = self._entry.text().strip()
        if not term:
            return
        if any(term.casefold() == existing.casefold() for existing in self._terms):
            self._window.notify("Ten termin jest już w słowniku", tone="error")
            return
        self._terms.append(term)
        self._entry.clear()
        self._render()
        self._persist()

    def _remove(self, term: str) -> None:
        self._terms = [item for item in self._terms if item != term]
        self._render()
        self._persist()

    def _persist(self) -> None:
        """Save now, restart later.

        Writing the file is cheap; restarting the daemon reloads a
        multi-gigabyte model. Typing five terms must not cost five reloads, so
        the restart is debounced and a burst of edits collapses into one.
        """
        terms = list(self._terms)

        def apply(raw: dict[str, Any]) -> None:
            service.mutable_section(raw, "model")["vocabulary"] = terms

        BackgroundCall(
            lambda: service.update_config(apply),
            self._saved,
            self._failed,
        )

    def _saved(self, written: object) -> None:
        if isinstance(written, dict):
            self._raw = written
        self._schedule_restart()

    def _schedule_restart(self) -> None:
        self._window.notify("Słownik zapisany")
        self._restart_timer.start(RESTART_DEBOUNCE_MS)

    def _restart_daemon(self) -> None:
        def work() -> None:
            # Nothing to reload if it is not running; the file is already saved.
            if service.daemon_status() is not None:
                service.restart_daemon()

        BackgroundCall(
            work,
            lambda _result: self._window.notify("Demon przeładował słownik"),
            self._failed,
        )
