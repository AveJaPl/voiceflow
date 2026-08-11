"""System integration for the standalone GTK application.

This module deliberately does not import ``src/voiceflow``.  The desktop app
runs on the system Python so it can use PyGObject, while the daemon lives in its
own uv environment.
"""

from __future__ import annotations

import copy
import json
from dataclasses import dataclass
import os
import shutil
import socket
import subprocess
import tempfile
from collections.abc import Mapping, Sequence
from datetime import datetime
from pathlib import Path
from typing import Any, TypedDict

import yaml


CONFIG_HEADER = "# voiceflow configuration (edited by the desktop app; reference: README)\n"
SOCKET_TIMEOUT_SECONDS = 0.35

MODELS: tuple[tuple[str, str], ...] = (
    ("tiny", "~75 MB"),
    ("base", "~145 MB"),
    ("small", "~466 MB"),
    ("medium", "~1.5 GB"),
    ("large-v2", "~3.1 GB"),
    ("large-v3", "~3.1 GB"),
    ("large-v3-turbo", "~1.6 GB"),
    ("distil-large-v3", "~1.5 GB"),
)
DEVICES = ("cuda", "cpu", "auto")

# Keep these defaults synchronized manually with src/voiceflow/config.py.
DEFAULT_CONFIG: dict[str, Any] = {
    "model": {
        "name": "large-v3-turbo",
        "device": "cuda",
        "compute_type": "float16",
        "language": "pl",
        "beam_size": 5,
        "vocabulary": [],
    },
    "audio": {"source": None, "max_seconds": 300},
    "inject": {
        "method": "clipboard",
        "key_delay_ms": 12,
        "paste_key": "ctrl+shift+v",
        "restore_clipboard": True,
    },
    "preview": {
        "enabled": True,
        "interval_seconds": 1.0,
        "window_seconds": 30.0,
        "max_chars": 330,
    },
    "mute_apps": {
        "enabled": True,
        "apps": ["WEBRTC VoiceEngine"],
        "duck_enabled": True,
        "duck_to": 0.6,
        "duck_rules": {},
    },
    "presence": {"enabled": False, "client_id": ""},
    "history": {"enabled": True, "store_text": True, "max_entries": 20000},
    "overlay": {"enabled": True},
    "notifications": {"enabled": True},
    "log_level": "INFO",
}


class HistoryRecord(TypedDict, total=False):
    """Validated fields from one JSONL history line."""

    timestamp: str
    words: int
    chars: int
    audio_seconds: float
    transcription_seconds: float
    injected: bool
    text: str | None


def config_path() -> Path:
    """Return the XDG configuration file used by the daemon."""
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "voiceflow" / "config.yaml"


def history_path() -> Path:
    """Return the local JSONL history file without importing the daemon."""
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "voiceflow" / "history.jsonl"


def room_state_path() -> Path:
    """Return the live room state the daemon writes for this application.

    The daemon runs in a different Python environment, so who-is-speaking
    travels through a file rather than a call — same arrangement as the history
    above.
    """
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "voiceflow" / "room.json"


def voiceflow_cli() -> str:
    """Locate the daemon's command-line entry point.

    The application cannot import the `voiceflow` package — separate
    environments — so room actions are performed by running the very binary the
    systemd unit runs. Preferring the explicit path matters because a desktop
    launcher does not necessarily inherit a shell's PATH.
    """
    explicit = Path.home() / ".local" / "bin" / "voiceflow"
    if explicit.exists():
        return str(explicit)
    found = shutil.which("voiceflow")
    if found:
        return found
    raise RuntimeError(
        "Nie znaleziono polecenia voiceflow. Zainstaluj demona albo dodaj ~/.local/bin do PATH."
    )


