"""The wire under :class:`voiceflow.room.RoomClient`.

Kept apart from ``room.py`` on purpose: every rule about who may speak lives
there and is tested without a network, while everything that can fail because
of a cable lives here. This module reconnects, sends a heartbeat, and hands
decoded messages upwards — it decides nothing.

Failure is not an error state. When the room service is unreachable the daemon
must keep dictating exactly as it did before rooms existed, so every path in
here ends in "tell the client we are offline and try again later".
"""

from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable
from typing import Any

from voiceflow.config import RoomConfig

LOGGER = logging.getLogger(__name__)

#: Matches the server: a speaker who stops pulsing for 10 s is treated as done.
HEARTBEAT_SECONDS = 3.0
#: Backoff between reconnection attempts, seconds. Grows, then stops growing —
#: a room that comes back after an hour should be rejoined within the minute.
RECONNECT_DELAYS = (1, 2, 5, 10, 30, 60)


class WebSocketTransport:
    """Keeps a connection to the room service and pumps messages both ways."""

    def __init__(
        self,
        config: RoomConfig,
        *,
        on_disconnected: Callable[[], None] | None = None,
    ) -> None:
        self.config = config
        self._on_message: Callable[[dict[str, Any]], None] | None = None
        self._on_disconnected = on_disconnected
        self._socket: Any = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- Transport protocol -------------------------------------------------

    def on_message(self, callback: Callable[[dict[str, Any]], None]) -> None:
        self._on_message = callback

    def send(self, payload: dict[str, Any]) -> None:
        with self._lock:
            socket = self._socket
        if socket is None:
            return
        socket.send(json.dumps(payload))

    # -- lifecycle ----------------------------------------------------------

    def start(self) -> None:
        """Begin connecting in the background. Never blocks the caller."""
        if not (self.config.enabled and self.config.server and self.config.code):
            return
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="voiceflow-room", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._lock:
            socket, self._socket = self._socket, None
        if socket is not None:
            try:
                socket.close()
            except Exception:
                pass

    # -- plumbing -----------------------------------------------------------

    def _url(self) -> str:
        base = self.config.server.rstrip("/")
        return f"{base}/ws?room={self.config.code}&token={self.config.token}"

    def _run(self) -> None:
        try:
            from websockets.sync.client import connect
        except ImportError:
            LOGGER.warning(
                "Pakiet websockets nie jest zainstalowany — pokój pozostaje wyłączony"
            )
            return

        attempt = 0
        while not self._stop.is_set():
            try:
                with connect(
                    self._url(),
                    open_timeout=5,
                    # Własny puls idzie co 3 s (patrz `_pump`), więc pingi
                    # biblioteki są tu drugim, nadmiarowym mechanizmem. Zostają
                    # dla wykrycia martwego gniazda, ale z hojnym oknem: przy
                    # domyślnych 20 s połączenie ginęło, gdy proces akurat
                    # mielił transkrypcję i pong nie zdążył wrócić na czas.
                    ping_interval=20,
                    ping_timeout=60,
                ) as socket:
                    with self._lock:
                        self._socket = socket
                    attempt = 0
                    LOGGER.info("Połączono z pokojem %s", self.config.code)
                    self._pump(socket)
            except Exception as exc:
                LOGGER.info("Pokój niedostępny: %s", exc)
            finally:
                with self._lock:
                    self._socket = None
                if self._on_disconnected is not None:
                    # Bez tego blokada nałożona przez cudze dyktowanie zostałaby
                    # z nami po zerwaniu łącza — a wtedy awaria sieci odbiera
                    # użytkownikowi podstawową funkcję narzędzia.
                    self._on_disconnected()
            if self._stop.is_set():
                return
            delay = RECONNECT_DELAYS[min(attempt, len(RECONNECT_DELAYS) - 1)]
            attempt += 1
            self._stop.wait(delay)

    def _pump(self, socket: Any) -> None:
        """Read messages until the socket dies, pulsing while we wait."""
        while not self._stop.is_set():
            try:
                raw = socket.recv(timeout=HEARTBEAT_SECONDS)
            except TimeoutError:
                socket.send(json.dumps({"type": "heartbeat"}))
                continue
            if raw is None:
                return
            try:
                message = json.loads(raw)
            except (TypeError, ValueError):
                continue  # śmieć w kanale nie zrywa połączenia
            if isinstance(message, dict) and self._on_message is not None:
                self._on_message(message)
