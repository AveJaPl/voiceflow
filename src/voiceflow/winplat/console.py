"""Get rid of the console window Windows hands a background process.

Neither the daemon nor the desktop window has anything to say on a terminal:
one runs for the whole session behind a hotkey, the other draws its own window.
Both are started from a shortcut through ``pythonw.exe``, which should mean no
console at all — and yet a black window full of log lines lands in front of the
user's work, and the desktop window opens behind it.

The venv is why. uv builds ``.venv\\Scripts\\pythonw.exe`` as a trampoline that
re-launches the *console* interpreter of the base installation, and a console
program whose parent has no console to inherit is given a brand-new console
window of its own. The installer now replaces that trampoline with the real
``pythonw.exe``, so the window is never created; this module is what saves the
copies installed before that fix, and any launcher we do not control.

Nothing here fires when voiceflow is started from a terminal on purpose. A
console shared with another process — the shell that typed the command — is the
user's window, not ours, and taking it away would swallow the very output they
ran the command to read. Set ``VOICEFLOW_KEEP_CONSOLE`` to keep even our own.
"""

from __future__ import annotations

import contextlib
import logging
import os
import sys
from pathlib import Path

LOGGER = logging.getLogger(__name__)

_WINDOWS = os.name == "nt"

_SW_HIDE = 0
#: Room for the process list. A console with more processes on it than this is
#: emphatically not ours; the launch chain below is two deep at most.
_PROCESS_LIST_SIZE = 8


def _libraries():
    """The two DLLs this needs, imported only where they exist."""
    import ctypes

    return ctypes.windll.kernel32, ctypes.windll.user32


def _inside_installation(executable: str) -> bool:
    """True when a path points inside the environment this process runs from.

    ``sys.prefix`` is the virtualenv even when the interpreter binary itself
    lives in the base installation, which is exactly the trampoline's shape.
    """
    try:
        Path(executable).resolve().relative_to(Path(sys.prefix).resolve())
    except (OSError, ValueError):
        return False
    return True


def _is_our_launcher(pid: int) -> bool:
    """True when this pid is a process of ours that led to this one.

    Both halves matter. An ancestor alone would accept the shell that typed
    the command; an executable in our environment alone would accept an
    unrelated voiceflow someone parked on the same console.
    """
    try:
        import psutil
    except ImportError:  # pragma: no cover - psutil is a Windows dependency
        return False
    try:
        if pid not in {ancestor.pid for ancestor in psutil.Process().parents()}:
            return False
        return _inside_installation(psutil.Process(pid).exe())
    except (psutil.Error, OSError) as exc:
        LOGGER.debug("Nie można sprawdzić procesu %s na konsoli: %s", pid, exc)
        return False


def _console_is_ours(kernel32) -> bool:
    """True when nobody but us and our own launchers is on this console.

    Alone is the simple case: Windows made the console for us at launch. But
    an installed copy is usually started through uv's ``pythonw.exe``, which
    is a trampoline that re-launches the console interpreter — so the console
    Windows created for it holds two processes, and reading "two" as "someone
    else's terminal" left the black window standing in precisely the case this
    module exists for. Every extra process is therefore checked: our own
    launcher chain is still our own console, a shell is not.
    """
    import ctypes

    buffer = (ctypes.c_uint32 * _PROCESS_LIST_SIZE)()
    count = kernel32.GetConsoleProcessList(buffer, _PROCESS_LIST_SIZE)
    # Zero is the failure code, and a count above the buffer means the list did
    # not fit and was not written. Either way the console is treated as somebody
    # else's: leaving a window open is a blemish, closing the user's is a bug.
    if count < 1 or count > _PROCESS_LIST_SIZE:
        return False
    others = {buffer[index] for index in range(count)} - {os.getpid()}
    return all(_is_our_launcher(pid) for pid in others)


def _silence_standard_streams() -> None:
    """Point the standard descriptors at NUL before the console goes away.

    Freeing a console invalidates whatever descriptors 0-2 were writing to.
    Python keeps its ``sys.stdout``/``sys.stderr`` objects either way, and the
    first log record written through one of them would raise OSError from deep
    inside logging — so they are redirected somewhere harmless first.
    """
    try:
        null = os.open(os.devnull, os.O_RDWR)
    except OSError:
        return
    try:
        for descriptor in (0, 1, 2):
            with contextlib.suppress(OSError):
                os.dup2(null, descriptor)
    finally:
        if null > 2:
            with contextlib.suppress(OSError):
                os.close(null)


def hide_own_console() -> bool:
    """Detach from a console this process was given for itself.

    Returns True when a console window was taken away. Best effort throughout:
    a failure leaves the window where it is, which is ugly but never fatal —
    the daemon's real report goes to ``daemon.log`` regardless.
    """
    if not _WINDOWS or os.environ.get("VOICEFLOW_KEEP_CONSOLE"):
        return False
    try:
        kernel32, user32 = _libraries()
        window = kernel32.GetConsoleWindow()
        if not window or not _console_is_ours(kernel32):
            return False
        # Hidden first, then freed: FreeConsole destroys the window once the
        # last process lets go, and the user need not watch that happen.
        user32.ShowWindow(window, _SW_HIDE)
        _silence_standard_streams()
        kernel32.FreeConsole()
    except (AttributeError, OSError) as exc:  # pragma: no cover - Win32 misbehaving
        LOGGER.debug("Nie można ukryć konsoli: %s", exc)
        return False
    return True
