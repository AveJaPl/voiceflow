"""The shared dictation room, without a terminal.

Creating a room used to mean ``voiceflow room create --as Filip`` followed by a
manual daemon restart. This page does both, hands back the link, and offers
rooms other people are advertising nearby so nobody retypes a six-character
code.

Nothing here computes anything: the numbers come from :mod:`voiceflow.roomboard`,
the network records from :mod:`voiceflow.roomdiscovery`, and both are tested
without a window. This file only arranges widgets and moves slow work off the
UI thread.
"""

from __future__ import annotations

import getpass
import os
from collections.abc import Callable
from typing import Any

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QLineEdit, QPushButton, QVBoxLayout, QWidget

from voiceflow.gui import service, theme
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    RecordingDot,
    ShareBar,
    StatusDot,
    Switch,
    clear_layout,
    empty_state,
    hbox,
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
    RoomDataError,
    board_rows,
    fetch_ranking,
    format_duration,
    room_url,
    session_elapsed,
    words_word,
)
from voiceflow.roomdiscovery import DiscoveredRoom, visible_rooms
from voiceflow.roomstate import RoomState

#: The ranking refreshes as the web page does; the numbers need not be instant.
POLL_MS = 5000
#: The session clock has to tick, and the state file is re-read with it.
TICK_MS = 1000


