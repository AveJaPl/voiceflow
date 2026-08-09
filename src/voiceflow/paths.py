"""XDG-compliant paths used by voiceflow."""

from __future__ import annotations

import os
from pathlib import Path


def config_dir() -> Path:
    """Return the voiceflow configuration directory."""
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "voiceflow"


def data_dir() -> Path:
    """Return the voiceflow data directory."""
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "voiceflow"


def runtime_base_dir() -> Path:
    """Return the per-user XDG runtime directory.

    Graphical sessions set ``XDG_RUNTIME_DIR``. The conventional systemd path is
    used as a defensive fallback for manually started shells.
    """
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

