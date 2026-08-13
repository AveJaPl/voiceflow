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
from voiceflow.roomstate import RoomState

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
        on_state_changed: Callable[[RoomState], None] | None = None,
    ) -> None:
        self.config = config
        self._on_remote_speaking = on_remote_speaking
        self._on_remote_silence = on_remote_silence
        self._transport = transport
        #: Publishes state for the desktop app. Injected rather than called
        #: directly so the rules below stay testable without touching a disk.
        self._on_state_changed = on_state_changed
        #: Whether THIS machine is dictating. The server never echoes a speaker
        #: to themselves, so `_remote_speaker` can never carry this.
        self._speaking_here = False
        #: Set by any message arriving from the service — a link that talks to
        #: us is a link that works, and there is no separate "connected" event.
        self._connected = False
        #: Ostatnio rozgłoszony utwór, żeby nie powtarzać tego samego.
        self._now_playing: dict[str, str] | None = None
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
        self._speaking_here = True
        self._publish_state()
        self._send({"type": "speaking_started"})

    def report_finished(self, *, words: int, seconds: float) -> None:
        self._speaking_here = False
        self._publish_state()
        self._send({"type": "speaking_ended", "words": words, "seconds": seconds})

    def report_cancelled(self) -> None:
        """Speaking ended with nothing to report — release the room now.

        Cancelling, or a recording that turned out to be silence, used to send
        nothing at all: the room went on showing this person as the speaker and
        kept everybody else blocked until the heartbeat expired ten seconds
        later. Zero words is how the server knows not to write a row for it.
        """
        self._speaking_here = False
        self._publish_state()
        self._send({"type": "speaking_ended", "words": 0, "seconds": 0})

    def report_now_playing(self, track: dict[str, str] | None) -> None:
        """Publish what is playing here, but only when it actually changed.

        The room shows it live and the server forgets it immediately — there is
        no table for this. Sending on every poll would be a message a second for
        a value that changes once per song.
        """
        if track == self._now_playing:
            return
        self._now_playing = track
        self._send({"type": "now_playing", "track": track})

    def heartbeat(self) -> None:
        self._send({"type": "heartbeat"})

    def on_disconnected(self) -> None:
        """Server unreachable: forget the room rather than hold its lock.

        A room we cannot see is a room we cannot be blocked by. Losing the
        network must never take dictation away — that is the whole tool. The
        volume this machine lowered for somebody else is restored on the way
        out, because nobody else is going to tell us to.
        """
        self._connected = False
        # Serwer trzyma kafelek tylko w pamięci procesu i zapomniał go razem
        # z połączeniem; bez tego po powrocie nie wysłalibyśmy go ponownie.
        self._now_playing = None
        self._set_remote_speaker(None)
        self._publish_state()
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

    def _publish_state(self) -> None:
        """Mirror the current state to disk for the desktop application."""
        if self._on_state_changed is None:
            return
        try:
            self._on_state_changed(
                RoomState(
                    code=self.config.code,
                    connected=self._connected,
                    speaking=self._remote_speaker,
                    speaking_here=self._speaking_here,
                )
            )
        except Exception:
            # Rysowanie cudzego okna nie może przewrócić dyktowania.
            LOGGER.warning("Nie udało się zapisać stanu pokoju", exc_info=True)

    def _handle(self, payload: dict[str, Any]) -> None:
        # Cokolwiek przyszło kanałem, znaczy że kanał działa. Osobnego zdarzenia
        # "połączono" protokół nie ma, a aplikacja musi odróżnić ciszę w pokoju
        # od zerwanego łącza.
        if not self._connected:
            self._connected = True
            self._publish_state()
            # Zerwanie łącza kasuje mówiącego po stronie serwera (rozłączenie =
            # wyjście z pokoju), a my w tym czasie mówimy dalej. Bez tego
            # przypomnienia tablica gasła w połowie dyktowania i pokazywała
            # ciszę, choć mikrofon pracował — a przy łączu rwącym się co kilka
            # minut trafiało to w każde dłuższe dyktowanie.
            if self._speaking_here:
                self._send({"type": "speaking_started"})
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
        self._publish_state()
        if name is None:
            if self._ducked:
                self._ducked = False
                self._on_remote_silence()
            return
        if self.config.duck_for_others and not self._ducked:
            self._ducked = True
            self._on_remote_speaking(name)