class RoomPage(QWidget):
    """Create, join and watch a shared dictation room."""

    def __init__(self, on_toast: Callable[[str], None]) -> None:
        super().__init__()
        self._on_toast = on_toast

        self._server = DEFAULT_SERVER
        #: Membership is read from config.yaml, because that is what the join
        #: writes and it survives a stopped daemon. room.json speaks only of
        #: live things — who is talking, is the link up — so its absence cannot
        #: mean "you are not in a room".
        self._code = ""
        self._enabled = False
        self._state = RoomState()
        self._document: dict[str, Any] = {}
        self._discovered: list[DiscoveredRoom] = []
        self._busy = False
        self._advertise = True

        self._advertiser = service.room_advertiser()
        self._browser = service.room_browser(self._on_rooms_found)

        clamp, layout = page_body()
        layout.addWidget(
            page_header(
                "Pokój",
                "Dyktujcie razem: jedna osoba mówi naraz, a tablica liczy, kto ile powiedział.",
            )
        )
        self._outside = self._build_outside()
        self._inside = self._build_inside()
        layout.addWidget(self._outside)
        layout.addWidget(self._inside)
        layout.addStretch(1)
        self._inside.setVisible(False)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))

        self._tick_timer = QTimer(self)
        self._tick_timer.setInterval(TICK_MS)
        self._tick_timer.timeout.connect(self._tick)
        self._poll_timer = QTimer(self)
        self._poll_timer.setInterval(POLL_MS)
        self._poll_timer.timeout.connect(self._poll_now)

        self._render_nearby()

    # -- construction --------------------------------------------------------

    def _build_outside(self) -> QWidget:
        box = plain(vbox(theme.SPACE_24))

        nearby = plain(vbox(theme.SPACE_12))
        nearby.layout().addWidget(section_label("W twojej sieci"))
        self._nearby_holder = vbox(theme.SPACE_8)
        nearby.layout().addLayout(self._nearby_holder)
        box.layout().addWidget(nearby)

        name_group = plain(vbox(theme.SPACE_8))
        name_group.layout().addWidget(section_label("Twoja nazwa w rankingu"))
        self._display_name = QLineEdit()
        self._display_name.setPlaceholderText("Imię")
        self._display_name.setText(_default_display_name())
        name_group.layout().addWidget(self._display_name)
        box.layout().addWidget(name_group)

        create = Card(horizontal=True)
        self._room_name = QLineEdit()
        self._room_name.setPlaceholderText("Nazwa pokoju, np. Salon")
        create.body.addWidget(self._room_name, 1)
        create_button = QPushButton("Utwórz pokój")
        create_button.setObjectName("primary-button")
        create_button.clicked.connect(self._create)
        create.body.addWidget(create_button)
        box.layout().addWidget(create)

        join = Card(horizontal=True)
        self._join_code = QLineEdit()
        self._join_code.setObjectName("monospace-entry")
        self._join_code.setPlaceholderText("KOD POKOJU")
        self._join_code.setMaxLength(6)
        self._join_code.returnPressed.connect(lambda: self._join(self._join_code.text()))
        join.body.addWidget(self._join_code, 1)
        join_button = QPushButton("Dołącz kodem")
        join_button.clicked.connect(lambda: self._join(self._join_code.text()))
        join.body.addWidget(join_button)
        box.layout().addWidget(join)

        box.layout().addWidget(
            label(
                "Bez pokoju voiceflow działa dokładnie tak jak dziś, w pełni lokalnie. "
                "Po dołączeniu na serwer trafiają wyłącznie zdarzenia „zaczynam/kończę mówić” "
                "oraz liczba słów i sekund — nagranie i tekst nigdy.",
                "section-hint",
                wrap=True,
            )
        )
        return box

    def _build_inside(self) -> QWidget:
        box = plain(vbox(theme.SPACE_24))

        header = Card()
        self._room_title = label("Pokój", "card-title")
        header.body.addWidget(self._room_title)
        self._room_link = label("", "secondary-text", wrap=True, selectable=True)
        header.body.addWidget(self._room_link)

        actions = plain(hbox(theme.SPACE_8))
        copy_button = QPushButton("Kopiuj link")
        copy_button.clicked.connect(self._copy_link)
        actions.layout().addWidget(copy_button)
        open_button = QPushButton("Otwórz w przeglądarce")
        open_button.clicked.connect(self._open_link)
        actions.layout().addWidget(open_button)
        leave_button = QPushButton("Wyjdź z pokoju")
        leave_button.clicked.connect(self._leave)
        actions.layout().addWidget(leave_button)
        actions.layout().addStretch(1)
        header.body.addWidget(actions)

        advertise = plain(hbox(theme.SPACE_12))
        self._advertise_switch = Switch(True)
        self._advertise_switch.toggled.connect(self._on_advertise_toggled)
        advertise.layout().addWidget(self._advertise_switch)
        advertise.layout().addWidget(
            label(
                "Rozgłaszaj ten pokój w sieci lokalnej — każdy w tej sieci będzie mógł "
                "dołączyć bez podawania kodu.",
                "section-hint",
                wrap=True,
            ),
            1,
        )
        header.body.addWidget(advertise)
        box.layout().addWidget(header)

        now = Card(horizontal=True)
        self._now_dot = StatusDot()
        self._now_recording_dot = RecordingDot()
        self._now_recording_dot.setVisible(False)
        now.body.addWidget(self._now_dot, 0, Qt.AlignmentFlag.AlignVCenter)
        now.body.addWidget(self._now_recording_dot, 0, Qt.AlignmentFlag.AlignVCenter)
        now_text = plain(vbox(theme.SPACE_4))
        self._now_title = label("Cisza", "card-title")
        now_text.layout().addWidget(self._now_title)
        self._now_subtitle = label("Nikt teraz nie dyktuje", "secondary-text", wrap=True)
        now_text.layout().addWidget(self._now_subtitle)
        now.body.addWidget(now_text, 1)
        box.layout().addWidget(now)

        session = Card()
        session_top = plain(hbox(theme.SPACE_12))
        self._session_name = label("Sesja", "card-title")
        session_top.layout().addWidget(self._session_name, 1)
        self._session_clock = label("—", "stat-value")
        session_top.layout().addWidget(self._session_clock)
        session.body.addWidget(session_top)

        session_row = plain(hbox(theme.SPACE_8))
        self._new_session_name = QLineEdit()
        self._new_session_name.setPlaceholderText("Nazwa nowej sesji, np. coding session")
        session_row.layout().addWidget(self._new_session_name, 1)
        start_button = QPushButton("Zacznij sesję")
        start_button.clicked.connect(self._start_session)
        session_row.layout().addWidget(start_button)
        end_button = QPushButton("Zakończ")
        end_button.clicked.connect(self._end_session)
        session_row.layout().addWidget(end_button)
        session.body.addWidget(session_row)
        box.layout().addWidget(session)

        board = plain(vbox(theme.SPACE_12))
        board.layout().addWidget(section_label("Tablica sesji"))
        self._board_holder = vbox(theme.SPACE_8)
        board.layout().addLayout(self._board_holder)
        box.layout().addWidget(board)

        self._status = label("", "section-hint", wrap=True)
        box.layout().addWidget(self._status)
        return box

    # -- lifecycle -----------------------------------------------------------

    def refresh(self) -> None:
        """Re-read everything and start watching. Called when the page opens."""
        try:
            raw = service.load_raw_config()
        except RuntimeError as exc:
            self._on_toast(str(exc))
            raw = {}
        room = service.section(raw, "room")
        self._server = service.string_value(room, "server", DEFAULT_SERVER)
        self._enabled = service.bool_value(room, "enabled", False)
        self._code = service.string_value(room, "code", "").upper()

        self._state = service.room_state()
        self._browser.start()
        self._tick_timer.start()
        self._poll_timer.start()
        self._sync_advertisement()
        self._render()
        self._poll_now()

    def shutdown(self) -> None:
        """Stop advertising and watching — on closing the window."""
        self._tick_timer.stop()
        self._poll_timer.stop()
        self._advertiser.withdraw()
        self._browser.stop()

    def _in_room(self) -> bool:
        return self._enabled and bool(self._code)

    def _tick(self) -> None:
        # The file is read here rather than watched: an atomic replace loses a
        # file watcher, and the session clock has to tick every second anyway.
        self._reload_state()
        self._render_session()

    def _reload_state(self) -> None:
        state = service.room_state()
        if state == self._state:
            return
        self._state = state
        self._sync_advertisement()
        self._render()

    # -- the network ---------------------------------------------------------

    def _poll_now(self) -> None:
        if not self._in_room():
            return
        server, code = self._server, self._code
        BackgroundCall(
            lambda: fetch_ranking(server, code),
            self._finish_poll,
            lambda message: self._status.setText(message),
        )

    def _finish_poll(self, document: object) -> None:
        if not isinstance(document, dict):
            return
        self._document = document
        self._status.setText("Na żywo")
        self._render_room_header()
        self._render_session()
        self._render_board()
        self._sync_advertisement()

    def _on_rooms_found(self, rooms: list[DiscoveredRoom]) -> None:
        # Called from a zeroconf thread; a timer hop puts the redraw back on
        # the UI thread, where touching widgets is legal.
        self._discovered = rooms
        QTimer.singleShot(0, self._render_nearby)

    # -- actions -------------------------------------------------------------

    def _create(self) -> None:
        name = self._display_name.text().strip()
        if not name:
            self._on_toast("Podaj swoją nazwę w rankingu")
            return
        room_name = self._room_name.text().strip()
        server = self._server
        self._run_room_action(
            lambda: service.create_room(server, room_name, name),
            "Pokój utworzony",
            open_browser=True,
        )

    def _join(self, code: str) -> None:
        name = self._display_name.text().strip()
        if not name:
            self._on_toast("Podaj swoją nazwę w rankingu")
            return
        wanted = code.strip().upper()
        if not wanted:
            self._on_toast("Podaj kod pokoju")
            return
        server = self._server
        self._run_room_action(
            lambda: service.join_room(server, wanted, name), f"Dołączono do {wanted}"
        )

    def _leave(self) -> None:
        self._run_room_action(service.leave_room, "Wyszedłeś z pokoju")

    def _run_room_action(
        self, action: Callable[[], Any], message: str, *, open_browser: bool = False
    ) -> None:
        if self._busy:
            return
        self._busy = True
        self._status.setText("Chwila…")
        BackgroundCall(
            action,
            lambda _result: self._finish_action(True, message, open_browser),
            lambda detail: self._finish_action(False, detail, False),
        )

    def _finish_action(self, ok: bool, message: str, open_browser: bool) -> None:
        self._busy = False
        self._on_toast(message)
        self._status.setText("" if ok else message)
        # The action rewrote config.yaml, so it is reloaded whole — the state
        # file alone would not do, because the daemon is only now coming back.
        self.refresh()
        if ok and open_browser:
            QTimer.singleShot(1000, self._open_link)

    def _start_session(self) -> None:
        from voiceflow.roomboard import start_session

        name = self._new_session_name.text().strip()
        server, code = self._server, self._code
        BackgroundCall(
            lambda: start_session(server, code, name),
            lambda _result: self._after_session_change("Nowa sesja ruszyła"),
            self._on_toast,
        )

    def _end_session(self) -> None:
        from voiceflow.roomboard import end_session

        server, code = self._server, self._code
        BackgroundCall(
            lambda: end_session(server, code),
            lambda _result: self._after_session_change("Sesja zakończona"),
            self._on_toast,
        )

    def _after_session_change(self, message: str) -> None:
        self._new_session_name.setText("")
        self._on_toast(message)
        self._poll_now()

    def _copy_link(self) -> None:
        try:
            service.copy_to_clipboard(self._link())
        except RuntimeError as exc:
            self._on_toast(str(exc))
            return
        self._on_toast("Link skopiowany")

    def _open_link(self) -> None:
        link = self._link()
        if link:
            QDesktopServices.openUrl(QUrl(link))

    def _on_advertise_toggled(self, active: bool) -> None:
        self._advertise = active
        self._sync_advertisement()

    # -- drawing -------------------------------------------------------------

    def _link(self) -> str:
        try:
            return room_url(self._server, self._code)
        except RoomDataError:
            return ""

    def _room(self) -> dict[str, Any]:
        room = self._document.get("room")
        return room if isinstance(room, dict) else {}

    def _sync_advertisement(self) -> None:
        if self._in_room() and self._advertise:
            self._advertiser.publish(
                code=self._code,
                name=str(self._room().get("name") or ""),
                host=self._display_name.text().strip(),
            )
        else:
            self._advertiser.withdraw()

    def _render(self) -> None:
        inside = self._in_room()
        self._inside.setVisible(inside)
        self._outside.setVisible(not inside)
        if inside:
            self._render_room_header()
            self._render_speaker()
            self._render_session()
            self._render_board()
        else:
            self._render_nearby()

    def _render_room_header(self) -> None:
        name = str(self._room().get("name") or "")
        self._room_title.setText(f"{name} · {self._code}" if name else self._code)
        self._room_link.setText(self._link())

    def _render_speaker(self) -> None:
        speaking = bool(self._state.speaking_here or self._state.speaking)
        self._now_dot.setVisible(not speaking)
        self._now_recording_dot.setVisible(speaking)
        if self._state.speaking_here:
            self._now_title.setText("Mówisz Ty")
            self._now_subtitle.setText("Reszta pokoju czeka, aż skończysz")
        elif self._state.speaking:
            self._now_title.setText(f"{self._state.speaking} dyktuje")
            self._now_subtitle.setText(
                "Twój skrót nie zacznie nagrywać — dwa mikrofony naraz psują obie transkrypcje"
            )
        else:
            self._now_title.setText("Cisza")
            if self._state.connected:
                message = "Nikt teraz nie dyktuje"
            elif self._state.code:
                message = "Brak połączenia z serwerem pokoi — dyktowanie działa lokalnie"
            else:
                # The daemon has not reported anything yet. That is NOT the same
                # as a dropped link; claiming one would be an invention.
                message = "Demon nie zgłosił jeszcze stanu pokoju — zrestartuj voiceflow"
            self._now_subtitle.setText(message)

    def _render_session(self) -> None:
        session = self._document.get("session")
        if not isinstance(session, dict):
            self._session_name.setText("Brak otwartej sesji")
            self._session_clock.setText("—")
            return
        self._session_name.setText(str(session.get("name") or "Sesja bez nazwy"))
        self._session_clock.setText(session_elapsed(str(session.get("started_at") or "")))

    def _render_board(self) -> None:
        clear_layout(self._board_holder)
        ranking = self._document.get("ranking")
        members = self._document.get("members")
        rows = board_rows(
            ranking if isinstance(ranking, list) else [],
            members if isinstance(members, list) else [],
        )
        if not rows:
            self._board_holder.addWidget(
                empty_state(
                    "system-users-symbolic",
                    "Jeszcze nikt nie dołączył do tego pokoju. "
                    "Podaj komuś kod albo link.",
                )
            )
            return
        for row in rows:
            self._board_holder.addWidget(self._board_row(row))

    def _board_row(self, row) -> QWidget:
        card = Card(horizontal=True, spacing=theme.SPACE_16)

        position = label(f"{row.position:02d}", "stat-value")
        card.body.addWidget(position, 0, Qt.AlignmentFlag.AlignVCenter)

        middle = plain(vbox(theme.SPACE_4))
        name = label(row.name, "card-title")
        if row.name == self._state.speaking:
            name.setStyleSheet(f"color: {theme.RECORDING}; background: transparent;")
        middle.layout().addWidget(name)
        share = ShareBar()
        share.setValue(row.share)
        middle.layout().addWidget(share)
        if row.dictations:
            detail = (
                f"{row.dictations} dyktowań · średnio {row.average_words} "
                f"{words_word(row.average_words)} · {row.share}% sesji"
            )
            if row.behind:
                detail = f"{detail} · brakuje {row.behind}"
        else:
            # "0 dyktowań · średnio 0 słów · 0% sesji" is four ways of saying
            # the same nothing at somebody who has only just walked in.
            detail = "W pokoju, jeszcze nic nie podyktował"
        middle.layout().addWidget(label(detail, "section-hint", wrap=True))
        card.body.addWidget(middle, 1)

        for value, caption in ((str(row.words), "SŁÓW"), (format_duration(row.seconds), "MÓWIENIA")):
            column = plain(vbox(theme.SPACE_4))
            column.layout().addWidget(label(value, "stat-value"))
            column.layout().addWidget(label(caption, "stat-label"))
            card.body.addWidget(column, 0, Qt.AlignmentFlag.AlignVCenter)
        return card

    def _render_nearby(self) -> None:
        clear_layout(self._nearby_holder)
        rooms = visible_rooms(self._discovered, self._code)
        if not rooms:
            self._nearby_holder.addWidget(
                empty_state(
                    "network-wireless-symbolic",
                    "Nikt w tej sieci nie rozgłasza pokoju. Utwórz własny albo wpisz kod.",
                )
            )
            return
        for room in rooms:
            card = Card(horizontal=True)
            text = plain(vbox(theme.SPACE_4))
            text.layout().addWidget(label(room.title, "card-title"))
            text.layout().addWidget(label(room.subtitle, "section-hint"))
            card.body.addWidget(text, 1)
            button = QPushButton("Dołącz")
            button.setObjectName("primary-button")
            button.clicked.connect(lambda _checked=False, code=room.code: self._join(code))
            card.body.addWidget(button, 0, Qt.AlignmentFlag.AlignVCenter)
            self._nearby_holder.addWidget(card)


def _default_display_name() -> str:
    """A first guess at the name that will appear on the board."""
    try:
        name = os.environ.get("USERNAME") or os.environ.get("USER") or getpass.getuser()
    except Exception:  # noqa: BLE001 - a nameless account is not an error
        name = ""
    return name.capitalize()
