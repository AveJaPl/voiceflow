"""The shared dictation room, without a terminal.

Creating a room used to mean `voiceflow room create --as Filip` followed by a
manual daemon restart. This page does both, hands back the link, and offers
rooms other people are advertising nearby so nobody retypes a six-character code.

Nothing here computes anything: the numbers come from `roomdata`, the network
records from `discovery`, and both are tested without a window. This file only
arranges widgets and moves slow work off the main thread.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

from voiceflow_app import services, style
from voiceflow_app.avahi import RoomAdvertiser, RoomBrowser
from voiceflow_app.discovery import DiscoveredRoom, visible_rooms
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.roomdata import (
    RoomDataError,
    RoomState,
    board_rows,
    end_session,
    fetch_ranking,
    format_duration,
    read_room_state,
    room_url,
    session_elapsed,
    start_session,
    words_word,
)

DEFAULT_SERVER = "wss://rooms.pbdevs.com"
#: Ranking odświeżamy tak jak strona webowa; liczby nie muszą być natychmiastowe.
POLL_SECONDS = 5


class RoomPage(Gtk.ScrolledWindow):
    """Create, join and watch a shared dictation room."""

    def __init__(self, on_toast: Callable[[str], None]) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_toast = on_toast

        self._server = DEFAULT_SERVER
        #: Przynależność do pokoju czytamy z config.yaml, bo to ją zapisuje CLI
        #: i ona przeżywa zgaszonego demona. `room.json` mówi tylko o rzeczach
        #: żywych — kto mówi i czy jest łącze — więc jego brak nie może
        #: oznaczać „nie jesteś w pokoju".
        self._code = ""
        self._enabled = False
        self._state = RoomState()
        self._document: dict[str, Any] = {}
        self._discovered: list[DiscoveredRoom] = []
        self._busy = False
        self._advertise = True

        self._advertiser = RoomAdvertiser()
        self._browser = RoomBrowser(self._on_rooms_found)
        self._monitor: Gio.FileMonitor | None = None
        self._tick_source: int | None = None
        self._poll_source: int | None = None

        content = page_content(self)
        content.append(
            page_header(
                "Pokój",
                "Dyktujcie razem: jedna osoba mówi naraz, a tablica liczy, kto ile powiedział.",
            )
        )
        self._outside = self._build_outside()
        self._inside = self._build_inside()
        content.append(self._outside)
        content.append(self._inside)
        self._inside.set_visible(False)
        self._render_nearby()

    # -- budowa widoku ------------------------------------------------------

    def _build_outside(self) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_24)

        nearby = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        nearby.append(label("W TWOJEJ SIECI", "section-label"))
        self._nearby_holder = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8
        )
        nearby.append(self._nearby_holder)
        box.append(nearby)

        name_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8)
        name_row.append(label("TWOJA NAZWA W RANKINGU", "section-label"))
        self._display_name = Gtk.Entry(placeholder_text="Imię")
        self._display_name.add_css_class("flat-entry")
        self._display_name.set_text(os.environ.get("USER", "").capitalize())
        name_row.append(self._display_name)
        box.append(name_row)

        create = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
        create.add_css_class("card")
        create.add_css_class("content-card")
        self._room_name = Gtk.Entry(placeholder_text="Nazwa pokoju, np. Salon")
        self._room_name.add_css_class("flat-entry")
        self._room_name.set_hexpand(True)
        create.append(self._room_name)
        create_button = Gtk.Button(label="Utwórz pokój")
        create_button.add_css_class("primary-button")
        create_button.connect("clicked", lambda _b: self._create())
        create.append(create_button)
        box.append(create)

        join = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
        join.add_css_class("card")
        join.add_css_class("content-card")
        self._join_code = Gtk.Entry(placeholder_text="KOD POKOJU", max_length=6)
        self._join_code.add_css_class("monospace-entry")
        self._join_code.set_hexpand(True)
        self._join_code.connect("activate", lambda _e: self._join(self._join_code.get_text()))
        join.append(self._join_code)
        join_button = Gtk.Button(label="Dołącz kodem")
        join_button.connect("clicked", lambda _b: self._join(self._join_code.get_text()))
        join.append(join_button)
        box.append(join)

        box.append(
            label(
                "Bez pokoju voiceflow działa dokładnie tak jak dziś, w pełni lokalnie. "
                "Po dołączeniu na serwer trafiają wyłącznie zdarzenia „zaczynam/kończę mówić” "
                "oraz liczba słów i sekund — nagranie i tekst nigdy.",
                "section-hint",
            )
        )
        return box

    def _build_inside(self) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_24)

        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        header.add_css_class("card")
        header.add_css_class("content-card")
        self._room_title = label("Pokój", "card-title")
        header.append(self._room_title)
        self._room_link = label("", "secondary-text")
        self._room_link.set_selectable(True)
        self._room_link.set_wrap(True)
        header.append(self._room_link)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_8)
        copy_button = Gtk.Button(label="Kopiuj link")
        copy_button.connect("clicked", lambda _b: self._copy_link())
        actions.append(copy_button)
        open_button = Gtk.Button(label="Otwórz w przeglądarce")
        open_button.connect("clicked", lambda _b: self._open_link())
        actions.append(open_button)
        leave_button = Gtk.Button(label="Wyjdź z pokoju")
        leave_button.connect("clicked", lambda _b: self._leave())
        actions.append(leave_button)
        header.append(actions)

        advertise = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
        self._advertise_switch = Gtk.Switch(active=True)
        self._advertise_switch.set_valign(Gtk.Align.CENTER)
        self._advertise_switch.connect("notify::active", self._on_advertise_toggled)
        advertise.append(self._advertise_switch)
        advertise_label = label(
            "Rozgłaszaj ten pokój w sieci lokalnej — każdy w tej sieci będzie mógł dołączyć "
            "bez podawania kodu.",
            "section-hint",
        )
        advertise_label.set_wrap(True)
        advertise_label.set_hexpand(True)
        advertise.append(advertise_label)
        header.append(advertise)
        box.append(header)

        now = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
        now.add_css_class("card")
        now.add_css_class("content-card")
        self._now_dot = label("●", "status-dot")
        self._now_dot.set_valign(Gtk.Align.CENTER)
        now.append(self._now_dot)
        now_text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
        self._now_title = label("Cisza", "card-title")
        now_text.append(self._now_title)
        self._now_subtitle = label("Nikt teraz nie dyktuje", "secondary-text")
        self._now_subtitle.set_wrap(True)
        now_text.append(self._now_subtitle)
        now.append(now_text)
        box.append(now)

        session = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        session.add_css_class("card")
        session.add_css_class("content-card")
        session_top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
        self._session_name = label("Sesja", "card-title")
        self._session_name.set_hexpand(True)
        session_top.append(self._session_name)
        self._session_clock = label("—", "stat-value")
        session_top.append(self._session_clock)
        session.append(session_top)
        session_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_8)
        self._new_session_name = Gtk.Entry(placeholder_text="Nazwa nowej sesji, np. coding session")
        self._new_session_name.add_css_class("flat-entry")
        self._new_session_name.set_hexpand(True)
        session_row.append(self._new_session_name)
        start_button = Gtk.Button(label="Zacznij sesję")
        start_button.connect("clicked", lambda _b: self._start_session())
        session_row.append(start_button)
        end_button = Gtk.Button(label="Zakończ")
        end_button.connect("clicked", lambda _b: self._end_session())
        session_row.append(end_button)
        session.append(session_row)
        box.append(session)

        board = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_12)
        board.append(label("TABLICA SESJI", "section-label"))
        self._board_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8)
        board.append(self._board_holder)
        box.append(board)

        self._status = label("", "section-hint")
        box.append(self._status)
        return box

    # -- cykl życia ---------------------------------------------------------

    def refresh(self) -> None:
        """Re-read everything and start watching. Called when the page opens."""
        raw = {}
        try:
            raw = services.load_raw_config()
        except RuntimeError as exc:
            self._on_toast(str(exc))
        room = services.section(raw, "room")
        self._server = services.string_value(room, "server", DEFAULT_SERVER)
        self._enabled = services.bool_value(room, "enabled", False)
        self._code = services.string_value(room, "code", "").upper()

        self._state = read_room_state(services.room_state_path())
        self._browser.start()
        self._ensure_monitor()
        self._ensure_timers()
        self._sync_advertisement()
        self._render()
        self._poll_now()

    def _in_room(self) -> bool:
        return self._enabled and bool(self._code)

    def shutdown(self) -> None:
        """Stop advertising and watching — on closing the window."""
        self._advertiser.withdraw()
        self._browser.stop()
        for source in (self._tick_source, self._poll_source):
            if source is not None:
                GLib.source_remove(source)
        self._tick_source = None
        self._poll_source = None

    def _ensure_timers(self) -> None:
        if self._tick_source is None:
            self._tick_source = GLib.timeout_add_seconds(1, self._tick)
        if self._poll_source is None:
            self._poll_source = GLib.timeout_add_seconds(POLL_SECONDS, self._poll)

    def _ensure_monitor(self) -> None:
        """Watch the daemon's state file so a change in speaker shows at once."""
        if self._monitor is not None:
            return
        try:
            handle = Gio.File.new_for_path(str(services.room_state_path()))
            self._monitor = handle.monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, None)
        except GLib.Error:
            return  # sekundowy tik i tak odczyta plik
        self._monitor.connect("changed", lambda *_args: self._reload_state())

    def _tick(self) -> bool:
        # Plik czytamy także tutaj: obserwator bywa gubiony przy podmianie pliku
        # przez `os.replace`, a zegar sesji i tak musi iść co sekundę.
        self._reload_state()
        self._render_session()
        return True

    def _poll(self) -> bool:
        self._poll_now()
        return True

    def _reload_state(self) -> None:
        state = read_room_state(services.room_state_path())
        if state == self._state:
            return
        self._state = state
        self._sync_advertisement()
        self._render()

    # -- dane z sieci -------------------------------------------------------

    def _poll_now(self) -> None:
        if not self._in_room():
            return
        server, code = self._server, self._code

        def worker() -> None:
            try:
                document = fetch_ranking(server, code)
            except RoomDataError as exc:
                GLib.idle_add(self._finish_poll, None, str(exc))
                return
            GLib.idle_add(self._finish_poll, document, "")

        threading.Thread(target=worker, name="room-ranking", daemon=True).start()

    def _finish_poll(self, document: dict[str, Any] | None, error: str) -> bool:
        if document is None:
            self._status.set_label(error)
            return False
        self._document = document
        self._status.set_label("Na żywo")
        self._render_room_header()
        self._render_session()
        self._render_board()
        self._sync_advertisement()
        return False

    def _on_rooms_found(self, rooms: list[DiscoveredRoom]) -> None:
        self._discovered = rooms
        GLib.idle_add(self._render_nearby)

    # -- akcje --------------------------------------------------------------

    def _create(self) -> None:
        name = self._display_name.get_text().strip()
        if not name:
            self._on_toast("Podaj swoją nazwę w rankingu")
            return
        arguments = ["create", "--server", self._server, "--as", name]
        room_name = self._room_name.get_text().strip()
        if room_name:
            arguments += ["--name", room_name]
        self._run_room_action(arguments, "Pokój utworzony", open_browser=True)

    def _join(self, code: str) -> None:
        name = self._display_name.get_text().strip()
        if not name:
            self._on_toast("Podaj swoją nazwę w rankingu")
            return
        wanted = code.strip().upper()
        if not wanted:
            self._on_toast("Podaj kod pokoju")
            return
        self._run_room_action(
            ["join", wanted, "--server", self._server, "--as", name], f"Dołączono do {wanted}"
        )

    def _leave(self) -> None:
        self._run_room_action(["leave"], "Wyszedłeś z pokoju")

    def _run_room_action(
        self, arguments: list[str], message: str, *, open_browser: bool = False
    ) -> None:
        """Run a room command, then restart the daemon so it takes effect.

        The restart is not optional and not the user's business: the daemon
        reads its configuration once, at startup, so without it joining a room
        would silently do nothing.
        """
        if self._busy:
            return
        self._busy = True
        self._status.set_label("Chwila…")

        def worker() -> None:
            try:
                services.run_room_command(arguments)
                services.run_systemctl("restart")
            except RuntimeError as exc:
                GLib.idle_add(self._finish_action, False, str(exc), False)
                return
            GLib.idle_add(self._finish_action, True, message, open_browser)

        threading.Thread(target=worker, name="room-action", daemon=True).start()

    def _finish_action(self, ok: bool, message: str, open_browser: bool) -> bool:
        self._busy = False
        self._on_toast(message)
        self._status.set_label("" if ok else message)
        # Akcja przepisała config.yaml, więc przeładowujemy go w całości —
        # sam stan z pliku by nie wystarczył, bo demon dopiero wstaje.
        self.refresh()
        if ok and open_browser:
            GLib.timeout_add_seconds(1, self._open_link_once)
        return False

    def _open_link_once(self) -> bool:
        self._open_link()
        return False

    def _start_session(self) -> None:
        name = self._new_session_name.get_text().strip()
        server, code = self._server, self._code

        def worker() -> None:
            try:
                start_session(server, code, name)
            except RoomDataError as exc:
                GLib.idle_add(self._on_toast, str(exc))
                return
            GLib.idle_add(self._after_session_change, "Nowa sesja ruszyła")

        threading.Thread(target=worker, name="room-session", daemon=True).start()

    def _end_session(self) -> None:
        server, code = self._server, self._code

        def worker() -> None:
            try:
                end_session(server, code)
            except RoomDataError as exc:
                GLib.idle_add(self._on_toast, str(exc))
                return
            GLib.idle_add(self._after_session_change, "Sesja zakończona")

        threading.Thread(target=worker, name="room-session", daemon=True).start()

    def _after_session_change(self, message: str) -> bool:
        self._new_session_name.set_text("")
        self._on_toast(message)
        self._poll_now()
        return False

    def _copy_link(self) -> None:
        try:
            services.copy_to_clipboard(self._link())
        except RuntimeError as exc:
            self._on_toast(str(exc))
            return
        self._on_toast("Link skopiowany")

    def _open_link(self) -> None:
        launcher = Gtk.UriLauncher(uri=self._link())
        launcher.launch(self.get_root(), None, None, None)

    def _on_advertise_toggled(self, switch: Gtk.Switch, _param) -> None:
        self._advertise = switch.get_active()
        self._sync_advertisement()

    # -- rysowanie ----------------------------------------------------------

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
                host=self._display_name.get_text().strip(),
            )
        else:
            self._advertiser.withdraw()

    def _render(self) -> None:
        inside = self._in_room()
        self._inside.set_visible(inside)
        self._outside.set_visible(not inside)
        if inside:
            self._render_room_header()
            self._render_speaker()
            self._render_session()
            self._render_board()
        else:
            self._render_nearby()

    def _render_room_header(self) -> None:
        name = str(self._room().get("name") or "")
        self._room_title.set_label(f"{name} · {self._code}" if name else self._code)
        self._room_link.set_label(self._link())

    def _render_speaker(self) -> None:
        if self._state.speaking_here:
            self._now_dot.add_css_class("recording-dot")
            self._now_title.set_label("Mówisz Ty")
            self._now_subtitle.set_label("Reszta pokoju czeka, aż skończysz")
        elif self._state.speaking:
            self._now_dot.add_css_class("recording-dot")
            self._now_title.set_label(f"{self._state.speaking} dyktuje")
            self._now_subtitle.set_label(
                "Twój skrót nie zacznie nagrywać — dwa mikrofony naraz psują obie transkrypcje"
            )
        else:
            self._now_dot.remove_css_class("recording-dot")
            self._now_title.set_label("Cisza")
            if self._state.connected:
                message = "Nikt teraz nie dyktuje"
            elif self._state.code:
                message = "Brak połączenia z serwerem pokoi — dyktowanie działa lokalnie"
            else:
                # Demon jeszcze nic nie zgłosił. To NIE to samo co zerwane łącze;
                # twierdzenie o braku połączenia byłoby zmyśleniem.
                message = "Demon nie zgłosił jeszcze stanu pokoju — zrestartuj voiceflow"
            self._now_subtitle.set_label(message)

    def _render_session(self) -> None:
        session = self._document.get("session")
        if not isinstance(session, dict):
            self._session_name.set_label("Brak otwartej sesji")
            self._session_clock.set_label("—")
            return
        self._session_name.set_label(str(session.get("name") or "Sesja bez nazwy"))
        self._session_clock.set_label(session_elapsed(str(session.get("started_at") or "")))

    def _render_board(self) -> None:
        while child := self._board_holder.get_first_child():
            self._board_holder.remove(child)
        ranking = self._document.get("ranking")
        rows = board_rows(ranking if isinstance(ranking, list) else [])
        if not rows:
            self._board_holder.append(
                empty_state(
                    "system-users-symbolic",
                    "Jeszcze nikt nic nie podyktował w tej sesji. Pierwsze słowo bierze prowadzenie.",
                )
            )
            return
        for row in rows:
            self._board_holder.append(self._board_row(row))

    def _board_row(self, row) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_16)
        card.add_css_class("card")
        card.add_css_class("content-card")

        position = label(f"{row.position:02d}", "stat-value")
        position.set_valign(Gtk.Align.CENTER)
        card.append(position)

        middle = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
        middle.set_hexpand(True)
        name = label(row.name, "card-title")
        if row.name == self._state.speaking:
            name.add_css_class("recording-dot")
        middle.append(name)
        share = Gtk.ProgressBar(fraction=row.share / 100)
        share.add_css_class("room-share")
        middle.append(share)
        detail = (f"{row.dictations} dyktowań · średnio {row.average_words} "
                  f"{words_word(row.average_words)} · {row.share}% sesji")
        if row.behind:
            detail = f"{detail} · brakuje {row.behind}"
        middle.append(label(detail, "section-hint"))
        card.append(middle)

        words = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
        words.set_valign(Gtk.Align.CENTER)
        words.append(label(str(row.words), "stat-value"))
        words.append(label("SŁÓW", "stat-label"))
        card.append(words)

        spoken = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
        spoken.set_valign(Gtk.Align.CENTER)
        spoken.append(label(format_duration(row.seconds), "stat-value"))
        spoken.append(label("MÓWIENIA", "stat-label"))
        card.append(spoken)
        return card

    def _render_nearby(self) -> bool:
        while child := self._nearby_holder.get_first_child():
            self._nearby_holder.remove(child)
        rooms = visible_rooms(self._discovered, self._code)
        if not rooms:
            self._nearby_holder.append(
                empty_state(
                    "network-wireless-symbolic",
                    "Nikt w tej sieci nie rozgłasza pokoju. Utwórz własny albo wpisz kod.",
                )
            )
            return False
        for room in rooms:
            card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=style.SPACE_12)
            card.add_css_class("card")
            card.add_css_class("content-card")
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_4)
            text.set_hexpand(True)
            text.append(label(room.title, "card-title"))
            text.append(label(room.subtitle, "section-hint"))
            card.append(text)
            button = Gtk.Button(label="Dołącz")
            button.add_css_class("primary-button")
            button.set_valign(Gtk.Align.CENTER)
            button.connect("clicked", lambda _b, code=room.code: self._join(code))
            card.append(button)
            self._nearby_holder.append(card)
        return False
