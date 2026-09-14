"""Local mirror of the room's live state, written for the desktop app.

The daemon holds the room WebSocket, so it is the only process that knows who
is speaking right now. The application is a separate process in a separate
Python environment and cannot import anything from here — so the two talk
through a small file, exactly as the daemon already talks to the GNOME Shell
extension through ``stats.json``.

Deliberately not carried here: the room name (the app reads it from the ranking
endpoint, which is authoritative) and the device token (a secret that never
leaves ``config.yaml``).
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path

from voiceflow.paths import room_state_file

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class RoomState:
    """What the application needs to draw the room screen without the network."""

    #: Six-character room code, empty when not in a room.
    code: str = ""
    #: Whether the daemon currently has a live link to the room service.
    connected: bool = False
    #: Who is speaking ELSEWHERE, or None. The server never echoes a speaker to
    #: themselves, so this is always somebody else.
    speaking: str | None = None
    #: Whether this machine is the one dictating. Kept apart from `speaking`
    #: because the daemon knows it is recording but not under what name it is
    #: listed in the ranking — the display name belongs to the device
    #: registration, not to the room configuration.
    speaking_here: bool = False

    def as_document(self) -> dict[str, object]:
        return {
            "code": self.code,
            "connected": self.connected,
            "speaking": self.speaking,
            "speaking_here": self.speaking_here,
        }


def write_room_state(state: RoomState, path: Path | None = None) -> None:
    """Replace the room state file atomically.

    Atomic because the application may read at any moment and a half-written
    file would give it truncated JSON. Failures are logged, never raised —
    losing this file must not disturb dictation, which is the whole tool.
    """
    target = path or room_state_file()
    tmp = target.with_suffix(".json.tmp")
    try:
        tmp.write_text(json.dumps(state.as_document(), ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, target)
    except OSError as exc:
        LOGGER.warning("Nie można zapisać stanu pokoju do %s: %s", target, exc)
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def read_room_state(path: Path | None = None) -> RoomState:
    """Return the stored state, or an empty one when it is missing or broken.

    A missing file is the normal state of a machine that never joined a room,
    and a truncated one is what a reader gets if it loses the race with a
    writer on a system without atomic replace. Neither is worth an exception.
    """
    target = path or room_state_file()
    try:
        document = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return RoomState()
    if not isinstance(document, dict):
        return RoomState()
    speaking = document.get("speaking")
    return RoomState(
        code=str(document.get("code") or ""),
        connected=bool(document.get("connected")),
        speaking=str(speaking) if isinstance(speaking, str) and speaking else None,
        speaking_here=bool(document.get("speaking_here")),
    )


def clear_room_state(path: Path | None = None) -> None:
    """Remove the file when leaving a room, so no stale room lingers on screen."""
    target = path or room_state_file()
    try:
        target.unlink(missing_ok=True)
    except OSError as exc:
        LOGGER.warning("Nie można usunąć stanu pokoju %s: %s", target, exc)
