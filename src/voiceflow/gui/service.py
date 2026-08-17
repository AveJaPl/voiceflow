"""What the window needs from the machine: the daemon, audio, the clipboard.

Unlike the GTK application — which runs on the system Python and therefore
reimplements everything — this window ships inside the package and simply uses
the daemon's own modules. There is no second copy of the config schema, the
history reader, or the IPC protocol to drift out of step.

Every call here is safe to make from a worker thread and raises ``RuntimeError``
with a message fit to show the user.
"""

from __future__ import annotations

import contextlib
import copy
import dataclasses
import json
import logging
import os
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from voiceflow.daemon import send_request
from voiceflow.history import read_records
from voiceflow.paths import config_dir, data_dir, history_file, room_state_file

LOGGER = logging.getLogger(__name__)

CONFIG_HEADER = "# voiceflow configuration (edited by the desktop app; reference: README)\n"

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
COMPUTE_TYPES = ("float16", "int8_float16", "int8", "float32")

_CREATE_NO_WINDOW = 0x08000000


def config_path() -> Path:
    """The YAML file the daemon reads."""
    return config_dir() / "config.yaml"


def log_path() -> Path:
    return data_dir() / "daemon.log"


def icon_path() -> Path | None:
    """The application icon, when running from a source checkout or install.

    It lives in ``windows/`` beside the package rather than inside it, so it is
    absent from a bare wheel install — the window simply goes without one.
    """
    candidate = Path(__file__).resolve().parents[3] / "windows" / "voiceflow.ico"
    return candidate if candidate.exists() else None


# -- daemon ------------------------------------------------------------------


def daemon_status() -> dict[str, Any] | None:
    """Return the daemon's status, or None when nothing is listening."""
    try:
        return send_request("status", timeout=2.0)
    except (RuntimeError, OSError):
        return None


def probe_binding(binding: str) -> str:
    """Can the daemon actually have this chord? One of free/taken/current.

    Windows answers by letting us register it, but our own running daemon holds
    the shortcut it is listening on — probing that one fails, and reporting it
    as "taken" would tell the user their current, working hotkey is unusable.
    So the daemon's own binding is recognised first.

    Raises ``ValueError`` when the text is not a binding at all.
    """
    from voiceflow.winplat.hotkey import binding_is_available

    status = daemon_status()
    if (
        isinstance(status, dict)
        and binding == status.get("hotkey")
        # Only when it really holds it. A daemon whose registration failed owns
        # nothing, and the probe below is then the honest answer.
        and status.get("hotkey_active")
    ):
        return "current"
    return "free" if binding_is_available(binding) else "taken"


def daemon_command(command: str, *, timeout: float = 3.0) -> dict[str, Any]:
    try:
        return send_request(command, timeout=timeout)
    except (RuntimeError, OSError) as exc:
        raise RuntimeError(str(exc)) from exc


def _daemon_launcher() -> list[str]:
    """The command that starts a detached, window-less daemon.

    Prefers the interpreter running this window, so the daemon always comes
    from the same environment as the UI that launched it.
    """
    executable = Path(sys.executable)
    windowless = executable.with_name("pythonw.exe")
    interpreter = windowless if windowless.exists() else executable
    return [str(interpreter), "-m", "voiceflow", "daemon"]


#: The daemon this window launched, while it is still starting up. A daemon
#: takes half a minute to load its model and answers nothing until it has, so
#: without this every impatient second click spawned another one — and each one
#: loaded its own copy of the model, making the wait longer still.
_LAUNCHED: "subprocess.Popen[bytes] | None" = None


def launch_pending() -> bool:
    """True while a daemon this window launched is still running.

    Deliberately does not ask the daemon anything: this is called from the UI
    thread on every status refresh, and the answer has to be free.
    """
    return _LAUNCHED is not None and _LAUNCHED.poll() is None


