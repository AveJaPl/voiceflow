"""Whose console is it — ours to close, or the terminal the user is reading?

The Win32 calls are stubbed, so the decision itself is what these exercise, on
every platform. Getting it wrong in one direction leaves a black window over
the user's work; in the other it closes the terminal they ran the command in
and swallows the output they wanted.
"""

from __future__ import annotations

import os

import pytest

from voiceflow.winplat import console


class FakeKernel:
    """Just enough kernel32: a console window and the processes on it.

    ``processes`` is the count Win32 reports; ``pids`` is what it writes into
    the caller's buffer. They are separate on purpose — a count larger than the
    buffer means Windows wrote nothing at all, and that case has to be testable.
    """

    def __init__(self, window: int = 4242, processes: int = 1, pids=None) -> None:
        self.window = window
        self.processes = processes
        self.pids = pids if pids is not None else [os.getpid()]
        self.freed = False

    def GetConsoleWindow(self) -> int:  # noqa: N802 - Win32 naming
        return self.window

    def GetConsoleProcessList(self, buffer, size) -> int:  # noqa: N802
        for index, pid in enumerate(self.pids[:size]):
            buffer[index] = pid
        return self.processes

    def FreeConsole(self) -> int:  # noqa: N802
        self.freed = True
        return 1


class FakeUser:
    def __init__(self) -> None:
        self.hidden: list[tuple[int, int]] = []

    def ShowWindow(self, window: int, command: int) -> int:  # noqa: N802
        self.hidden.append((window, command))
        return 1


@pytest.fixture
def launchers(monkeypatch):
    """Which pids count as our own launchers, without asking the real psutil."""
    ours: set[int] = set()
    monkeypatch.setattr(console, "_is_our_launcher", lambda pid: pid in ours)
    return ours


@pytest.fixture
def win32(monkeypatch):
    """Pretend to be Windows, with stubbed libraries and untouched streams."""
    kernel, user = FakeKernel(), FakeUser()
    monkeypatch.setattr(console, "_WINDOWS", True)
    monkeypatch.setattr(console, "_libraries", lambda: (kernel, user))
    monkeypatch.setattr(console, "_silence_standard_streams", lambda: None)
    monkeypatch.delenv("VOICEFLOW_KEEP_CONSOLE", raising=False)
    return kernel, user


def test_a_console_of_our_own_is_hidden_and_freed(win32):
    kernel, user = win32

    assert console.hide_own_console() is True
    assert user.hidden == [(4242, console._SW_HIDE)]
    assert kernel.freed


def test_a_console_shared_with_a_shell_is_left_alone(win32, launchers):
    """The terminal the user typed the command in stays, output and all."""
    kernel, user = win32
    kernel.processes, kernel.pids = 2, [os.getpid(), 777]
    launchers.clear()

    assert console.hide_own_console() is False
    assert user.hidden == []
    assert not kernel.freed


def test_a_console_shared_with_our_own_trampoline_is_hidden(win32, launchers):
    """uv's pythonw.exe re-launches the console interpreter: two of ours.

    This is what an installed copy looks like, and reading it as a shell is
    what left a black window full of logs in front of the user's work.
    """
    kernel, user = win32
    kernel.processes, kernel.pids = 2, [os.getpid(), 777]
    launchers.add(777)

    assert console.hide_own_console() is True
    assert user.hidden == [(4242, console._SW_HIDE)]
    assert kernel.freed


def test_one_stranger_among_our_own_is_enough_to_leave_it(win32, launchers):
    kernel, _ = win32
    kernel.processes, kernel.pids = 3, [os.getpid(), 777, 999]
    launchers.add(777)

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_a_process_list_too_long_to_read_counts_as_someone_elses(win32, launchers):
    """Above the buffer size Windows reports the count and writes nothing."""
    kernel, _ = win32
    kernel.processes, kernel.pids = console._PROCESS_LIST_SIZE + 1, [os.getpid()]
    launchers.add(777)

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_no_console_is_nothing_to_do(win32):
    kernel, _ = win32
    kernel.window = 0

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_an_unreadable_process_list_counts_as_someone_elses(win32):
    kernel, _ = win32
    kernel.processes = 0

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_the_escape_hatch_keeps_the_console(win32, monkeypatch):
    kernel, _ = win32
    monkeypatch.setenv("VOICEFLOW_KEEP_CONSOLE", "1")

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_other_platforms_never_touch_anything(win32, monkeypatch):
    kernel, _ = win32
    monkeypatch.setattr(console, "_WINDOWS", False)

    assert console.hide_own_console() is False
    assert not kernel.freed


def test_only_executables_from_our_own_environment_are_ours(tmp_path, monkeypatch):
    """The trampoline sits in the venv; a shell never does.

    ``sys.prefix`` is the environment even when the running binary belongs to
    the base installation, so it is what the launcher chain is measured against.
    """
    monkeypatch.setattr(console.sys, "prefix", str(tmp_path))

    assert console._inside_installation(str(tmp_path / "Scripts" / "pythonw.exe"))
    assert not console._inside_installation(str(tmp_path.parent / "cmd.exe"))
