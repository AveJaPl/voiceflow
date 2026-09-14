"""Kronika pokoju: zamknięte sesje i dorobek każdej osoby przez wszystkie.

Osobno od zakładki „Pokój", bo tamta odpowiada na pytanie „co jest teraz", a ta
na „co już było". Zlepione razem robiły jedną stronę, która przewija się w
nieskończoność i miesza dwa różne pytania.

Strona webowa tego nie pokazuje i nie ma pokazywać — tam liczy się wyłącznie
bieżąca sesja, bo to jest ekran, na który patrzy się w trakcie pracy.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

from voiceflow_app import services, style
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.roomdata import (
    RoomDataError,
    fetch_history,
    format_duration,
    people_word,
    session_span,
    sessions_word,
    words_word,
)

DEFAULT_SERVER = "wss://rooms.pbdevs.com"


class SessionsPage(Gtk.ScrolledWindow):
    """Past sessions of the room this machine belongs to."""

    def __init__(self, on_toast: Callable[[str], None]) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_toast = on_toast
        #: Ostatnio pobrana kronika. Trzymana między wejściami na zakładkę, żeby
        #: powrót tutaj był natychmiastowy — pobranie idzie w tle i podmienia
        #: zawartość dopiero, gdy jest co podmienić.
        self._sessions: list[dict[str, Any]] = []
        self._people: list[dict[str, Any]] = []
        self._totals: dict[str, Any] = {}
        self._has_more = False
        self._loaded_for = ""
        self._loading = False
        self._server = DEFAULT_SERVER
        self._code = ""

        content = page_content(self)
        content.append(
            page_header(
                "Sesje",
                "Co już było w tym pokoju: zamknięte sesje i dorobek każdej osoby przez wszystkie.",
            )
        )

        totals = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        self._totals_label = label("RAZEM W TYM POKOJU", "section-label")
        totals.append(self._totals_label)
        self._totals_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8)
        totals.append(self._totals_holder)
        content.append(totals)

        history = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        history.append(label("HISTORIA SESJI", "section-label"))
        self._history_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8)
        history.append(self._history_holder)
        content.append(history)

        self._render()

    def refresh(self) -> None:
        """Reload the room from configuration and fetch its history."""
        try:
            raw = services.load_raw_config()
        except RuntimeError as exc:
            self._on_toast(str(exc))
            return
        room = services.section(raw, "room")
        self._server = services.string_value(room, "server", DEFAULT_SERVER)
        self._code = (
            services.string_value(room, "code", "").upper()
            if services.bool_value(room, "enabled", False)
            else ""
        )
        if self._code != self._loaded_for:
            # Zmienił się pokój — to, co mamy w pamięci, dotyczy innego miejsca.
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

        def worker() -> None:
            try:
                document = fetch_history(server, code, offset)
            except RoomDataError as exc:
                GLib.idle_add(self._finish, None, offset, str(exc))
                return
            GLib.idle_add(self._finish, document, offset, "")

        threading.Thread(target=worker, name="room-history", daemon=True).start()

    def _finish(self, document: dict[str, Any] | None, offset: int, error: str) -> bool:
        self._loading = False
        if document is None:
            self._on_toast(error)
            self._render()
            return False
        page = document.get("sessions") or []
        # Pierwsza strona zastępuje, kolejne dokładają — inaczej „pokaż starsze"
        # gubiłoby to, co użytkownik już ma przed oczami.
        self._sessions = list(page) if offset == 0 else self._sessions + list(page)
        self._people = document.get("people") or []
        self._totals = document.get("totals") or {}
        self._has_more = bool(document.get("hasMore"))
        self._loaded_for = self._code
        self._render()
        return False

    # -- rysowanie ----------------------------------------------------------

    def _render(self) -> None:
        while child := self._totals_holder.get_first_child():
            self._totals_holder.remove(child)
        while child := self._history_holder.get_first_child():
            self._history_holder.remove(child)

        if not self._code:
            self._totals_label.set_label("RAZEM W TYM POKOJU")
            self._history_holder.append(
                empty_state(
                    "system-users-symbolic",
                    "Nie jesteś w żadnym pokoju. Utwórz go albo dołącz w zakładce Pokój.",
                )
            )
            return

        people, sessions, totals = self._people, self._sessions, self._totals

        words = int(totals.get("words") or 0)
        count = int(totals.get("sessions") or 0)
        self._totals_label.set_label(
            f"RAZEM W TYM POKOJU · {words} SŁÓW W {count} {'SESJI' if count == 1 else 'SESJACH'}"
            if words
            else "RAZEM W TYM POKOJU"
        )

        for person in people:
            appearances = int(person.get("sessions") or 0)
            average = int(person.get("averageWords") or 0)
            self._totals_holder.append(
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
            # Póki nic nie przyszło, NIE twierdzimy, że pokój jest pusty.
            # Wcześniej strona pisała „to pierwsza sesja" w trakcie pobierania,
            # co czytało się jak zawieszenie.
            self._history_holder.append(
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
            self._history_holder.append(
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
            more = Gtk.Button(label="Pokaż starsze sesje")
            more.set_halign(Gtk.Align.CENTER)
            more.connect("clicked", lambda _b: self._load(offset=len(self._sessions)))
            self._history_holder.append(more)

    def _render_status(self) -> None:
        """Redraw only when the list is still empty; nie migamy tym, co już jest."""
        if not self._sessions:
            self._render()

    def _row(
        self, title: str, detail: str, words: int, seconds: int, *, highlight: bool = False
    ) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_16)
        card.add_css_class("card")
        card.add_css_class("content-card")
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
        text.set_hexpand(True)
        name = label(title, "card-title")
        if highlight:
            name.add_css_class("recording-dot")
        text.append(name)
        text.append(label(detail, "section-hint"))
        card.append(text)
        for value, caption in ((str(words), "SŁÓW"), (format_duration(seconds), "MÓWIENIA")):
            column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
            column.set_valign(Gtk.Align.CENTER)
            column.append(label(value, "stat-value"))
            column.append(label(caption, "stat-label"))
            card.append(column)
        return card
