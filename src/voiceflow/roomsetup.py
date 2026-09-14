"""Joining a room from the command line.

Registering a device and joining a room is a handful of HTTP calls followed by
four lines written into ``config.yaml``. Doing it by hand with curl works and
nobody would; this module is what makes the feature reachable.

Writes only the four keys it owns and leaves the rest of the file — including
every comment — exactly as it found it.
"""

from __future__ import annotations

import json
import logging
import platform
import urllib.error
import urllib.request
from pathlib import Path

import yaml

from voiceflow.paths import config_dir

LOGGER = logging.getLogger(__name__)
_TIMEOUT = 10.0


class RoomSetupError(RuntimeError):
    """Joining failed in a way the user has to know about."""


def _post(url: str, payload: dict) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RoomSetupError(f"serwer odpowiedział {exc.code}: {detail}") from exc
    except OSError as exc:
        raise RoomSetupError(f"nie można połączyć się z {url}: {exc}") from exc


def _http_base(server: str) -> str:
    """wss://host -> https://host, bo REST i WebSocket dzielą ten sam adres."""
    base = server.rstrip("/")
    if base.startswith("wss://"):
        return "https://" + base[len("wss://"):]
    if base.startswith("ws://"):
        return "http://" + base[len("ws://"):]
    return base


def ensure_device(server: str, name: str, token: str = "") -> str:
    """Return a device token, registering this machine if it has none yet."""
    if token:
        return token
    result = _post(
        f"{_http_base(server)}/api/devices",
        {"name": name, "platform": platform.system().lower()},
    )
    device_token = result.get("token")
    if not device_token:
        raise RoomSetupError("serwer nie zwrócił tokenu urządzenia")
    return str(device_token)


def create_room(server: str, name: str, display_name: str, token: str = "") -> dict:
    device_token = ensure_device(server, display_name, token)
    room = _post(f"{_http_base(server)}/api/rooms", {"name": name})
    code = room.get("code")
    if not code:
        raise RoomSetupError("serwer nie zwrócił kodu pokoju")
    _post(f"{_http_base(server)}/api/rooms/{code}/join", {"token": device_token})
    return {"code": code, "token": device_token, "name": room.get("name")}


def join_room(server: str, code: str, display_name: str, token: str = "") -> dict:
    device_token = ensure_device(server, display_name, token)
    result = _post(
        f"{_http_base(server)}/api/rooms/{code.upper()}/join", {"token": device_token}
    )
    return {"code": code.upper(), "token": device_token, "name": result.get("room", {}).get("name")}


def leave_room(server: str, code: str, token: str, path: Path | None = None) -> Path:
    """Switch the room off while keeping the code and token for a quick return.

    Written once and called from both the command line and the desktop window:
    the flag lives inside the spliced-in text block, so flipping it by rewriting
    the parsed document would throw the block's comments away.
    """
    target = save_to_config(server, code, token, path)
    text = target.read_text(encoding="utf-8").replace(
        "  enabled: true\n  server:", "  enabled: false\n  server:"
    )
    target.write_text(text, encoding="utf-8")
    return target


def save_to_config(server: str, code: str, token: str, path: Path | None = None) -> Path:
    """Write the four room keys, preserving everything else in the file.

    ``config.yaml`` is a hand-written, commented document. Rewriting it whole
    from a parsed dict — which is what the obvious implementation does — throws
    every comment away, so the section is spliced in as text instead.
    """
    target = path or config_dir() / "config.yaml"
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    existing = target.read_text(encoding="utf-8") if target.exists() else ""

    block = (
        "room:\n"
        "  # Wspólny pokój dyktowania. Jedyna część voiceflow, która cokolwiek\n"
        "  # wysyła poza tę maszynę — i wyłącznie zdarzenia obecności oraz liczby\n"
        "  # (słowa, sekundy). Nagranie i tekst nie wychodzą nigdy.\n"
        "  enabled: true\n"
        f"  server: {server}\n"
        f"  code: {code}\n"
        f"  token: {token}\n"
        "  # Czy czyjeś dyktowanie może ściszyć dźwięk na TYM urządzeniu.\n"
        "  duck_for_others: true\n"
    )

    lines = existing.splitlines(keepends=True)
    kept: list[str] = []
    inside_room = False
    for line in lines:
        if line.startswith("room:"):
            inside_room = True
            continue
        if inside_room:
            # Sekcja kończy się na pierwszej linii bez wcięcia.
            if line.strip() and not line.startswith((" ", "\t", "#")):
                inside_room = False
            else:
                continue
        kept.append(line)

    body = "".join(kept)
    if body and not body.endswith("\n"):
        body += "\n"
    target.write_text(body + block, encoding="utf-8")
    target.chmod(0o600)

    # Plik musi się nadal parsować — token wpisany bez cudzysłowów potrafi
    # wyglądać jak coś innego niż tekst.
    try:
        yaml.safe_load(target.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise RoomSetupError(f"zapisana konfiguracja nie jest poprawnym YAML: {exc}") from exc
    return target
