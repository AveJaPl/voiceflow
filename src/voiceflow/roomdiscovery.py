"""Rules for finding dictation rooms on the local network.

Two people sitting at one desk should not retype a six-character code, so a
machine that is in a room advertises it over mDNS and the other machine offers
it as a button. Outside that network — and outside this window — the code and
the link still work; discovery is a shortcut on top of them, never the only way
in.

This module holds only the rules, so they can be tested without a network. The
transport lives in :mod:`voiceflow.winplat.mdns` on Windows and in
``app/voiceflow_app/avahi.py`` on Linux — different libraries, one wire format,
so a Windows machine and a Linux machine see each other's rooms.

The advertised record carries the room code and nothing else that matters —
never the device token, which is a secret and stays in ``config.yaml``.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any

#: What Avahi is told. Its DNS-SD name adds the domain, below.
SERVICE_TYPE = "_voiceflow._tcp"
#: What python-zeroconf wants: the same service, spelled with its domain.
ZEROCONF_TYPE = f"{SERVICE_TYPE}.local."
#: The port is mandatory in the record but nobody connects to it — the
#: conversation goes through the room service, not across the LAN. Zero says so.
PORT = 0


@dataclass(frozen=True)
class DiscoveredRoom:
    """A room somebody nearby is advertising."""

    code: str
    #: The room's name, when it was given one.
    name: str
    #: Whose machine it is — so the card can read "Salon · Filip".
    host: str

    @property
    def title(self) -> str:
        return self.name or f"Pokój {self.code}"

    @property
    def subtitle(self) -> str:
        return f"{self.host} · {self.code}" if self.host else self.code


def txt_fields(code: str, name: str, host: str) -> dict[str, str]:
    """The advertised record. One place, so both platforms publish the same keys."""
    return {"code": code.upper(), "room": name, "host": host}


def decode_txt(records: Mapping[Any, Any] | Iterable[Iterable[int]] | None) -> dict[str, str]:
    """Read a TXT record into a mapping, skipping anything odd.

    Accepts both shapes the two transports produce: zeroconf's already-parsed
    ``{key: value}`` mapping of bytes, and Avahi's raw ``key=value`` byte
    arrays. A foreign record on the network must not be able to break the list.
    """
    fields: dict[str, str] = {}
    if records is None:
        return fields
    if isinstance(records, Mapping):
        for raw_key, raw_value in records.items():
            key = _text(raw_key)
            if key:
                fields[key] = _text(raw_value)
        return fields
    for record in records:
        try:
            text = bytes(bytearray(record)).decode("utf-8")
        except (TypeError, ValueError, UnicodeDecodeError):
            continue
        key, separator, value = text.partition("=")
        if separator and key:
            fields[key] = value
    return fields


def _text(value: object) -> str:
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8")
        except UnicodeDecodeError:
            return ""
    return str(value) if value is not None else ""


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
