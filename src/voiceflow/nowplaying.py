"""What is playing right now, read from MPRIS.

Used by the room: when several people work together, seeing the track somebody
put on is part of being in the same space. The value travels over the existing
room WebSocket and is **never stored** — there is no table for it, on purpose.
Closing a session leaves no record of what anybody listened to, which is the
same rule that keeps `dictations` free of a text column.

Reads through `busctl --json=short`, which returns real JSON. The obvious
alternative, `gdbus`, prints GVariant text that would have to be parsed by hand.
Neither is a new dependency: both ship with systemd and glib.

Everything that decides is a pure function, so the rules below are tested
without a bus.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any

LOGGER = logging.getLogger(__name__)

MPRIS_PREFIX = "org.mpris.MediaPlayer2"
_OBJECT = "/org/mpris/MediaPlayer2"
_PLAYER_INTERFACE = f"{MPRIS_PREFIX}.Player"
#: Krótko: to jest ozdoba, która nigdy nie może opóźnić dyktowania.
_TIMEOUT = 1.5


@dataclass(frozen=True)
class Track:
    """One playing track, as much of it as MPRIS gave us."""

    title: str
    artist: str
    #: Nazwa aplikacji („Spotify"), nie nazwa magistrali.
    player: str
    #: Publiczny adres okładki z CDN wydawcy; pusty, gdy odtwarzacz go nie podał.
    art_url: str = ""

    def as_payload(self) -> dict[str, str]:
        return {
            "title": self.title,
            "artist": self.artist,
            "player": self.player,
            "artUrl": self.art_url,
        }


@dataclass(frozen=True)
class Candidate:
    """A player we could show, before the choice between them is made."""

    bus_name: str
    status: str
    title: str
    artist: str
    player: str
    art_url: str

    @property
    def playing(self) -> bool:
        return self.status == "Playing" and bool(self.title)


def choose(candidates: list[Candidate]) -> Track | None:
    """Pick the one player worth showing, or None.

    There is usually more than one candidate on the bus: a Bluetooth speaker
    exposes MPRIS over AVRCP next to the real application. The rule, in order:

    1. it must be playing and have a title — anything else is not "what is on";
    2. among those, the one that publishes cover art wins, because real
       applications do and AVRCP proxies usually do not;
    3. still tied — first by bus name, so the choice is repeatable and can be
       written down in a test.

    Checked against Filip's machine: `org.mpris.MediaPlayer2.JBL_Clip_5…` sits
    next to Spotify, exposes no metadata at all and reports `Stopped`, so it
    falls out at step 1.
    """
    playing = [candidate for candidate in candidates if candidate.playing]
    if not playing:
        return None
    with_art = [candidate for candidate in playing if candidate.art_url]
    best = sorted(with_art or playing, key=lambda candidate: candidate.bus_name)[0]
    return Track(
        title=best.title, artist=best.artist, player=best.player, art_url=best.art_url
    )


def candidate_from(bus_name: str, metadata: Any, status: Any, identity: Any) -> Candidate:
    """Build a candidate from three raw MPRIS property reads."""
    fields = metadata if isinstance(metadata, dict) else {}
    return Candidate(
        bus_name=bus_name,
        status=str(status or ""),
        title=_text(fields.get("xesam:title")),
        artist=_first_text(fields.get("xesam:artist")),
        player=str(identity or "") or bus_name.removeprefix(f"{MPRIS_PREFIX}."),
        art_url=_text(fields.get("mpris:artUrl")),
    )


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _first_text(value: Any) -> str:
    """MPRIS lists artists; a track with three of them still needs one line."""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list) and value:
        return ", ".join(str(item).strip() for item in value if str(item).strip())
    return ""


def unwrap(document: Any) -> Any:
    """Strip busctl's ``{"type": …, "data": …}`` wrappers, however deep.

    busctl reports the D-Bus type alongside every value. Only the values matter
    here, and dragging the types through the rest of the module would put the
    shape of one command line into every function that touches a track.
    """
    if isinstance(document, dict):
        if set(document) == {"type", "data"}:
            return unwrap(document["data"])
        return {key: unwrap(value) for key, value in document.items()}
    if isinstance(document, list):
        return [unwrap(item) for item in document]
    return document


# -- odczyt z magistrali ----------------------------------------------------


def _run(arguments: list[str]) -> str | None:
    try:
        result = subprocess.run(
            arguments, check=False, capture_output=True, text=True, timeout=_TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def _property(busctl: str, bus_name: str, interface: str, name: str) -> Any:
    raw = _run([busctl, "--user", "get-property", bus_name, _OBJECT, interface, name,
                "--json=short"])
    if not raw:
        return None
    try:
        return unwrap(json.loads(raw))
    except ValueError:
        return None


def players(busctl: str) -> list[str]:
    """Bus names of everything currently claiming to be a media player."""
    raw = _run([busctl, "--user", "list", "--no-pager", "--acquired"])
    if not raw:
        return []
    names = []
    for line in raw.splitlines():
        name = line.split(" ", 1)[0].strip()
        if name.startswith(f"{MPRIS_PREFIX}."):
            names.append(name)
    return names


def current_track() -> Track | None:
    """What is playing on this machine right now, or None.

    Never raises and never blocks for long: a missing `busctl`, a player that
    stopped answering, a malformed reply — all of them mean "no tile", not an
    error. This runs alongside dictation and must never be able to disturb it.
    """
    busctl = shutil.which("busctl")
    if busctl is None:
        return None
    candidates = []
    for bus_name in players(busctl):
        status = _property(busctl, bus_name, _PLAYER_INTERFACE, "PlaybackStatus")
        if status != "Playing":
            continue  # nie pytamy o resztę, gdy i tak odpadnie
        candidates.append(
            candidate_from(
                bus_name,
                _property(busctl, bus_name, _PLAYER_INTERFACE, "Metadata"),
                status,
                _property(busctl, bus_name, MPRIS_PREFIX, "Identity"),
            )
        )
    return choose(candidates)
