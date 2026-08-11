"""Tests for the daemon state machine without hardware or a Whisper model."""

from __future__ import annotations

import threading
import time
from pathlib import Path

from voiceflow.config import Config, HistoryConfig, TrayConfig
from voiceflow.daemon import State, VoiceflowDaemon
from voiceflow.history import History
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


class _FailingInjector:
    """Raises on every inject() call, like a broken ydotool/wtype setup."""

    def inject(self, text: str) -> InjectionResult:
        raise RuntimeError("wstrzykiwanie nie powiodło się")

    def probe(self) -> ProbeResult:
        return ProbeResult(False, None, False, False, False, False, "Błąd")


class _Notifier:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def send(self, message: str, *, urgency: str = "normal", expire_ms: int | None = None) -> None:
        self.messages.append(f"{urgency}:{message}")


class _Muter:
    """Records mute calls instead of touching the machine's real audio.

    Without this the daemon builds a live Core Audio muter, and running the
    suite genuinely mutes the developer's microphone and turns their music down
    — which is both rude and a source of crashes, since COM pointers then
    outlive the threads pytest creates and destroys.
    """

    def __init__(self) -> None:
        self.calls: list[str] = []

    def mute(self) -> None:
        self.calls.append("mute")

    def unmute(self) -> None:
        self.calls.append("unmute")


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

    def notice(self, text: str, *, timeout_ms: int | None = None) -> None:
        self.calls.append(("notice", "notice", text))


class _Tray:
    """Records tray calls instead of spawning a real indicator process."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def start(self) -> None:
        self.calls.append(("start", None, None))

    def update(self, label: str, summary: list[str]) -> None:
        self.calls.append(("update", label, list(summary)))

    def stop(self) -> None:
        self.calls.append(("stop", None, None))


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
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        micmuter=_Muter(),  # type: ignore[arg-type]
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


class _SilentTranscriber:
    """A recording that turned out to contain no speech."""

    device = "cuda"
    compute_type = "float16"

    def transcribe(self, _audio_path: Path) -> TranscriptionResult:
        return TranscriptionResult("", "pl", 1.0, 0.1)

    def transcribe_preview(self, _audio: object) -> str | None:
        return None


def test_silence_reports_on_the_card_not_in_a_notification(tmp_path: Path) -> None:
    """No speech is an outcome, not an alert: it belongs where the user looked."""
    notifier = _Notifier()
    overlay = _Overlay()
    injector = _Injector()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_SilentTranscriber(),
        injector=injector,  # type: ignore[arg-type]
        notifier=notifier,  # type: ignore[arg-type]
        overlay=overlay,  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
    )

    daemon.handle_command("start")
    daemon.handle_command("stop")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    notices = [call for call in overlay.calls if call[0] == "notice"]
    assert len(notices) == 1
    assert "mowy" in (notices[0][2] or "")
    # No desktop notification: that was the whole point of the change.
    assert notifier.messages == []
    # And the card must not be torn down in the same breath, or the message
    # would be gone before it could be read.
    assert overlay.calls[-1][0] == "notice"
    assert injector.texts == []


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
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        micmuter=_Muter(),  # type: ignore[arg-type]
    )

    daemon.handle_command("start")
    response = daemon.handle_command("cancel")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    assert response["ok"] is True
    assert response["state"] == State.IDLE
    assert recorder.cancelled is True
    assert not recorder.path.exists()


def test_daemon_starts_the_tray_and_shows_zero_stats(tmp_path: Path) -> None:
    tray = _Tray()
    VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    assert tray.calls[0] == ("start", None, None)
    assert tray.calls[1] == (
        "update",
        "0 min · 💬 0",
        ["Ten tydzień: 0 min · 0 słów", "Ten miesiąc: 0 min · 0 słów", "Ten rok: 0 min · 0 słów"],
    )


def test_disabled_tray_does_no_background_work(tmp_path: Path) -> None:
    tray = _Tray()
    VoiceflowDaemon(
        Config(tray=TrayConfig(enabled=False)),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    assert tray.calls == []


class _ThreeWordTranscriber:
    device = "cuda"
    compute_type = "float16"

    def transcribe(self, _audio_path: Path) -> TranscriptionResult:
        return TranscriptionResult("trzy słowa tutaj", "pl", 60.0, 0.1)

    def transcribe_preview(self, _audio: object) -> str | None:
        return None


def test_dictation_pushes_fresh_stats_to_the_tray(tmp_path: Path) -> None:
    tray = _Tray()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_ThreeWordTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    daemon.handle_command("start")
    daemon.handle_command("stop")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    assert tray.calls[-1] == (
        "update",
        "1 min · 💬 3",
        ["Ten tydzień: 1 min · 3 słów", "Ten miesiąc: 1 min · 3 słów", "Ten rok: 1 min · 3 słów"],
    )


def test_failed_injection_still_refreshes_the_tray(tmp_path: Path) -> None:
    tray = _Tray()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_ThreeWordTranscriber(),
        injector=_FailingInjector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    daemon.handle_command("start")
    daemon.handle_command("stop")
    daemon._executor.shutdown(wait=True)  # noqa: SLF001

    # The history record for the failed injection is still written, so the
    # tray must reflect it too — not just successful dictations.
    assert tray.calls[-1] == (
        "update",
        "1 min · 💬 3",
        ["Ten tydzień: 1 min · 3 słów", "Ten miesiąc: 1 min · 3 słów", "Ten rok: 1 min · 3 słów"],
    )


def test_cleanup_stops_the_tray(tmp_path: Path) -> None:
    tray = _Tray()
    daemon = VoiceflowDaemon(
        Config(),
        recorder=_Recorder(tmp_path / "recording.wav"),
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=_Overlay(),  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        tray=tray,  # type: ignore[arg-type]
    )

    daemon._cleanup(None)  # noqa: SLF001

    assert tray.calls[-1] == ("stop", None, None)
