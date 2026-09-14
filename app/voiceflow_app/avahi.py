"""Avahi transport for room discovery — the part that touches the bus.

Kept apart from `discovery.py` for the same reason `roomlink.py` is kept apart
from `room.py` on the daemon side: there live the rules, testable without a
network, and here everything that can break because of the outside world.

Speaks to `org.freedesktop.Avahi` over D-Bus through `Gio`, which the
application already depends on — no `python-zeroconf`, no new package. The
daemon could not do this: its environment has no `gi`, which is why a room is
only visible on the network while this window is open.

A missing or broken Avahi is not an error to show. It is an empty list, because
the room code and the link keep working without it.
"""

from __future__ import annotations

import logging
from collections.abc import Callable

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib  # noqa: E402

from voiceflow_app.discovery import (
    SERVICE_TYPE,
    DiscoveredRoom,
    decode_txt,
    encode_txt,
    room_from_txt,
)

LOGGER = logging.getLogger(__name__)

_AVAHI = "org.freedesktop.Avahi"
#: Avahi: „dowolny interfejs" i „dowolny protokół".
_IF_UNSPEC = -1
_PROTO_UNSPEC = -1
_TIMEOUT_MS = 3000
#: Port jest w rekordzie obowiązkowy, ale nikt się na niego nie łączy — rozmowa
#: idzie przez usługę pokoi, nie po sieci lokalnej. Zero mówi to wprost.
_PORT = 0
#: Pozycja rekordu TXT w odpowiedzi `ResolveService`.
_TXT_INDEX = 9


def _system_bus() -> Gio.DBusConnection | None:
    try:
        return Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    except GLib.Error as error:
        LOGGER.info("Brak magistrali systemowej; wykrywanie w sieci wyłączone: %s", error)
        return None


class RoomAdvertiser:
    """Publishes this machine's room for as long as the window is open."""

    def __init__(self) -> None:
        self._bus = _system_bus()
        self._group_path: str | None = None

    def publish(self, *, code: str, name: str, host: str) -> None:
        """Advertise a room, replacing whatever was advertised before."""
        self.withdraw()
        if self._bus is None or not code:
            return
        txt = encode_txt({"code": code.upper(), "room": name, "host": host})
        try:
            reply = self._bus.call_sync(
                _AVAHI, "/", f"{_AVAHI}.Server", "EntryGroupNew",
                None, GLib.VariantType.new("(o)"), Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
            group_path = reply.unpack()[0]
            self._bus.call_sync(
                _AVAHI, group_path, f"{_AVAHI}.EntryGroup", "AddService",
                GLib.Variant(
                    "(iiussssqaay)",
                    (
                        _IF_UNSPEC, _PROTO_UNSPEC, 0,
                        f"voiceflow {code.upper()}", SERVICE_TYPE, "", "", _PORT, txt,
                    ),
                ),
                None, Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
            self._bus.call_sync(
                _AVAHI, group_path, f"{_AVAHI}.EntryGroup", "Commit",
                None, None, Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
        except GLib.Error as error:
            LOGGER.info("Nie udało się rozgłosić pokoju: %s", error)
            return
        self._group_path = group_path

    def withdraw(self) -> None:
        """Stop advertising — on leaving a room, or on closing the window."""
        if self._bus is None or self._group_path is None:
            return
        try:
            self._bus.call_sync(
                _AVAHI, self._group_path, f"{_AVAHI}.EntryGroup", "Free",
                None, None, Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
        except GLib.Error as error:
            LOGGER.debug("Nie udało się zdjąć rozgłoszenia: %s", error)
        self._group_path = None


class RoomBrowser:
    """Watches the network and reports which rooms are advertised right now."""

    def __init__(self, on_change: Callable[[list[DiscoveredRoom]], None]) -> None:
        self._on_change = on_change
        self._bus = _system_bus()
        self._browser_path: str | None = None
        self._subscription: int | None = None
        #: Klucz to (nazwa usługi, domena) — tym Avahi identyfikuje wpis przy
        #: usuwaniu, a jedna maszyna zgłasza go raz na interfejs sieciowy.
        self._rooms: dict[tuple[str, str], DiscoveredRoom] = {}

    def start(self) -> None:
        if self._bus is None or self._browser_path is not None:
            return
        try:
            reply = self._bus.call_sync(
                _AVAHI, "/", f"{_AVAHI}.Server", "ServiceBrowserNew",
                GLib.Variant("(iissu)", (_IF_UNSPEC, _PROTO_UNSPEC, SERVICE_TYPE, "", 0)),
                GLib.VariantType.new("(o)"), Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
        except GLib.Error as error:
            LOGGER.info("Nie udało się rozpocząć przeglądania sieci: %s", error)
            return
        self._browser_path = reply.unpack()[0]
        self._subscription = self._bus.signal_subscribe(
            _AVAHI, f"{_AVAHI}.ServiceBrowser", None, self._browser_path, None,
            Gio.DBusSignalFlags.NONE, self._on_signal,
        )

    def stop(self) -> None:
        if self._bus is None:
            return
        if self._subscription is not None:
            self._bus.signal_unsubscribe(self._subscription)
            self._subscription = None
        if self._browser_path is not None:
            try:
                self._bus.call_sync(
                    _AVAHI, self._browser_path, f"{_AVAHI}.ServiceBrowser", "Free",
                    None, None, Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
                )
            except GLib.Error as error:
                LOGGER.debug("Nie udało się zamknąć przeglądania: %s", error)
            self._browser_path = None
        self._rooms.clear()

    def rooms(self) -> list[DiscoveredRoom]:
        return list(self._rooms.values())

    def _on_signal(self, _bus, _sender, _path, _interface, signal, parameters) -> None:
        values = parameters.unpack()
        if signal == "ItemNew":
            self._resolve(*values[:5])
        elif signal == "ItemRemove":
            self._rooms.pop((values[2], values[4]), None)
            self._on_change(self.rooms())

    def _resolve(self, interface: int, protocol: int, name: str, service: str, domain: str) -> None:
        """Ask Avahi for the TXT record behind an announcement."""
        if self._bus is None:
            return
        try:
            reply = self._bus.call_sync(
                _AVAHI, "/", f"{_AVAHI}.Server", "ResolveService",
                GLib.Variant(
                    "(iisssiu)", (interface, protocol, name, service, domain, _PROTO_UNSPEC, 0)
                ),
                None, Gio.DBusCallFlags.NONE, _TIMEOUT_MS, None,
            )
        except GLib.Error as error:
            LOGGER.debug("Nie udało się rozwiązać usługi %s: %s", name, error)
            return
        room = room_from_txt(decode_txt(reply.unpack()[_TXT_INDEX]))
        if room is None:
            return
        self._rooms[(name, domain)] = room
        self._on_change(self.rooms())