def run_room_command(arguments: Sequence[str]) -> str:
    """Run `voiceflow room …` and return its output, or raise a readable error."""
    try:
        result = subprocess.run(
            [voiceflow_cli(), "room", *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Serwer pokoi nie odpowiedział na czas") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(detail or f"voiceflow room zakończyło się kodem {result.returncode}")
    return result.stdout.strip()


def daemon_socket_path() -> Path:
    """Return the daemon socket path without importing the project package."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = Path(runtime) if runtime else Path("/run/user") / str(os.getuid())
    return base / "voiceflow" / "daemon.sock"


def app_icon_path() -> Path:
    """Return the SVG source shared with the desktop launcher."""
    return Path(__file__).resolve().parent.parent / "io.github.avejapl.voiceflow.svg"


def send_request(command: str, timeout: float = SOCKET_TIMEOUT_SECONDS) -> dict[str, Any]:
    """Send one newline-delimited JSON request to the local daemon."""
    payload = json.dumps({"command": command}, ensure_ascii=False).encode("utf-8") + b"\n"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    raw = b""
    try:
        client.connect(str(daemon_socket_path()))
        client.sendall(payload)
        with client.makefile("rb") as response_file:
            raw = response_file.readline(65537)
    except OSError as exc:
        raise RuntimeError(f"Demon voiceflow nie odpowiada: {exc}") from exc
    finally:
        client.close()
    if not raw or len(raw) > 65536:
        raise RuntimeError("Demon zwrócił pustą lub zbyt dużą odpowiedź")
    try:
        response = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Demon zwrócił nieprawidłową odpowiedź: {exc}") from exc
    if not isinstance(response, dict):
        raise RuntimeError("Demon zwrócił odpowiedź innego typu niż obiekt JSON")
    return response


def load_raw_config(path: Path | None = None) -> dict[str, Any]:
    """Load a YAML mapping, returning defaults when the file does not exist."""
    target = path or config_path()
    if not target.exists():
        return copy.deepcopy(DEFAULT_CONFIG)
    try:
        loaded = yaml.safe_load(target.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise RuntimeError(f"Nie można wczytać pliku {target}: {exc}") from exc
    if loaded is None:
        return {}
    if not isinstance(loaded, Mapping):
        raise RuntimeError(f"Główny element pliku {target} nie jest mapą YAML")
    return copy.deepcopy(dict(loaded))


def section(data: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    """Return a mapping section or an empty mapping for invalid input."""
    value = data.get(name, {})
    return value if isinstance(value, Mapping) else {}


def string_value(data: Mapping[str, Any], key: str, default: str) -> str:
    """Read a non-empty string with a fallback."""
    value = data.get(key, default)
    return value if isinstance(value, str) and value else default


def bool_value(data: Mapping[str, Any], key: str, default: bool) -> bool:
    """Read a boolean with a fallback."""
    value = data.get(key, default)
    return value if isinstance(value, bool) else default


def string_list_value(data: Mapping[str, Any], key: str, default: list[str]) -> list[str]:
    """Read the string-list shape accepted by voiceflow's parser."""
    if key not in data:
        return list(default)
    value = data.get(key, default)
    if isinstance(value, str):
        stripped = value.strip()
        return [stripped] if stripped else []
    if not isinstance(value, (list, tuple)):
        return []
    return [item.strip() for item in value if isinstance(item, str) and item.strip()]


def float_value(data: Mapping[str, Any], key: str, default: float) -> float:
    """Read a non-negative float with a fallback."""
    value = data.get(key, default)
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0:
        return float(value)
    return default


def float_mapping_value(data: Mapping[str, Any], key: str) -> dict[str, float]:
    """Read an application-to-volume mapping accepted by the daemon."""
    value = data.get(key, {})
    if not isinstance(value, Mapping):
        return {}
    result: dict[str, float] = {}
    for raw_name, raw_volume in value.items():
        if not isinstance(raw_name, str) or not raw_name.strip():
            continue
        if (
            isinstance(raw_volume, (int, float))
            and not isinstance(raw_volume, bool)
            and 0.0 <= float(raw_volume) <= 1.0
        ):
            result[raw_name.strip()] = float(raw_volume)
    return result


#: PipeWire infrastructure clients that are not user applications.
_INFRA_PREFIXES = ("wireplumber", "pipewire", "libcanberra", "gnome-shell", "xdg-desktop")


@dataclass(frozen=True, slots=True)
class AudioApplication:
    """One application known to the audio system.

    ``playing`` — has an active playback stream right now.
    ``connected`` — has a live PipeWire client (running, possibly paused).
    ``captures`` — has an active microphone capture stream.
    An app that is none of these can still appear in the UI as a remembered rule.
    """

    name: str
    playing: bool = False
    connected: bool = False
    captures: bool = False


def discover_audio_applications() -> list[AudioApplication]:
    """Union of three pw-dump views: clients, playback streams, capture streams.

    Playback streams alone are not enough: Spotify on pause closes its stream
    and would look "inactive" while it is plainly running — the client entry is
    what keeps it visible.
    """
    try:
        result = subprocess.run(
            ["pw-dump"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("Nie znaleziono polecenia pw-dump") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Przekroczono czas odświeżania aplikacji audio") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(detail or f"pw-dump zakończył się kodem {result.returncode}")
    try:
        nodes = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("pw-dump zwrócił nieprawidłowy JSON") from exc
    if not isinstance(nodes, list):
        raise RuntimeError("pw-dump zwrócił nieoczekiwany format danych")
    return _merge_audio_objects(nodes)


def _merge_audio_objects(objects: list) -> list[AudioApplication]:
    """Pure merge step, separated so it is testable without pw-dump."""
    playing: set[str] = set()
    connected: set[str] = set()
    captures: set[str] = set()
    for entry in objects:
        if not isinstance(entry, Mapping):
            continue
        info = entry.get("info")
        props = info.get("props") if isinstance(info, Mapping) else None
        if not isinstance(props, Mapping):
            continue
        raw_name = props.get("application.name")
        if not isinstance(raw_name, str) or not raw_name.strip():
            continue
        name = raw_name.strip()
        if name.casefold().startswith(_INFRA_PREFIXES):
            continue
        kind = entry.get("type")
        media = props.get("media.class")
        if kind == "PipeWire:Interface:Client":
            connected.add(name)
        elif media == "Stream/Output/Audio":
            playing.add(name)
            connected.add(name)
        elif media == "Stream/Input/Audio":
            captures.add(name)
            connected.add(name)
    return sorted(
        (
            AudioApplication(
                name=name,
                playing=name in playing,
                connected=True,
                captures=name in captures,
            )
            for name in connected
        ),
        key=lambda app: app.name.casefold(),
    )


def discord_socket_available() -> bool:
    """Check Discord IPC locations used by native, Snap, and Flatpak installs."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = Path(runtime) if runtime else Path("/run/user") / str(os.getuid())
    locations = (
        base,
        base / "snap.discord",
        base / "app" / "com.discordapp.Discord",
    )
    return any(any(folder.glob("discord-ipc-*")) for folder in locations)


def ensure_mutable_section(data: dict[str, Any], name: str) -> dict[str, Any]:
    """Return a mutable copy of a section while preserving its unknown keys."""
    current = data.get(name)
    result = copy.deepcopy(dict(current)) if isinstance(current, Mapping) else {}
    data[name] = result
    return result


def atomic_write_config(data: Mapping[str, Any], path: Path | None = None) -> None:
    """Serialize configuration and atomically replace the destination file."""
    target = path or config_path()
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    body = yaml.safe_dump(
        dict(data), allow_unicode=True, default_flow_style=False, sort_keys=False
    )
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=".config.yaml.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(CONFIG_HEADER)
            temporary.write(body)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, target)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


def read_history_records(
    path: Path | None = None, *, limit: int | None = None
) -> list[HistoryRecord]:
    """Read valid JSONL records oldest-first, skipping malformed lines."""
    target = path or history_path()
    if not target.exists():
        return []
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    if limit is not None:
        lines = lines[-limit:]
    records: list[HistoryRecord] = []
    for line in lines:
        if not line.strip():
            continue
        try:
            data = json.loads(line)
            if not isinstance(data, dict):
                continue
            record: HistoryRecord = {
                "timestamp": str(data["timestamp"]),
                "words": max(0, int(data["words"])),
                "chars": max(0, int(data["chars"])),
                "audio_seconds": max(0.0, float(data.get("audio_seconds", 0.0))),
                "transcription_seconds": max(
                    0.0, float(data.get("transcription_seconds", 0.0))
                ),
                "injected": bool(data.get("injected", True)),
            }
            text = data.get("text")
            if text is None or isinstance(text, str):
                record["text"] = text
            # Validate the timestamp now so views never fail on malformed data.
            datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
            records.append(record)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return records


def delete_history_record(
    record: Mapping[str, Any], path: Path | None = None
) -> bool:
    """Atomically remove one matching JSONL record while preserving every other line."""
    target = path or history_path()
    if not target.exists():
        return False
    lines = target.read_text(encoding="utf-8").splitlines()
    kept: list[str] = []
    removed = False
    for line in lines:
        if removed:
            kept.append(line)
            continue
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            kept.append(line)
            continue
        if not isinstance(candidate, Mapping):
            kept.append(line)
            continue
        try:
            matches = (
                str(candidate.get("timestamp", "")) == str(record.get("timestamp", ""))
                and int(candidate.get("words", -1)) == int(record.get("words", -2))
                and int(candidate.get("chars", -1)) == int(record.get("chars", -2))
            )
        except (TypeError, ValueError):
            matches = False
        if matches:
            removed = True
        else:
            kept.append(line)
    if not removed:
        return False

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=".history.jsonl.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            if kept:
                temporary.write("\n".join(kept))
                temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, target.stat().st_mode & 0o777)
        os.replace(temporary_name, target)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass
    return True


def run_systemctl(action: str) -> None:
    """Run a bounded user service action and raise a readable error."""
    if action not in {"start", "stop", "restart"}:
        raise ValueError(f"Unsupported service action: {action}")
    try:
        result = subprocess.run(
            ["systemctl", "--user", action, "voiceflow"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Przekroczono czas oczekiwania na systemctl") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(detail or f"systemctl zakończył się kodem {result.returncode}")


def copy_to_clipboard(text: str) -> None:
    """Copy text through the compositor clipboard with a bounded subprocess."""
    try:
        result = subprocess.run(
            ["wl-copy"],
            input=text,
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Przekroczono czas kopiowania do schowka") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(detail or f"wl-copy zakończył się kodem {result.returncode}")


def installed_version() -> str:
    """App version from the project's pyproject.toml (single source of truth)."""
    pyproject = Path(__file__).resolve().parent.parent.parent / "pyproject.toml"
    try:
        for line in pyproject.read_text(encoding="utf-8").splitlines():
            if line.startswith("version"):
                return line.split('"')[1]
    except (OSError, IndexError):
        pass
    return "0.0.0"


def check_update() -> tuple[str, str] | None:
    """Return (latest, url) when a newer release exists; None otherwise.

    One anonymous request; the caller runs this off the main thread and only
    when the daemon-side daily cache would allow it anyway — the app checks
    once per launch.
    """
    import urllib.request

    request = urllib.request.Request(
        "https://api.github.com/repos/AveJaPl/voiceflow/releases/latest",
        headers={"User-Agent": "voiceflow-app"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None
    tag = str(data.get("tag_name", ""))
    url = str(data.get("html_url", "https://github.com/AveJaPl/voiceflow/releases"))

    def parse(text: str) -> tuple[int, ...]:
        parts = []
        for chunk in text.strip().lstrip("vV").split("."):
            digits = "".join(ch for ch in chunk if ch.isdigit())
            if not digits:
                break
            parts.append(int(digits))
        return tuple(parts) or (0,)

    return (tag, url) if parse(tag) > parse(installed_version()) else None
