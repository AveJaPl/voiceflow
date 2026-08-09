"""Tests for pw-record command construction and safe process stopping."""

from __future__ import annotations

import signal
import subprocess
import wave
from pathlib import Path

import pytest

from voiceflow.config import AudioConfig
from voiceflow.recorder import (
    Recorder,
    RecorderError,
    _validate_wav,
    build_record_command,
)


def test_record_command_without_source(tmp_path: Path) -> None:
    output = tmp_path / "audio.wav"

    command = build_record_command(AudioConfig(), output)

    assert command == [
        "pw-record",
        "--rate",
        "16000",
        "--channels",
        "1",
        "--format",
        "s16",
        str(output),
    ]


def test_record_command_adds_configured_target(tmp_path: Path) -> None:
    output = tmp_path / "audio.wav"

    command = build_record_command(AudioConfig(source="alsa_input.usb"), output)

    assert command[-3:] == ["--target", "alsa_input.usb", str(output)]


class _Process:
    def __init__(self, waits: list[int | subprocess.TimeoutExpired]) -> None:
        self.waits = waits
        self.signals: list[int] = []
        self.killed = False
        self.stderr = None

    def send_signal(self, value: int) -> None:
        self.signals.append(value)

    def wait(self, timeout: float) -> int:
        value = self.waits.pop(0)
        if isinstance(value, subprocess.TimeoutExpired):
            raise value
        return value

    def kill(self) -> None:
        self.killed = True


def test_finish_sends_sigint_before_waiting() -> None:
    process = _Process([0])

    Recorder._finish_process(process)  # type: ignore[arg-type]

    assert process.signals == [signal.SIGINT]
    assert process.killed is False


def test_finish_kills_only_after_sigint_timeout() -> None:
    process = _Process([subprocess.TimeoutExpired("pw-record", 5), -signal.SIGKILL])

    with pytest.raises(RecorderError):
        Recorder._finish_process(process)  # type: ignore[arg-type]

    assert process.signals == [signal.SIGINT]
    assert process.killed is True


def test_exit_code_one_after_sigint_is_not_an_error() -> None:
    """Regression: pw-record always exits 1 after SIGINT with a perfectly good WAV.

    Treating that as a failure discarded every single recording.
    """
    process = _Process([1])

    Recorder._finish_process(process)  # type: ignore[arg-type]

    assert process.killed is False


def test_valid_wav_reports_its_duration(tmp_path: Path) -> None:
    path = tmp_path / "audio.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(b"\x00\x01" * 16000)

    assert _validate_wav(path) == pytest.approx(1.0)


def test_header_only_wav_is_rejected(tmp_path: Path) -> None:
    """A SIGKILLed pw-record leaves a header claiming zero frames."""
    path = tmp_path / "audio.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)

    assert _validate_wav(path) is None


def test_garbage_file_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "audio.wav"
    path.write_bytes(b"to nie jest WAV")

    assert _validate_wav(path) is None


def test_missing_file_is_rejected(tmp_path: Path) -> None:
    assert _validate_wav(tmp_path / "nie-ma.wav") is None
