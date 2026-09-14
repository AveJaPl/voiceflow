"""One daemon per machine, decided before anything expensive happens.

The daemon already refused to start when another one answered the control
channel — but that endpoint is written at the *end* of startup, after a
multi-gigabyte model has been loaded and warmed up. For the thirty seconds in
between, voiceflow looked exactly like nothing was running, and a second launch
sailed straight past the check: the desktop window's "Uruchom demona" button, the
Start Menu icon, the autostart shortcut, all of them.

That is not a hypothetical. Seven daemons were once found loading seven copies
of the model at once, each slowing the others down so the boot took longer,
which made the window keep reporting nothing was running — and only the first
of them held the dictation shortcut, so the other six reported the hotkey as
taken by "another application". It was, by voiceflow.

So the very first thing a daemon does now is take a lock on a file, which the
operating system releases when the process dies — no stale lock can outlive a
crash, unlike the endpoint file this backs up. A second daemon finds it held and
exits in milliseconds, before importing a model at all.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

LOGGER = logging.getLogger(__name__)

_WINDOWS = os.name == "nt"

#: Which byte of the file is the claim. Deliberately past everything ever
#: written there, because a Windows lock is *mandatory*: a byte held this way
#: cannot even be read by another process, and locking byte zero would hide the
#: pid this file exists to publish. Locking past the end is allowed and is what
#: makes the claim and its explanation coexist.
_CLAIM_BYTE = 4096


class InstanceLock:
    """An exclusive, self-releasing claim on being *the* voiceflow daemon.

    Advisory and OS-level: ``fcntl.flock`` on Linux, ``msvcrt.locking`` on
    Windows. Both are attached to the open file rather than to a name on disk,
    so the claim dies with the process however it dies.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._handle = None

    @property
    def held(self) -> bool:
        return self._handle is not None

    def acquire(self) -> bool:
        """Take the lock, or return False when another process holds it."""
        if self.held:
            return True
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Opened, never truncated: the pid inside is a diagnostic, and emptying
        # the file before knowing whether we may have it would erase the other
        # daemon's own record of itself.
        handle = open(self.path, "a+b")  # noqa: SIM115 - held for the process's life
        try:
            self._lock(handle)
        except OSError:
            handle.close()
            return False
        try:
            handle.seek(0)
            handle.truncate()
            handle.write(f"{os.getpid()}\n".encode())
            handle.flush()
        except OSError as exc:  # pragma: no cover - the lock is what matters
            LOGGER.debug("Nie można zapisać pid do %s: %s", self.path, exc)
        self._handle = handle
        return True

    def release(self) -> None:
        """Give the lock up. Idempotent, and safe to call from a finally."""
        handle, self._handle = self._handle, None
        if handle is None:
            return
        try:
            self._unlock(handle)
        except OSError as exc:  # pragma: no cover - closing releases it anyway
            LOGGER.debug("Nie można zwolnić blokady %s: %s", self.path, exc)
        finally:
            handle.close()

    def __enter__(self) -> "InstanceLock":
        self.acquire()
        return self

    def __exit__(self, *_exception: object) -> None:
        self.release()

    @staticmethod
    def _lock(handle) -> None:
        if _WINDOWS:
            import msvcrt

            handle.seek(_CLAIM_BYTE)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            return
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    @staticmethod
    def _unlock(handle) -> None:
        if _WINDOWS:
            import msvcrt

            handle.seek(_CLAIM_BYTE)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            return
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def holder_pid(path: Path) -> int | None:
    """Which process claims to hold the lock, for a message worth reading."""
    try:
        first = path.read_bytes().split(b"\n", 1)[0].strip()
        return int(first) if first else None
    except (OSError, ValueError):
        return None
