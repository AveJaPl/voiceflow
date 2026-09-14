"""One daemon per machine, and the half-minute in which that used to fail.

The endpoint file only exists once a daemon is fully up, so it cannot answer
"is one starting?" — this lock can, from the first millisecond. These tests pin
the two properties the rest depends on: a second claim is refused, and a claim
does not outlive the process that made it.
"""

from __future__ import annotations

import subprocess
import sys
import textwrap
import time
from pathlib import Path

from voiceflow.instance import InstanceLock, holder_pid


def test_the_first_claim_wins(tmp_path: Path) -> None:
    first = InstanceLock(tmp_path / "daemon.lock")
    second = InstanceLock(tmp_path / "daemon.lock")

    assert first.acquire() is True
    assert second.acquire() is False
    assert first.held and not second.held


def test_releasing_hands_it_to_the_next_one(tmp_path: Path) -> None:
    first = InstanceLock(tmp_path / "daemon.lock")
    second = InstanceLock(tmp_path / "daemon.lock")
    first.acquire()

    first.release()

    assert second.acquire() is True


def test_acquiring_twice_is_not_a_deadlock(tmp_path: Path) -> None:
    """The daemon may re-enter this on a restart path; it must be harmless."""
    lock = InstanceLock(tmp_path / "daemon.lock")

    assert lock.acquire() is True
    assert lock.acquire() is True

    lock.release()


def test_the_holder_is_named_in_the_file(tmp_path: Path) -> None:
    """So "already running" can say *which* process, not just that one is."""
    lock = InstanceLock(tmp_path / "daemon.lock")
    lock.acquire()

    import os

    assert holder_pid(lock.path) == os.getpid()


def test_no_holder_no_pid(tmp_path: Path) -> None:
    assert holder_pid(tmp_path / "never-locked.lock") is None


def test_a_dead_process_leaves_nothing_locked(tmp_path: Path) -> None:
    """A crashed daemon must not lock voiceflow out of ever starting again.

    This is why the lock lives on an open file rather than on the file's
    existence: the operating system drops it when the process dies, however it
    dies. The child below is killed outright — no cleanup runs at all.
    """
    lock_path = tmp_path / "daemon.lock"
    script = textwrap.dedent(
        f"""
        import time
        from pathlib import Path
        from voiceflow.instance import InstanceLock

        lock = InstanceLock(Path({str(lock_path)!r}))
        assert lock.acquire()
        print("held", flush=True)
        time.sleep(60)
        """
    )
    child = subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert child.stdout is not None
        assert child.stdout.readline().strip() == "held"
        assert InstanceLock(lock_path).acquire() is False, "dziecko trzyma blokadę"
    finally:
        child.kill()
        child.wait(timeout=10)

    # Polled rather than asserted outright: Windows tears a killed process's
    # handles down on its own schedule, a beat after the wait above returns.
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if InstanceLock(lock_path).acquire():
            return
        time.sleep(0.1)
    raise AssertionError("blokada przeżyła proces, który ją trzymał")
