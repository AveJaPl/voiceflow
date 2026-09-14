"""Rules for finding dictation rooms on the local network.

Two people sitting at one desk should not retype a six-character code, so a
machine that is in a room advertises it over mDNS and the other machine offers
it as a button. Outside that network — and outside this window — the code and
the link still work; discovery is a shortcut on top of them, never the only way in.

This module holds only the rules, so they can be tested without a bus. The
Avahi side lives in `avahi.py`, the same split the daemon uses between
`room.py` and `roomlink.py`.

The advertised record carries the room code and nothing else that matters —
never the device token, which is a secret and stays in `config.yaml`.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass

SERVICE_TYPE = "_voiceflow._tcp"


@dataclass(frozen=True)
class DiscoveredRoom:
    """A room somebody nearby is advertising."""

    code: str
    #: Nazwa pokoju, jeśli ją nadano.
    name: str
    #: Czyja to maszyna — do pokazania „Salon · Filip".
    host: str

    @property
    def title(self) -> str:
        return self.name or f"Pokój {self.code}"

    @property
    def subtitle(self) -> str:
        return f"{self.host} · {self.code}" if self.host else self.code


# Avahi podaje TXT jako tablice bajtów, nie napisy, więc obie strony tej
# zamiany trzymamy tutaj i testujemy bez magistrali.


def encode_txt(fields: Mapping[str, str]) -> list[list[int]]:
    """Render `key=value` pairs the way Avahi's `aay` argument expects them."""
    return [list(f"{key}={value}".encode("utf-8")) for key, value in fields.items()]


def decode_txt(records: Iterable[Iterable[int]] | None) -> dict[str, str]:
    """Read Avahi's byte arrays back into a mapping, skipping anything odd."""
    fields: dict[str, str] = {}
    for record in records or []:
        try:
            text = bytes(bytearray(record)).decode("utf-8")
        except (TypeError, ValueError, UnicodeDecodeError):
            continue  # obcy rekord w sieci nie może wywrócić listy
        key, separator, value = text.partition("=")
        if separator and key:
            fields[key] = value
    return fields


def room_from_txt(fields: Mapping[str, str]) -> DiscoveredRoom | None:
    """Build a room from a TXT mapping, or None when it is not one of ours.

    A record without a code cannot be joined, so it is not a room — offering it
    would put a button on screen that leads nowhere.
    """
    code = (fields.get("code") or "").strip().upper()
    if not code:
        return None
    return DiscoveredRoom(
        code=code,
        name=(fields.get("room") or "").strip(),
        host=(fields.get("host") or "").strip(),
    )


def visible_rooms(found: Iterable[DiscoveredRoom], own_code: str = "") -> list[DiscoveredRoom]:
    """Drop our own room and collapse duplicates, keeping a stable order.

    The same room arrives once per network interface — wired and wireless on
    one machine is the ordinary case — and offering it twice looks like two
    rooms. Our own room is dropped because "join" would be a no-op.
    """
    mine = (own_code or "").strip().upper()
    seen: set[str] = set()
    rooms: list[DiscoveredRoom] = []
    for room in found:
        if room.code == mine or room.code in seen:
            continue
        seen.add(room.code)
        rooms.append(room)
    return rooms
