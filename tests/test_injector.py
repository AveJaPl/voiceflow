"""Tests for safe ydotool arguments and injection fallback."""

from __future__ import annotations

import os
import time

import pytest

from voiceflow.config import InjectConfig
from voiceflow.injector import (
    InjectionError,
    Injector,
    build_key_command,
    build_type_command,
)


#: These two drive the Linux injector through a real `bash`, so they depend on
#: POSIX fork/exec semantics and on bash existing. Windows uses
#: voiceflow.winplat.injector and neither holds there.
_posix_only = pytest.mark.skipif(
    os.name == "nt", reason="zależy od semantyki fork/exec POSIX i powłoki bash"
)


@_posix_only
def test_run_does_not_wait_for_a_forked_grandchild() -> None:
    """Regression: wl-copy forks a child that keeps owning the Wayland selection.

    With stdout/stderr piped, subprocess.run waited for EOF on pipes that the
    surviving grandchild held open, so every paste timed out after 3 seconds.
    """
    started = time.perf_counter()

    Injector._run(["bash", "-c", "sleep 30 & exit 0"], timeout=3)

    assert time.perf_counter() - started < 2.0


@_posix_only
def test_run_reports_stderr_of_a_failing_command() -> None:
    with pytest.raises(InjectionError, match="nie ma takiego czegos"):
        Injector._run(["bash", "-c", "echo nie ma takiego czegos >&2; exit 3"], timeout=3)


def test_type_command_preserves_polish_text_and_leading_hyphen() -> None:
    text = "- Zażółć gęślą jaźń"

    command = build_type_command("/usr/bin/ydotool", 12, text)

    assert command == [
        "/usr/bin/ydotool",
        "type",
        "--key-delay",
        "12",
        "--",
        "- Zażółć gęślą jaźń",
    ]


def test_terminal_paste_chord_uses_press_then_reverse_release() -> None:
    command = build_key_command("ydotool", "ctrl+shift+v")

    assert command == ["ydotool", "key", "29:1", "42:1", "47:1", "47:0", "42:0", "29:0"]


def test_auto_falls_back_to_clipboard(monkeypatch: pytest.MonkeyPatch) -> None:
    injector = Injector(InjectConfig(method="auto"))
    pasted: list[str] = []

    def fail_ydotool(text: str) -> None:
        raise InjectionError(f"ydotool failed for {text}")

    monkeypatch.setattr(injector, "_inject_ydotool", fail_ydotool)
    monkeypatch.setattr(injector, "_inject_clipboard", pasted.append)

    result = injector.inject("tekst")

    assert result.method == "clipboard"
    assert result.fallback_reason == "ydotool failed for tekst"
    assert pasted == ["tekst"]


def test_explicit_ydotool_does_not_hide_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    injector = Injector(InjectConfig(method="ydotool"))

    def fail(_text: str) -> None:
        raise InjectionError("brak socketu")

    monkeypatch.setattr(injector, "_inject_ydotool", fail)

    try:
        injector.inject("tekst")
    except InjectionError as exc:
        assert "brak socketu" in str(exc)
    else:
        raise AssertionError("InjectionError was expected")


def test_polish_text_uses_unicode_safe_clipboard(monkeypatch: pytest.MonkeyPatch) -> None:
    injector = Injector(InjectConfig(method="ydotool"))
    pasted: list[str] = []
    monkeypatch.setattr(injector, "_inject_clipboard", pasted.append)

    result = injector.inject("Pchnąć w tę łódź jeża")

    assert result.method == "clipboard"
    assert "ASCII" in (result.fallback_reason or "")
    assert pasted == ["Pchnąć w tę łódź jeża"]
