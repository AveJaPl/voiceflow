"""Whose console is it — ours to close, or the terminal the user is reading?

The Win32 calls are stubbed, so the decision itself is what these exercise, on
every platform. Getting it wrong in one direction leaves a black window over
the user's work; in the other it closes the terminal they ran the command in
and swallows the output they wanted.
"""

from __future__ import annotations

import pytest

from voiceflow.winplat import console


class FakeKernel:
    """Just enough kernel32: a console window and the processes on it."""

    def __init__(self, window: int = 4242, processes: int = 1) -> None:
        self.window = window
        self.processes = processes
        self.freed = False

    def GetConsoleWindow(self) -> int:  # noqa: N802 - Win32 naming
        return self.window

    def GetConsoleProcessList(self, buffer, size) -> int:  # noqa: N802
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


def test_a_console_shared_with_a_shell_is_left_alone(win32):
    kernel, user = win32
    kernel.processes = 2

    assert console.hide_own_console() is False
    assert user.hidden == []
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
