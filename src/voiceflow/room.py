"""Client side of a shared dictation room.

Holds no audio and no text. It publishes two facts — "I started speaking" and
"I finished, N words in M seconds" — and consumes one: who, if anyone, is
speaking right now. Everything the daemon does with that knowledge (refusing to
start, quietening the speakers) is code that already existed.

The transport is injected, so every rule below is testable without a network.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from typing import Any, Protocol

from voiceflow.config import RoomConfig

LOGGER = logging.getLogger(__name__)


class Transport(Protocol):
    """Whatever carries messages to the room service."""

    def send(self, payload: dict[str, Any]) -> None: ...
    def on_message(self, callback: Callable[[dict[str, Any]], None]) -> None: ...


class RoomClient:
    """Tracks who is speaking in the room and gates the local hotkey."""

    def __init__(
        self,
        config: RoomConfig,
        *,
        on_remote_speaking: Callable[[str], None],
        on_remote_silence: Callable[[], None],
        transport: Transport | None = None,
    ) -> None:
        self.config = config
        self._on_remote_speaking = on_remote_speaking
        self._on_remote_silence = on_remote_silence
        self._transport = transport
        #: Name of whoever is speaking elsewhere, or None when the room is quiet.
        self._remote_speaker: str | None = None
        #: True once we quietened this machine for somebody else, so the restore
        #: happens exactly once — a second duck would remember the already-ducked
        #: level as the original one and leave this machine permanently quiet.
        self._ducked = False
        if transport is not None:
            transport.on_message(self._handle)

    @property
    def active(self) -> bool:
        return self.config.enabled and bool(self.config.code)

    def may_start(self) -> tuple[bool, str | None]:
        """Whether the local hotkey may begin recording, and who blocks it."""
        if not self.config.enabled:
            return True, None
        if self._remote_speaker is None:
            return True, None
        return False, self._remote_speaker

    def report_started(self) -> None:
        self._send({"type": "speaking_started"})

    def report_finished(self, *, words: int, seconds: float) -> None:
        self._send({"type": "speaking_ended", "words": words, "seconds": seconds})

    def report_cancelled(self) -> None:
        """Speaking ended with nothing to report — release the room now.

        Cancelling, or a recording that turned out to be silence, used to send
        nothing at all: the room went on showing this person as the speaker and
        kept everybody else blocked until the heartbeat expired ten seconds
        later. Zero words is how the server knows not to write a row for it.
        """
        self._send({"type": "speaking_ended", "words": 0, "seconds": 0})

    def heartbeat(self) -> None:
        self._send({"type": "heartbeat"})

    def on_disconnected(self) -> None:
        """Server unreachable: forget the room rather than hold its lock.

        A room we cannot see is a room we cannot be blocked by. Losing the
        network must never take dictation away — that is the whole tool. The
        volume this machine lowered for somebody else is restored on the way
        out, because nobody else is going to tell us to.
        """
        self._set_remote_speaker(None)
        LOGGER.info("Pokój niedostępny; dyktowanie działa lokalnie")

    # -- plumbing ----------------------------------------------------------

    def _send(self, payload: dict[str, Any]) -> None:
        if not self.config.enabled or self._transport is None:
            return
        try:
            self._transport.send(payload)
        except Exception:
            # Zgłaszanie do pokoju jest best-effort: dyktowanie już się odbyło
            # lokalnie i jego wynik jest u użytkownika niezależnie od tego, czy
            # statystyka doleciała.
            LOGGER.warning("Nie udało się wysłać zdarzenia pokoju", exc_info=True)

    def _handle(self, payload: dict[str, Any]) -> None:
        kind = payload.get("type")
        if kind == "speaking_denied":
            self._set_remote_speaker(payload.get("blockedBy"))
            return
        if kind not in ("speaker_changed", "room_state"):
            return
        speaking = payload.get("speaking")
        name = speaking.get("name") if isinstance(speaking, dict) else None
        self._set_remote_speaker(name)

    def _set_remote_speaker(self, name: str | None) -> None:
        if name == self._remote_speaker:
            return
        self._remote_speaker = name
        if name is None:
            if self._ducked:
                self._ducked = False
                self._on_remote_silence()
            return
        if self.config.duck_for_others and not self._ducked:
            self._ducked = True
            self._on_remote_speaking(name)
