"""Tests for the daemon state machine without hardware or a Whisper model."""

from __future__ import annotations

import threading
import time
from pathlib import Path

from voiceflow.config import Config
from voiceflow.daemon import State, VoiceflowDaemon
from voiceflow.injector import InjectionResult, ProbeResult
from voiceflow.transcriber import TranscriptionResult


class _Recorder:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.cancelled = False

    def start(self) -> Path:
        self.path.write_bytes(b"RIFF" + b"0" * 64)
        return self.path

    def stop(self) -> Path:
        return self.path

    def cancel(self) -> None:
        self.cancelled = True
        self.path.unlink(missing_ok=True)

    def cleanup(self) -> None:
        self.cancel()


class _BlockingTranscriber:
    device = "cuda"
    compute_type = "float16"

    def __init__(self) -> None:
        self.release = threading.Event()

    def transcribe(self, _audio_path: Path) -> TranscriptionResult:
        self.release.wait(timeout=2)
        return TranscriptionResult("Zażółć gęślą jaźń", "pl", 1.0, 0.1)

    def transcribe_preview(self, _audio: object) -> str | None:
        return None


class _Injector:
    def __init__(self) -> None:
        self.texts: list[str] = []

    def inject(self, text: str) -> InjectionResult:
        self.texts.append(text)
        return InjectionResult("ydotool")

    def probe(self) -> ProbeResult:
        return ProbeResult(True, "/run/user/1000/.ydotool_socket", True, True, True, True, "Gotowe")


class _Notifier:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def send(self, message: str, *, urgency: str = "normal", expire_ms: int | None = None) -> None:
        self.messages.append(f"{urgency}:{message}")


class _Overlay:
    """Records overlay calls instead of spawning a real on-screen window."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, str | None]] = []

    def start(self, state: str = "listening", text: str | None = None) -> None:
        self.calls.append(("start", state, text))

    def update(self, state: str, text: str | None = None) -> None:
        self.calls.append(("update", state, text))

    def stop(self) -> None:
        self.calls.append(("stop", "", None))


def test_toggle_state_machine_ignores_toggle_during_transcription(tmp_path: Path) -> None:
    transcriber = _BlockingTranscriber()
    injector = _Injector()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=transcriber,
        injector=injector,  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
    )

    started = daemon.handle_command("toggle")
    assert started["state"] == State.RECORDING

    stopped = daemon.handle_command("toggle")
    assert stopped["state"] == State.TRANSCRIBING

    ignored = daemon.handle_command("toggle")
    assert ignored["ok"] is True
    assert "pominięto" in ignored["message"]
    assert daemon.handle_command("status")["state"] == State.TRANSCRIBING

    transcriber.release.set()
    deadline = time.monotonic() + 2
    while daemon.state is not State.IDLE and time.monotonic() < deadline:
        time.sleep(0.01)
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    assert daemon.state is State.IDLE
    assert injector.texts == ["Zażółć gęślą jaźń"]


def test_cancel_discards_recording(tmp_path: Path) -> None:
    recorder = _Recorder(tmp_path / "recording.wav")
    transcriber = _BlockingTranscriber()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=recorder,
        transcriber=transcriber,
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
    )

    daemon.handle_command("start")
    response = daemon.handle_command("cancel")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    assert response["ok"] is True
    assert response["state"] == State.IDLE
    assert recorder.cancelled is True
    assert not recorder.path.exists()
