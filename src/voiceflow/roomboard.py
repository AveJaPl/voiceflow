"""Numbers behind the room board, kept apart from the widgets that draw them.

Everything here is either a pure calculation or a bounded HTTP read, so the
board can be tested without a window, a network or a daemon — the same split
``statlib`` already uses.

This is the package-side twin of ``app/voiceflow_app/roomdata.py``. The GTK
application cannot import it: it runs on the system Python, in a different
environment from the daemon. The Qt window ships *inside* the package, so it
imports this module instead of carrying a third copy. Keep the two in step —
they are what makes the two boards show the same numbers.

The live room state (who is speaking) is not re-read here; that already lives
in :mod:`voiceflow.roomstate`, which the daemon writes.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

#: How long we wait for the room service. Called from a worker thread, but the
#: window has no reason to wait longer — no answer is shown as no connection.
REQUEST_TIMEOUT_SECONDS = 6.0

#: How many past sessions we fetch at once. The chronicle can be long and only
#: a dozen rows fit on screen; the rest waits behind a button.
HISTORY_PAGE = 20

DEFAULT_SERVER = "wss://rooms.pbdevs.com"


class RoomDataError(RuntimeError):
    """The room service could not be reached or answered with nonsense."""


@dataclass(frozen=True)
class BoardRow:
    """One line of the ranking, ready to render."""

    position: int
    name: str
    words: int
    seconds: int
    dictations: int
    average_words: int
    #: Share of the whole session's words, 0–100.
    share: int
    #: How many words behind the leader; the leader has zero.
    behind: int


def board_rows(
    ranking: Sequence[Mapping[str, Any]],
    members: Sequence[Mapping[str, Any]] = (),
) -> list[BoardRow]:
    """Turn the ranking payload into rows carrying share and distance.

    Share and distance are computed here rather than in the widget because they
    are the two numbers that make the board competitive, and a wrong one is a
    lie that looks like a fact.

    Everybody who joined the room gets a line, including whoever has not said
    anything yet. The ranking only counts people with dictations, so somebody
    who has just walked in was simply absent from the board — which reads as
    "you are not in this room" rather than "you have not started". They sort
    last, on nought words, which is exactly what they have.
    """
    entries = _with_silent_members(ranking, members)
    rows: list[BoardRow] = []
    total = sum(int(entry.get("words") or 0) for entry in entries)
    leader = int(entries[0].get("words") or 0) if entries else 0
    for position, entry in enumerate(entries, start=1):
        words = int(entry.get("words") or 0)
        rows.append(
            BoardRow(
                position=position,
                name=str(entry.get("name") or "—"),
                words=words,
                seconds=int(entry.get("seconds") or 0),
                dictations=int(entry.get("dictations") or 0),
                average_words=int(entry.get("averageWords") or 0),
                share=round(words * 100 / total) if total else 0,
                behind=max(0, leader - words),
            )
        )
    return rows


def _with_silent_members(
    ranking: Sequence[Mapping[str, Any]],
    members: Sequence[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    """Append room members the ranking does not mention, on nought words.

    Matched by device id, because two people in one room may share a first
    name and matching on that would silently merge them into one line.
    """
    entries = list(ranking)
    known = {str(entry.get("deviceId") or "") for entry in entries}
    known.discard("")
    for member in members:
        device = str(member.get("id") or member.get("deviceId") or "")
        name = str(member.get("name") or "").strip()
        if not name or (device and device in known):
            continue
        known.add(device)
        entries.append(
            {"deviceId": device, "name": name, "words": 0, "seconds": 0,
             "dictations": 0, "averageWords": 0}
        )
    return entries


def format_duration(seconds: float) -> str:
    """Render a speaking time the way the web board does, to the minute."""
    minutes = max(0, round(seconds / 60))
    hours, rest = divmod(minutes, 60)
    if hours and rest:
        return f"{hours} godz. {rest} min"
    if hours:
        return f"{hours} godz."
    return f"{minutes} min"


def session_elapsed(started_at: str, now: datetime | None = None) -> str:
    """Render how long the session has been running, as HH:MM:SS.

    Returns an em dash for anything unparseable: a session whose start we
    cannot read is better shown as unknown than as zero.
    """
    moment = _parse_timestamp(started_at)
    if moment is None:
        return "—"
    current = now or datetime.now(timezone.utc)
    total = int(max(0.0, (current - moment).total_seconds()))
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def session_span(started_at: str, ended_at: str | None, now: datetime | None = None) -> str:
    """How long a session ran — or has been running, when it is still open."""
    start = _parse_timestamp(started_at)
    if start is None:
        return "—"
    end = _parse_timestamp(ended_at or "") or (now or datetime.now(timezone.utc))
    return format_duration(max(0.0, (end - start).total_seconds()))


def _parse_timestamp(value: str) -> datetime | None:
    text = (value or "").strip()
    if not text:
        return None
    # Postgres hands back "…Z", which fromisoformat refused until 3.11 — the
    # swap to an explicit offset works both ways and costs no dependency.
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


# -- Polish plurals ----------------------------------------------------------


def plural(count: int, one: str, few: str, many: str) -> str:
    """Polish plural by number.

    Without this the interface says "0 osoby" and "1 sesjach" — the kind of
    detail that gives away that nobody read the screen out loud. The ``many``
    branch also covers 12–14, which take it despite ending in 2–4.
    """
    number = abs(int(count))
    if number == 1:
        return one
    rest, teens = number % 10, number % 100
    return few if 2 <= rest <= 4 and not 12 <= teens <= 14 else many


def sessions_word(count: int) -> str:
    return plural(count, "sesja", "sesje", "sesji")


def people_word(count: int) -> str:
    return plural(count, "osoba", "osoby", "osób")


def words_word(count: int) -> str:
    return plural(count, "słowo", "słowa", "słów")


# -- addresses ---------------------------------------------------------------


def http_base(server: str) -> str:
    """Turn a ``wss://`` room server into the ``https://`` base REST uses."""
    base = (server or "").strip().rstrip("/")
    if base.startswith("wss://"):
        base = f"https://{base[len('wss://'):]}"
    elif base.startswith("ws://"):
        base = f"http://{base[len('ws://'):]}"
    if not base.startswith(("http://", "https://")):
        raise RoomDataError("Adres serwera pokoi jest nieprawidłowy")
    return base


