"""Per-platform paths used by voiceflow.

Linux follows the XDG spec; Windows uses APPDATA (roaming config) and
LOCALAPPDATA (machine-local data and runtime files).
"""

from __future__ import annotations

import os
from pathlib import Path

_WINDOWS = os.name == "nt"


def config_dir() -> Path:
    """Return the voiceflow configuration directory."""
    if _WINDOWS:
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
        return base / "voiceflow"
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "voiceflow"


def data_dir() -> Path:
    """Return the voiceflow data directory."""
    if _WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / "voiceflow"
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "voiceflow"


def runtime_base_dir() -> Path:
    """Return the per-user XDG runtime directory.

    Graphical sessions set ``XDG_RUNTIME_DIR``. The conventional systemd path is
    used as a defensive fallback for manually started shells.
    """
    if _WINDOWS:
        return data_dir() / "run"
    configured = os.environ.get("XDG_RUNTIME_DIR")
    return Path(configured) if configured else Path("/run/user") / str(os.getuid())


def runtime_dir(*, create: bool = True) -> Path:
    """Return, and optionally create, voiceflow's private runtime directory."""
    path = runtime_base_dir() / "voiceflow"
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.chmod(0o700)
    return path


def daemon_socket_path() -> Path:
    """Return the daemon Unix socket path."""
    return runtime_dir() / "daemon.sock"


def ydotool_socket_path() -> Path:
    """Return the configured or default ydotool daemon socket path."""
    value = os.environ.get("YDOTOOL_SOCKET")
    return Path(value) if value else runtime_base_dir() / ".ydotool_socket"



def history_file() -> Path:
    """Return the dictation history file (JSONL) in the data directory."""
    directory = data_dir()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory / "history.jsonl"


def stats_file() -> Path:
    """Return the aggregated statistics file read by the GNOME Shell extension.

    The daemon rewrites it after every dictation and on its refresh timer, so
    the extension never has to parse the full history itself — the shell
    process must not spend milliseconds on JSONL parsing while drawing.
    """
    directory = data_dir()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory / "stats.json"
