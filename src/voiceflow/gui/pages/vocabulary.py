"""Editable Whisper vocabulary presented as a five-column card grid."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QGridLayout, QLineEdit, QPushButton, QVBoxLayout, QWidget

from voiceflow.gui import icons, theme
from voiceflow.gui.widgets import (
    Card,
    StyledWidget,
    clear_layout,
    empty_state,
    label,
    page_body,
    page_header,
    page_scroll,
    plain,
    section_label,
    vbox,
)

#: The grid the GTK page pins to five per line, so both wrap identically.
COLUMNS = 5


class VocabularyPage(QWidget):
    """Manage proper names and domain terms passed to Whisper."""

    def __init__(self, on_dirty: Callable[[], None], on_toast: Callable[[str], None]) -> None:
        super().__init__()
        self._on_dirty = on_dirty
        self._on_toast = on_toast
        self._terms: list[str] = []

        clamp, layout = page_body()
        layout.addWidget(
            page_header(
                "Słownik",
                "Dodaj nazwy własne i terminy, które Whisper ma rozpoznawać dokładniej.",
            )
        )

        add_card = Card(horizontal=True)
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("Dodaj termin…")
        self.entry.returnPressed.connect(self._on_add)
        add_card.body.addWidget(self.entry, 1)
        add_button = QPushButton("Dodaj")
        add_button.setObjectName("primary-button")
        add_button.clicked.connect(self._on_add)
        add_card.body.addWidget(add_button)
        layout.addWidget(add_card)

        terms_group = plain(vbox(theme.SPACE_16))
        self.counter = section_label("0 terminów")
        terms_group.layout().addWidget(self.counter)
        self.terms_holder = vbox(0)
        terms_group.layout().addLayout(self.terms_holder)
        layout.addWidget(terms_group)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))
        self._render()

    def load_config(self, config: Mapping[str, Any]) -> None:
        """Replace the editor state from a raw configuration mapping."""
        from voiceflow.gui import service

        self._terms = service.string_list_value(service.section(config, "model"), "vocabulary")
        self.entry.setText("")
        self._render()

    def apply_to_config(self, config: dict[str, Any]) -> None:
        """Overlay the vocabulary while preserving unknown model keys."""
        from voiceflow.gui import service

        service.mutable_section(config, "model")["vocabulary"] = list(self._terms)

    # -- editing -------------------------------------------------------------

    def _on_add(self) -> None:
        term = self.entry.text().strip()
        if not term:
            return
        if term.casefold() in {item.casefold() for item in self._terms}:
            self._on_toast("Ten termin jest już w słowniku")
            return
        self._terms.append(term)
        self.entry.setText("")
        self._render()
        self._on_dirty()

    def _remove(self, term: str) -> None:
        if term not in self._terms:
            return
        self._terms.remove(term)
        self._render()
        self._on_dirty()

    # -- drawing -------------------------------------------------------------

    def _render(self) -> None:
        clear_layout(self.terms_holder)
        count = len(self._terms)
        self.counter.setText("1 TERMIN" if count == 1 else f"{count} TERMINÓW")
        if not self._terms:
            self.terms_holder.addWidget(
                empty_state(
                    "accessories-dictionary-symbolic",
                    "Słownik jest pusty. Dodaj pierwszy termin w polu powyżej.",
                )
            )
            return

        grid_host = plain()
        grid = QGridLayout(grid_host)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(theme.SPACE_8)
        for index, term in enumerate(self._terms):
            grid.addWidget(_Tile(term, self._remove), index // COLUMNS, index % COLUMNS)
        for column in range(COLUMNS):
            grid.setColumnStretch(column, 1)
        self.terms_holder.addWidget(grid_host)


class _Tile(StyledWidget):
    """One term, with a remove button that appears under the pointer."""

    def __init__(self, term: str, on_remove: Callable[[str], None]) -> None:
        super().__init__()
        self.setObjectName("vocabulary-tile")
        self.setMinimumHeight(56)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(theme.SPACE_16, theme.SPACE_12, theme.SPACE_16, theme.SPACE_12)
        text = label(term, "vocabulary-term", wrap=True)
        text.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(text)

        self._remove = QPushButton(self)
        self._remove.setObjectName("vocabulary-remove")
        self._remove.setIcon(icons.icon("window-close-symbolic", 12, theme.TEXT_SECONDARY_SOLID))
        self._remove.setToolTip(f"Usuń termin {term}")
        self._remove.setFixedSize(24, 24)
        self._remove.setCursor(Qt.CursorShape.PointingHandCursor)
        self._remove.clicked.connect(lambda: on_remove(term))
        self._remove.hide()

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().resizeEvent(event)
        self._remove.move(self.width() - self._remove.width() - 4, 4)

    def enterEvent(self, event) -> None:  # noqa: N802 - Qt naming
        self._remove.show()
        self._remove.raise_()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802 - Qt naming
        self._remove.hide()
        super().leaveEvent(event)
