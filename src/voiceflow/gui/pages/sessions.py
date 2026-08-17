"""The room's chronicle: closed sessions and what each person did across them.

Separate from the Room page because that one answers "what is happening now"
and this one answers "what already happened". Glued together they made a single
page that scrolls forever and mixes two different questions.

The web board deliberately shows none of this — there only the current session
matters, because that is the screen people look at while working.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QPushButton, QVBoxLayout, QWidget

from voiceflow.gui import service, theme
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
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
from voiceflow.roomboard import (
    DEFAULT_SERVER,
    fetch_history,
    format_duration,
    people_word,
    session_span,
    sessions_word,
    words_word,
)


class SessionsPage(QWidget):
    """Past sessions of the room this machine belongs to."""

    def __init__(self, on_toast: Callable[[str], None]) -> None:
        super().__init__()
        self._on_toast = on_toast
        #: The last chronicle fetched. Kept between visits so coming back here
        #: is instant — the fetch runs in the background and swaps the content
        #: only once there is something to swap in.
        self._sessions: list[dict[str, Any]] = []
        self._people: list[dict[str, Any]] = []
        self._totals: dict[str, Any] = {}
        self._has_more = False
        self._loaded_for = ""
        self._loading = False
        self._server = DEFAULT_SERVER
        self._code = ""

        clamp, layout = page_body()
        layout.addWidget(
            page_header(
                "Sesje",
                "Co już było w tym pokoju: zamknięte sesje i dorobek każdej osoby "
                "przez wszystkie.",
            )
        )

        totals = plain(vbox(theme.SPACE_12))
        self._totals_label = section_label("Razem w tym pokoju")
        totals.layout().addWidget(self._totals_label)
        self._totals_holder = vbox(theme.SPACE_8)
        totals.layout().addLayout(self._totals_holder)
        layout.addWidget(totals)

        history = plain(vbox(theme.SPACE_12))
        history.layout().addWidget(section_label("Historia sesji"))
        self._history_holder = vbox(theme.SPACE_8)
        history.layout().addLayout(self._history_holder)
        layout.addWidget(history)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))
        self._render()

    def refresh(self) -> None:
        """Reload the room from configuration and fetch its history."""
        try:
            raw = service.load_raw_config()
        except RuntimeError as exc:
            self._on_toast(str(exc))
            return
        room = service.section(raw, "room")
        self._server = service.string_value(room, "server", DEFAULT_SERVER)
        self._code = (
            service.string_value(room, "code", "").upper()
            if service.bool_value(room, "enabled", False)
            else ""
        )
        if self._code != self._loaded_for:
            # The room changed — what is in memory describes somewhere else.
            self._sessions, self._people, self._totals = [], [], {}
            self._has_more = False
        self._render()
        if self._code:
            self._load(offset=0)

    def _load(self, *, offset: int) -> None:
        """Fetch one page in the background, keeping what is already on screen."""
        if self._loading or not self._code:
            return
        self._loading = True
        self._render_status()
        server, code = self._server, self._code
        BackgroundCall(
            lambda: fetch_history(server, code, offset),
            lambda document: self._finish(document, offset),
            self._failed,
        )

    def _failed(self, message: str) -> None:
        self._loading = False
        self._on_toast(message)
        self._render()

    def _finish(self, document: object, offset: int) -> None:
        self._loading = False
        if not isinstance(document, dict):
            self._render()
            return
        page = document.get("sessions") or []
        # The first page replaces, later ones append — otherwise "show older"
        # would drop what the user already has in front of them.
        self._sessions = list(page) if offset == 0 else self._sessions + list(page)
        self._people = document.get("people") or []
        self._totals = document.get("totals") or {}
        self._has_more = bool(document.get("hasMore"))
        self._loaded_for = self._code
        self._render()

    # -- drawing -------------------------------------------------------------

    def _render(self) -> None:
        clear_layout(self._totals_holder)
        clear_layout(self._history_holder)

        if not self._code:
            self._totals_label.setText("RAZEM W TYM POKOJU")
            self._history_holder.addWidget(
                empty_state(
                    "system-users-symbolic",
                    "Nie jesteś w żadnym pokoju. Utwórz go albo dołącz w zakładce Pokój.",
                )
            )
            return

        people, sessions, totals = self._people, self._sessions, self._totals

        words = int(totals.get("words") or 0)
        count = int(totals.get("sessions") or 0)
        self._totals_label.setText(
            f"RAZEM W TYM POKOJU · {words} SŁÓW W {count} "
            f"{'SESJI' if count == 1 else 'SESJACH'}"
            if words
            else "RAZEM W TYM POKOJU"
        )

        for person in people:
            appearances = int(person.get("sessions") or 0)
            average = int(person.get("averageWords") or 0)
            self._totals_holder.addWidget(
                self._row(
                    str(person.get("name") or "—"),
                    f"{appearances} {sessions_word(appearances)}"
                    f" · {int(person.get('dictations') or 0)} dyktowań"
                    f" · średnio {average} {words_word(average)}",
                    int(person.get("words") or 0),
                    int(person.get("seconds") or 0),
                )
            )

        if not sessions:
            # Until something arrives we do NOT claim the room is empty. The
            # page used to say "this is the first session" mid-fetch, which
            # read like a hang.
            self._history_holder.addWidget(
                empty_state(
                    "document-open-recent-symbolic",
                    "Wczytywanie historii…"
                    if self._loading or self._loaded_for != self._code
                    else "Ta sesja jest pierwsza w tym pokoju.",
                )
            )
            return

        for entry in sessions:
            speakers = int(entry.get("speakers") or 0)
            running = not entry.get("endedAt")
            name = str(entry.get("name") or "Sesja bez nazwy")
            self._history_holder.addWidget(
                self._row(
                    f"{name} — trwa" if running else name,
                    f"{session_span(str(entry.get('startedAt') or ''), entry.get('endedAt'))}"
                    f" · {speakers} {people_word(speakers)}"
                    f" · {int(entry.get('dictations') or 0)} dyktowań",
                    int(entry.get("words") or 0),
                    int(entry.get("seconds") or 0),
                    highlight=running,
                )
            )
        if self._has_more:
            more = QPushButton("Pokaż starsze sesje")
            more.clicked.connect(lambda: self._load(offset=len(self._sessions)))
            holder = plain(vbox(0))
            holder.layout().addWidget(more, 0, Qt.AlignmentFlag.AlignHCenter)
            self._history_holder.addWidget(holder)

    def _render_status(self) -> None:
        """Redraw only while the list is still empty; never flicker what is there."""
        if not self._sessions:
            self._render()

    def _row(
        self, title: str, detail: str, words: int, seconds: int, *, highlight: bool = False
    ) -> QWidget:
        card = Card(horizontal=True, spacing=theme.SPACE_16)
        text = plain(vbox(theme.SPACE_4))
        name = label(title, "card-title")
        if highlight:
            name.setStyleSheet(f"color: {theme.RECORDING}; background: transparent;")
        text.layout().addWidget(name)
        text.layout().addWidget(label(detail, "section-hint", wrap=True))
        card.body.addWidget(text, 1)
        for value, caption in ((str(words), "SŁÓW"), (format_duration(seconds), "MÓWIENIA")):
            column = plain(vbox(theme.SPACE_4))
            column.layout().addWidget(label(value, "stat-value"))
            column.layout().addWidget(label(caption, "stat-label"))
            card.body.addWidget(column, 0, Qt.AlignmentFlag.AlignVCenter)
        return card
