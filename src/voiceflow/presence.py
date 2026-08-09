"""Discord Rich Presence: show friends that the user is dictating.

While a dictation is recorded the user goes silent on the call; without a cue
people think the connection dropped. Discord's Rich Presence displays an
activity ("voiceflow — dyktuje głosem" with a timer) next to the user's name,
set over a **local** IPC socket — no network, no account automation. Sending
chat messages on the user's behalf would be a ToS-violating self-bot and is
deliberately not implemented.

The protocol is small enough to speak directly (no pypresence dependency):
length-prefixed JSON frames over a unix socket — opcode 0 handshake, opcode 1
commands. Requires a client_id from a (free) application registered at
discord.com/developers; that id determines the activity name shown.

Everything here is fire-and-forget from a worker thread: presence must never
delay the hotkey, and a missing/closed Discord is a debug log, not an error.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import struct
import threading
import time
from pathlib import Path

from voiceflow.config import PresenceConfig

LOGGER = logging.getLogger(__name__)

_OP_HANDSHAKE = 0
_OP_FRAME = 1
_TIMEOUT = 1.0


def _encode(opcode: int, payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return struct.pack("<II", opcode, len(body)) + body


def _socket_candidates() -> list[Path]:
    """Discord's IPC endpoints per platform.

    Linux: unix sockets in the runtime dir (plus snap/flatpak subdirs).
    Windows: named pipes (backslash-backslash-dot) pipe discord-ipc-N.
    """
    if os.name == "nt":
        return [Path(rf"\\.\pipe\discord-ipc-{index}") for index in range(10)]
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    bases = [runtime, runtime / "snap.discord", runtime / "app" / "com.discordapp.Discord"]
    return [base / f"discord-ipc-{index}" for base in bases for index in range(10)]


class _PipeTransport:
    """File-object adapter giving a named pipe the socket sendall/recv shape."""

    def __init__(self, path: Path) -> None:
        # Buffering must be off: frames are small and must flush immediately.
        self._handle = open(path, "r+b", buffering=0)  # noqa: SIM115

    def sendall(self, data: bytes) -> None:
        self._handle.write(data)

    def recv(self, count: int) -> bytes:
        return self._handle.read(count) or b""

    def settimeout(self, _value: float) -> None:  # parity with socket API
        return

    def close(self) -> None:
        self._handle.close()


class DiscordPresence:
    """Best-effort activity updates over Discord's local IPC socket."""

    def __init__(self, config: PresenceConfig) -> None:
        self.config = config
        self._socket: socket.socket | None = None
        self._lock = threading.Lock()

    @property
    def available(self) -> bool:
        """Enabled and configured; the socket is probed lazily on first use."""
        return self.config.enabled and bool(self.config.client_id)

    def dictating(self) -> None:
        """Announce the dictation activity. Never blocks the caller."""
        if not self.available:
            return
        started = int(time.time())
        threading.Thread(
            target=self._set_activity,
            args=(
                {
                    "details": "Dyktuje głosem",
                    "timestamps": {"start": started},
                },
            ),
            name="voiceflow-presence",
            daemon=True,
        ).start()

    def clear(self) -> None:
        """Remove the activity. Never blocks the caller."""
        if not self.available:
            return
        threading.Thread(
            target=self._set_activity, args=(None,), name="voiceflow-presence", daemon=True
        ).start()

    # -- plumbing ----------------------------------------------------------

    def _set_activity(self, activity: dict | None) -> None:
        with self._lock:
            try:
                connection = self._ensure_connection()
                if connection is None:
                    return
                payload = {
                    "cmd": "SET_ACTIVITY",
                    "args": {"pid": os.getpid(), "activity": activity},
                    "nonce": str(time.monotonic()),
                }
                connection.sendall(_encode(_OP_FRAME, payload))
                self._read_frame(connection)
            except OSError as exc:
                LOGGER.debug("Discord presence niedostępne: %s", exc)
                self._drop_connection()

    def _ensure_connection(self) -> socket.socket | None:
        if self._socket is not None:
            return self._socket
        for candidate in _socket_candidates():
            if os.name != "nt" and not candidate.exists():
                continue
            try:
                if os.name == "nt":
                    connection = _PipeTransport(candidate)
                else:
                    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    connection.settimeout(_TIMEOUT)
                    connection.connect(str(candidate))
                connection.sendall(
                    _encode(_OP_HANDSHAKE, {"v": 1, "client_id": self.config.client_id})
                )
                self._read_frame(connection)
                self._socket = connection
                LOGGER.info("Połączono z Discord Rich Presence (%s)", candidate.name)
                return connection
            except OSError as exc:
                LOGGER.debug("Socket %s odrzucił połączenie: %s", candidate, exc)
        return None

    def _read_frame(self, connection: socket.socket) -> None:
        header = self._read_exact(connection, 8)
        _opcode, length = struct.unpack("<II", header)
        # Discord caps frames well below this; the bound guards a garbage length.
        if length > 1 << 20:
            raise OSError(f"nieprawidłowa długość ramki: {length}")
        self._read_exact(connection, length)

    @staticmethod
    def _read_exact(connection: socket.socket, count: int) -> bytes:
        chunks = b""
        while len(chunks) < count:
            chunk = connection.recv(count - len(chunks))
            if not chunk:
                raise OSError("Discord zamknął połączenie")
            chunks += chunk
        return chunks

    def _drop_connection(self) -> None:
        if self._socket is not None:
            try:
                self._socket.close()
            except OSError:
                pass
            self._socket = None
