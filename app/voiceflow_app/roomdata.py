"""Numbers behind the room board, kept apart from the widgets that draw them.

Everything here is either a pure calculation or a bounded read, so the board can
be tested without a window, a network or a daemon — the same split that
`statlib` and `shortcuts` already use in this application.

Note the duplication with `voiceflow.roomstate` on the daemon side: the two
processes run in *different Python environments* and cannot import each other,
so a four-field document is re-read here rather than shared. Copying the reader
is cheaper than bridging the environments.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

#: Ile czekamy na usługę pokoi. Wołane z wątku roboczego, ale okno i tak nie ma
#: po co czekać dłużej — brak odpowiedzi pokazujemy jako brak łączności.
REQUEST_TIMEOUT_SECONDS = 6.0


class RoomDataError(RuntimeError):
    """The room service could not be reached or answered with nonsense."""


@dataclass(frozen=True)
class RoomState:
    """Mirror of the daemon's `room.json`."""

    code: str = ""
    connected: bool = False
    speaking: str | None = None
    speaking_here: bool = False

    @property
    def in_room(self) -> bool:
        return bool(self.code)


@dataclass(frozen=True)
class BoardRow:
    """One line of the ranking, ready to render."""

    position: int
    name: str
    words: int
    seconds: int
    dictations: int
    average_words: int
    #: Udział w słowach całej sesji, 0–100.
    share: int
    #: Ile słów brakuje do lidera; lider ma zero.
    behind: int


def read_room_state(path: Path) -> RoomState:
    """Return the daemon's room state, or an empty one when unavailable.

    A missing file is the normal state of a machine that never joined a room.
    A broken one is what a reader gets on a lost race with the writer. Neither
    deserves an exception on the way to drawing a window.
    """
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
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


def board_rows(ranking: Sequence[Mapping[str, Any]]) -> list[BoardRow]:
    """Turn the ranking payload into rows carrying share and distance.

    Share and distance are computed here rather than in the widget because they
    are the two numbers that make the board competitive, and a wrong one is a
    lie that looks like a fact.
    """
    rows: list[BoardRow] = []
    total = sum(int(entry.get("words") or 0) for entry in ranking)
    leader = int(ranking[0].get("words") or 0) if ranking else 0
    for position, entry in enumerate(ranking, start=1):
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


def _parse_timestamp(value: str) -> datetime | None:
    text = (value or "").strip()
    if not text:
        return None
    # Postgres oddaje "…Z", którego `fromisoformat` nie przyjmował aż do 3.11 —
    # zamiana na offset działa w obie strony i nie kosztuje zależności.
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def http_base(server: str) -> str:
    """Turn a `wss://` room server into the `https://` base the REST API uses."""
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


#: Ile sesji dociągamy naraz. Kronika bywa długa, a na ekran i tak wchodzi
#: kilkanaście wierszy — reszta czeka za przyciskiem.
HISTORY_PAGE = 20


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


def plural(count: int, one: str, few: str, many: str) -> str:
    """Polish plural by number.

    Without this the interface says "0 osoby" and "1 sesjach" — the kind of
    detail that gives away that nobody read the screen out loud. The `many`
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


def session_span(started_at: str, ended_at: str | None, now: datetime | None = None) -> str:
    """How long a session ran — or has been running, when it is still open."""
    start = _parse_timestamp(started_at)
    if start is None:
        return "—"
    end = _parse_timestamp(ended_at or "") or (now or datetime.now(timezone.utc))
    return format_duration(max(0.0, (end - start).total_seconds()))


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
