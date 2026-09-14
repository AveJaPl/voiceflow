"""mDNS transport for room discovery — the part that touches the network.

Kept apart from :mod:`voiceflow.roomdiscovery` for the same reason
``roomlink.py`` is kept apart from ``room.py``: there live the rules, testable
without a network, and here everything that can break because of the outside
world.

Linux does this through Avahi over D-Bus. Windows has no Avahi, and its own
DNS-SD API is not reachable from Python, so this speaks the same protocol with
``python-zeroconf``. The wire format is identical, which is the point: a room
advertised from a Linux laptop shows up in this window, and vice versa.

A missing or broken zeroconf is not an error to show. It is an empty list,
because the room code and the link keep working without it.
"""

from __future__ import annotations

import logging
import socket
from collections.abc import Callable

from voiceflow.roomdiscovery import (
    PORT,
    ZEROCONF_TYPE,
    DiscoveredRoom,
    decode_txt,
    room_from_txt,
    txt_fields,
)

LOGGER = logging.getLogger(__name__)


def _zeroconf_module():
    """Import zeroconf lazily; absence is a disabled feature, not a crash."""
    try:
        import zeroconf  # noqa: PLC0415 - optional dependency, imported on use
    except ImportError as exc:
        LOGGER.info("Brak pakietu zeroconf; wykrywanie w sieci wyłączone: %s", exc)
        return None
    return zeroconf


def _local_address() -> bytes | None:
    """The address to advertise. Best effort — the record works without it."""
    try:
        return socket.inet_aton(socket.gethostbyname(socket.gethostname()))
    except OSError:
        return None


class RoomAdvertiser:
    """Publishes this machine's room for as long as the window is open."""

    def __init__(self) -> None:
        self._zeroconf = None
        self._info = None
        self._published: tuple[str, str, str] | None = None

    def publish(self, *, code: str, name: str, host: str) -> None:
        """Advertise a room, replacing whatever was advertised before.

        Re-publishing an unchanged record would tear the announcement down and
        put it back several times a minute — the page calls this on every state
        change — so an identical request is a no-op.
        """
        if not code:
            self.withdraw()
            return
        wanted = (code.upper(), name, host)
        if wanted == self._published:
            return
        self.withdraw()

        module = _zeroconf_module()
        if module is None:
            return
        address = _local_address()
        try:
            self._zeroconf = module.Zeroconf()
            self._info = module.ServiceInfo(
                ZEROCONF_TYPE,
                f"voiceflow {code.upper()}.{ZEROCONF_TYPE}",
                addresses=[address] if address else [],
                port=PORT,
                properties=txt_fields(code, name, host),
                server=f"{socket.gethostname()}.local.",
            )
            self._zeroconf.register_service(self._info, allow_name_change=True)
        except Exception as error:  # noqa: BLE001 - the network is best effort
            LOGGER.info("Nie udało się rozgłosić pokoju: %s", error)
            self._close()
            return
        self._published = wanted

    def withdraw(self) -> None:
        """Stop advertising — on leaving a room, or on closing the window."""
        if self._zeroconf is not None and self._info is not None:
            try:
                self._zeroconf.unregister_service(self._info)
            except Exception as error:  # noqa: BLE001
                LOGGER.debug("Nie udało się zdjąć rozgłoszenia: %s", error)
        self._close()

    def _close(self) -> None:
        if self._zeroconf is not None:
            try:
                self._zeroconf.close()
            except Exception as error:  # noqa: BLE001
                LOGGER.debug("Nie udało się zamknąć zeroconf: %s", error)
        self._zeroconf = None
        self._info = None
        self._published = None


class RoomBrowser:
    """Watches the network and reports which rooms are advertised right now."""

    def __init__(self, on_change: Callable[[list[DiscoveredRoom]], None]) -> None:
        self._on_change = on_change
        self._zeroconf = None
        self._browser = None
        #: Keyed by the service name, which is how the protocol identifies an
        #: entry when it goes away; one machine announces once per interface.
        self._rooms: dict[str, DiscoveredRoom] = {}

    def start(self) -> None:
        if self._browser is not None:
            return
        module = _zeroconf_module()
        if module is None:
            return
        try:
            self._zeroconf = module.Zeroconf()
            self._browser = module.ServiceBrowser(
                self._zeroconf, ZEROCONF_TYPE, handlers=[self._on_service_state_change]
            )
        except Exception as error:  # noqa: BLE001
            LOGGER.info("Nie udało się rozpocząć przeglądania sieci: %s", error)
            self.stop()

    def stop(self) -> None:
        if self._browser is not None:
            try:
                self._browser.cancel()
            except Exception as error:  # noqa: BLE001
                LOGGER.debug("Nie udało się zamknąć przeglądania: %s", error)
        if self._zeroconf is not None:
            try:
                self._zeroconf.close()
            except Exception as error:  # noqa: BLE001
                LOGGER.debug("Nie udało się zamknąć zeroconf: %s", error)
        self._browser = None
        self._zeroconf = None
        self._rooms.clear()

    def rooms(self) -> list[DiscoveredRoom]:
        return list(self._rooms.values())

    def _on_service_state_change(self, zeroconf, service_type, name, state_change) -> None:
        """Runs on a zeroconf thread; the callback hops to the UI thread itself."""
        changed = False
        if getattr(state_change, "name", str(state_change)) == "Removed":
            changed = self._rooms.pop(name, None) is not None
        else:
            try:
                info = zeroconf.get_service_info(service_type, name, timeout=2000)
            except Exception as error:  # noqa: BLE001
                LOGGER.debug("Nie udało się rozwiązać usługi %s: %s", name, error)
                return
            if info is None:
                return
            room = room_from_txt(decode_txt(info.properties))
            if room is None:
                return
            changed = self._rooms.get(name) != room
            self._rooms[name] = room
        if changed:
            self._on_change(self.rooms())