def room_url(server: str, code: str) -> str:
    """The address of the shared board — the link handed to a tablet or a TV."""
    return f"{http_base(server)}/room/{code.upper()}"


# -- the network -------------------------------------------------------------


def fetch_ranking(server: str, code: str) -> dict[str, Any]:
    """Fetch the live board. Call from a worker thread, never from the UI one."""
    url = f"{http_base(server)}/api/rooms/{code.upper()}/ranking"
    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            document = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise RoomDataError(f"Nie ma pokoju o kodzie {code.upper()}") from exc
        raise RoomDataError(f"Serwer pokoi odpowiedział {exc.code}") from exc
    except (OSError, ValueError) as exc:
        raise RoomDataError("Brak połączenia z serwerem pokoi") from exc
    if not isinstance(document, dict):
        raise RoomDataError("Serwer pokoi zwrócił nieoczekiwaną odpowiedź")
    return document


def fetch_history(server: str, code: str, offset: int = 0) -> dict[str, Any]:
    """Fetch one page of past sessions plus all-time totals. Worker thread only."""
    url = (
        f"{http_base(server)}/api/rooms/{code.upper()}/history"
        f"?limit={HISTORY_PAGE}&offset={max(0, offset)}"
    )
    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            document = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        raise RoomDataError("Nie udało się pobrać historii pokoju") from exc
    return document if isinstance(document, dict) else {}


def start_session(server: str, code: str, name: str) -> None:
    """Open a fresh named session, closing whatever was running."""
    _post(f"{http_base(server)}/api/rooms/{code.upper()}/session", {"name": name.strip()})


def end_session(server: str, code: str) -> None:
    """Close the running session; the room stays alive for the next one."""
    _post(f"{http_base(server)}/api/rooms/{code.upper()}/session/end", {})


def _post(url: str, payload: Mapping[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(dict(payload)).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise RoomDataError(f"Serwer pokoi odpowiedział {exc.code}") from exc
    except OSError as exc:
        raise RoomDataError("Brak połączenia z serwerem pokoi") from exc
    try:
        document = json.loads(body)
    except ValueError as exc:
        raise RoomDataError("Serwer pokoi zwrócił nieoczekiwaną odpowiedź") from exc
    return document if isinstance(document, dict) else {}