def start_daemon() -> None:
    """Launch the daemon and detach from it, unless one is already on its way."""
    global _LAUNCHED

    if daemon_status() is not None:
        return
    if _LAUNCHED is not None and _LAUNCHED.poll() is None:
        LOGGER.info("Demon już się uruchamia; nie uruchamiam drugiego")
        return
    try:
        _LAUNCHED = subprocess.Popen(
            _daemon_launcher(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=_CREATE_NO_WINDOW if os.name == "nt" else 0,
            close_fds=True,
        )
    except OSError as exc:
        raise RuntimeError(f"Nie można uruchomić demona: {exc}") from exc


def stop_daemon() -> None:
    """Ask the daemon to shut down; silence means it was not running."""
    try:
        send_request("shutdown", timeout=3.0)
    except (RuntimeError, OSError) as exc:
        raise RuntimeError(f"Nie można zatrzymać demona: {exc}") from exc


def restart_daemon(wait_seconds: float = 20.0) -> None:
    """Stop, then start once the old instance has released its endpoint.

    The daemon must fully exit before the next one starts, or the new process
    hits the single-instance guard and dies immediately.
    """
    import time

    with contextlib.suppress(RuntimeError):
        stop_daemon()
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if daemon_status() is None:
            break
        time.sleep(0.25)
    start_daemon()


# -- configuration -----------------------------------------------------------


def load_raw_config(path: Path | None = None) -> dict[str, Any]:
    """Load the YAML mapping verbatim, so unknown keys survive a round trip."""
    target = path or config_path()
    if not target.exists():
        return {}
    try:
        loaded = yaml.safe_load(target.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise RuntimeError(f"Nie można wczytać pliku {target}: {exc}") from exc
    if loaded is None:
        return {}
    if not isinstance(loaded, Mapping):
        raise RuntimeError(f"Główny element pliku {target} nie jest mapą YAML")
    return copy.deepcopy(dict(loaded))


def atomic_write_config(data: Mapping[str, Any], path: Path | None = None) -> None:
    """Replace the config file in one step, never leaving a half-written one."""
    target = path or config_path()
    target.parent.mkdir(parents=True, exist_ok=True)
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
        os.replace(temporary_name, target)
        temporary_name = None
    except OSError as exc:
        raise RuntimeError(f"Nie można zapisać konfiguracji: {exc}") from exc
    finally:
        if temporary_name is not None:
            with contextlib.suppress(OSError):
                Path(temporary_name).unlink()


#: Serializes read-modify-write on config.yaml. Each page saves from its own
#: worker thread, and two overlapping cycles would otherwise interleave their
#: reads and writes, dropping whichever change was written first.
_CONFIG_LOCK = threading.Lock()


def update_config(mutate: "Callable[[dict[str, Any]], None]") -> dict[str, Any]:
    """Re-read the file, apply one page's changes, write it back.

    Never write a whole mapping a page loaded minutes ago: the settings page,
    the vocabulary page and the user's own text editor all write this file, and
    a stale snapshot silently reverts whatever the others did in between.
    """
    with _CONFIG_LOCK:
        current = load_raw_config()
        mutate(current)
        atomic_write_config(current)
        return current


def section(data: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    value = data.get(name, {})
    return value if isinstance(value, Mapping) else {}


def mutable_section(data: dict[str, Any], name: str) -> dict[str, Any]:
    """Return a mutable section, preserving keys this window does not know."""
    current = data.get(name)
    result = copy.deepcopy(dict(current)) if isinstance(current, Mapping) else {}
    data[name] = result
    return result


def string_value(data: Mapping[str, Any], key: str, default: str) -> str:
    value = data.get(key, default)
    return value if isinstance(value, str) and value else default


def bool_value(data: Mapping[str, Any], key: str, default: bool) -> bool:
    value = data.get(key, default)
    return value if isinstance(value, bool) else default


def int_value(data: Mapping[str, Any], key: str, default: int) -> int:
    value = data.get(key, default)
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return value
    return default


def float_value(data: Mapping[str, Any], key: str, default: float) -> float:
    value = data.get(key, default)
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0:
        return float(value)
    return default


def string_list_value(data: Mapping[str, Any], key: str) -> list[str]:
    value = data.get(key, [])
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if not isinstance(value, (list, tuple)):
        return []
    return [item.strip() for item in value if isinstance(item, str) and item.strip()]


def float_mapping_value(data: Mapping[str, Any], key: str) -> dict[str, float]:
    value = data.get(key, {})
    if not isinstance(value, Mapping):
        return {}
    result: dict[str, float] = {}
    for name, volume in value.items():
        if not isinstance(name, str) or not name.strip():
            continue
        if isinstance(volume, (int, float)) and not isinstance(volume, bool):
            if 0.0 <= float(volume) <= 1.0:
                result[name.strip()] = float(volume)
    return result


# -- history -----------------------------------------------------------------


def history_records(limit: int | None = None) -> list[dict[str, Any]]:
    """History as plain dicts, oldest first — the shape statlib expects."""
    return [dataclasses.asdict(record) for record in read_records(limit=limit)]


def delete_history_record(record: Mapping[str, Any]) -> bool:
    """Remove one entry, preserving every other line byte for byte."""
    target = history_file()
    if not target.exists():
        return False
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise RuntimeError(f"Nie można odczytać historii: {exc}") from exc

    kept: list[str] = []
    removed = False
    for line in lines:
        if removed:
            kept.append(line)
            continue
        try:
            candidate = json.loads(line)
            matches = (
                isinstance(candidate, Mapping)
                and str(candidate.get("timestamp", "")) == str(record.get("timestamp", ""))
                and int(candidate.get("words", -1)) == int(record.get("words", -2))
                and int(candidate.get("chars", -1)) == int(record.get("chars", -2))
            )
        except (json.JSONDecodeError, TypeError, ValueError):
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
                temporary.write("\n".join(kept) + "\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, target)
        temporary_name = None
    except OSError as exc:
        raise RuntimeError(f"Nie można zapisać historii: {exc}") from exc
    finally:
        if temporary_name is not None:
            with contextlib.suppress(OSError):
                Path(temporary_name).unlink()
    return True


# -- audio, clipboard, Discord ----------------------------------------------


@dataclass(frozen=True, slots=True)
class AudioApplication:
    """One application the audio system knows about.

    ``playing`` means it has a live playback session right now. Windows keeps
    expired sessions around for a while, which is useful: an app that is merely
    paused stays visible instead of vanishing from the ducking list.

    ``capturing`` means it is holding a microphone — the apps worth adding to
    the mic-mute list, and the only ones that can be muted individually.
    """

    name: str
    playing: bool = False
    capturing: bool = False


def discover_audio_applications() -> list[AudioApplication]:
    """List applications playing or recording audio, via Core Audio."""
    if os.name != "nt":
        return []
    from voiceflow.winplat.micmute import capture_sessions, run_with_audio

    found: dict[str, bool] = {}
    capturing: set[str] = set()

    def collect() -> None:
        # Runs on the Core Audio thread; see micmute for why that matters.
        from pycaw.pycaw import AudioUtilities

        for session in AudioUtilities.GetAllSessions():
            process = session.Process
            if process is None:
                continue
            try:
                name = process.name()
            except Exception:  # noqa: BLE001 - the process may have just exited
                continue
            if not name:
                continue
            # State 1 is Active; anything else is expired or inactive.
            active = getattr(session, "State", 0) == 1
            found[name] = found.get(name, False) or active
        for session in capture_sessions():
            # Only a session Windows calls Active means "holding the microphone
            # right now"; the rest are leftovers and would read as a lie.
            if session.active:
                capturing.add(session.app)
            found.setdefault(session.app, False)

    try:
        run_with_audio(collect)
    except Exception as exc:  # noqa: BLE001 - Core Audio is best effort
        raise RuntimeError(f"Nie można odczytać sesji audio: {exc}") from exc
    return sorted(
        (
            AudioApplication(name, playing, name in capturing)
            for name, playing in found.items()
        ),
        key=lambda application: application.name.casefold(),
    )


def discord_available() -> bool:
    """True when Discord's local IPC pipe answers."""
    if os.name != "nt":
        return False
    return any(Path(rf"\\.\pipe\discord-ipc-{index}").exists() for index in range(10))


def copy_to_clipboard(text: str) -> None:
    if os.name != "nt":
        raise RuntimeError("Kopiowanie z tego okna działa na Windowsie")
    from voiceflow.winplat.injector import _set_clipboard_text

    try:
        _set_clipboard_text(text)
    except OSError as exc:
        raise RuntimeError(f"Nie można skopiować do schowka: {exc}") from exc


def open_in_explorer(path: Path) -> None:
    """Reveal a file or folder in the shell, without blocking the UI."""
    try:
        if os.name == "nt":
            os.startfile(str(path))  # noqa: S606 - a user-initiated shell open
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except OSError as exc:
        raise RuntimeError(f"Nie można otworzyć {path}: {exc}") from exc


# -- the room ----------------------------------------------------------------


def room_state():
    """The daemon's live view of the room: who is speaking, is the link up.

    Read from the file the daemon writes rather than asked over the control
    channel, because it must also be readable while the daemon is restarting —
    which is exactly what happens right after joining a room.
    """
    from voiceflow.roomstate import read_room_state

    return read_room_state()


def room_state_path() -> Path:
    return room_state_file()


def create_room(server: str, name: str, display_name: str) -> str:
    """Create a room, write it into the configuration, restart the daemon.

    The restart is not optional and not the user's business: the daemon reads
    its configuration once, at startup, so without it joining a room would
    silently do nothing.
    """
    from voiceflow.roomsetup import RoomSetupError, create_room as setup_create, save_to_config

    try:
        result = setup_create(server, name, display_name, _existing_room_token())
        save_to_config(server, result["code"], result["token"])
    except RoomSetupError as exc:
        raise RuntimeError(f"Nie udało się utworzyć pokoju: {exc}") from exc
    _restart_for_room()
    return str(result["code"])


def join_room(server: str, code: str, display_name: str) -> str:
    """Join an existing room by code, then restart the daemon so it takes hold."""
    from voiceflow.roomsetup import RoomSetupError, join_room as setup_join, save_to_config

    try:
        result = setup_join(server, code, display_name, _existing_room_token())
        save_to_config(server, result["code"], result["token"])
    except RoomSetupError as exc:
        raise RuntimeError(f"Nie udało się dołączyć: {exc}") from exc
    _restart_for_room()
    return str(result["code"])


def leave_room() -> None:
    """Switch the room off, keeping the code for a quick return."""
    from voiceflow.roomsetup import RoomSetupError, leave_room as setup_leave

    raw = load_raw_config()
    room = section(raw, "room")
    try:
        setup_leave(
            string_value(room, "server", ""),
            string_value(room, "code", ""),
            string_value(room, "token", ""),
        )
    except (RoomSetupError, OSError) as exc:
        raise RuntimeError(f"Nie udało się wyjść z pokoju: {exc}") from exc
    _restart_for_room()


def _existing_room_token() -> str:
    """Reuse this machine's device token instead of registering it twice."""
    return string_value(section(load_raw_config(), "room"), "token", "")


def _restart_for_room() -> None:
    if daemon_status() is not None:
        restart_daemon()


def room_advertiser():
    """The mDNS publisher, or a silent stand-in on a platform without one."""
    if os.name == "nt":
        from voiceflow.winplat.mdns import RoomAdvertiser

        return RoomAdvertiser()
    return _NoAdvertiser()


def room_browser(on_change):
    """The mDNS browser, or a silent stand-in on a platform without one."""
    if os.name == "nt":
        from voiceflow.winplat.mdns import RoomBrowser

        return RoomBrowser(on_change)
    return _NoBrowser()


class _NoAdvertiser:
    """Discovery absent is a missing shortcut, not a broken room."""

    def publish(self, **_fields: str) -> None:
        return None

    def withdraw(self) -> None:
        return None


class _NoBrowser:
    def start(self) -> None:
        return None

    def stop(self) -> None:
        return None

    def rooms(self) -> list:
        return []


# -- updates -----------------------------------------------------------------


def newer_release() -> tuple[str, str] | None:
    """Return (tag, url) when GitHub has a newer release; None otherwise.

    One anonymous request, made once per launch from a worker thread.
    """
    from voiceflow.updates import RELEASES_URL, fetch_latest_version, installed_version, is_newer

    result = fetch_latest_version()
    if result is None:
        return None
    tag, url = result
    if not is_newer(tag, installed_version()):
        return None
    return tag, url or RELEASES_URL
