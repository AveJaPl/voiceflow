"""Persistent Whisper daemon and its Unix socket state machine."""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import socketserver
import threading
from concurrent.futures import ThreadPoolExecutor
from enum import StrEnum
from pathlib import Path
from typing import Any, Protocol

from voiceflow.config import Config
from voiceflow.history import History, Record
from voiceflow.injector import InjectionResult, Injector
from voiceflow.micmute import MicMuter
from voiceflow.notifier import Notifier
from voiceflow.overlay import Overlay
from voiceflow.paths import daemon_socket_path, runtime_dir
from voiceflow.presence import DiscordPresence
from voiceflow.preview import PreviewLoop
from voiceflow.recorder import Recorder
from voiceflow.transcriber import Transcriber, TranscriptionResult

_WINDOWS = os.name == "nt"

LOGGER = logging.getLogger(__name__)


class State(StrEnum):
    """Daemon recording pipeline states."""

    IDLE = "IDLE"
    RECORDING = "RECORDING"
    TRANSCRIBING = "TRANSCRIBING"


class RecorderLike(Protocol):
    """Recorder interface used for dependency injection in tests."""

    def start(self) -> Path: ...
    def stop(self) -> Path: ...
    def cancel(self) -> None: ...
    def cleanup(self) -> None: ...


class TranscriberLike(Protocol):
    """Transcriber interface used by the daemon."""

    device: str
    compute_type: str
    def transcribe(self, audio_path: Path) -> TranscriptionResult: ...
    def transcribe_preview(self, audio: Any) -> str | None: ...


class _RequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        daemon: VoiceflowDaemon = self.server.voiceflow_daemon  # type: ignore[attr-defined]
        raw = self.rfile.readline(65537)
        if len(raw) > 65536:
            response = {"ok": False, "message": "Żądanie jest za duże"}
        else:
            try:
                request = json.loads(raw.decode("utf-8"))
                command = request.get("command") if isinstance(request, dict) else None
                if not isinstance(command, str):
                    raise ValueError("brak pola command")
                response = daemon.handle_command(command)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                response = {"ok": False, "message": f"Nieprawidłowe żądanie: {exc}"}
            except Exception as exc:
                LOGGER.exception("Nieobsłużony błąd żądania")
                response = {"ok": False, "message": f"Błąd demona: {exc}"}
        self.wfile.write(json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n")


class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = False


class VoiceflowDaemon:
    """Coordinate recording, transcription, injection, and notifications."""

    def __init__(
        self,
        config: Config,
        *,
        recorder: RecorderLike | None = None,
        transcriber: TranscriberLike | None = None,
        injector: Injector | None = None,
        notifier: Notifier | None = None,
        overlay: Overlay | None = None,
        history: History | None = None,
    ) -> None:
        self.config = config
        self.state = State.IDLE
        self._lock = threading.RLock()
        self._shutdown_requested = threading.Event()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voiceflow-worker")
        self.notifier = notifier or Notifier(config.notifications)
        if _WINDOWS and overlay is None:
            from voiceflow.winplat.overlay import WinOverlay

            self.overlay = WinOverlay(config.overlay)
        else:
            self.overlay = overlay or Overlay(config.overlay)
        if _WINDOWS:
            from voiceflow.winplat.micmute import WinMicMuter

            self.micmuter = WinMicMuter(config.mute_apps)
        else:
            self.micmuter = MicMuter(config.mute_apps)
        self.history = history or History(config.history)
        self.presence = DiscordPresence(config.presence)
        self.injector = injector or Injector(config.inject)
        if transcriber is None:
            # Refuse a second instance before downloading/loading a large model.
            _remove_stale_socket(daemon_socket_path())
            _remove_orphan_recordings(runtime_dir())
            self.transcriber = Transcriber(config.model)
        else:
            self.transcriber = transcriber
        if _WINDOWS and recorder is None:
            from voiceflow.winplat.recorder import WinRecorder

            self.recorder = WinRecorder(config.audio, runtime_dir(), self._max_duration_reached)
        else:
            self.recorder = recorder or Recorder(
                config.audio, runtime_dir(), self._max_duration_reached
            )
        self._server: _UnixServer | None = None
        self._preview: PreviewLoop | None = None

    def handle_command(self, command: str) -> dict[str, Any]:
        """Apply a protocol command to the daemon state machine."""
        if command == "ping":
            return {"ok": True, "message": "pong", "state": self.state.value}
        if command == "status":
            return self._status()
        if command == "shutdown":
            self._shutdown_requested.set()
            return {"ok": True, "message": "Demon zostanie zatrzymany", "state": self.state.value}
        if command == "cancel":
            return self._cancel()
        if command == "start":
            return self._start()
        if command == "stop":
            return self._stop()
        if command == "toggle":
            with self._lock:
                state = self.state
            if state is State.IDLE:
                return self._start()
            if state is State.RECORDING:
                return self._stop()
            return {"ok": True, "message": "Transkrypcja już trwa; polecenie pominięto", "state": state.value}
        return {"ok": False, "message": f"Nieznane polecenie: {command}", "state": self.state.value}

    def _start(self) -> dict[str, Any]:
        with self._lock:
            if self.state is not State.IDLE:
                return {"ok": False, "message": f"Nie można zacząć w stanie {self.state.value}", "state": self.state.value}
            # Mute the voice chat BEFORE audio starts flowing, or the first
            # word of every dictation leaks to everyone on the call.
            self.micmuter.mute()
            try:
                audio_path = self.recorder.start()
            except Exception as exc:
                LOGGER.exception("Nie można rozpocząć nagrywania")
                self.micmuter.unmute()
                self._fail(str(exc))
                return {"ok": False, "message": str(exc), "state": self.state.value}
            self.state = State.RECORDING
        # The overlay is the status surface: a dot that is visibly on while
        # listening answers "is it recording?" in a way a banner never could.
        self.overlay.start("listening")
        self.presence.dictating()
        self._start_preview(audio_path)
        return {"ok": True, "message": "Rozpoczęto nagrywanie", "state": self.state.value}

    def _start_preview(self, audio_path: Path) -> None:
        if not self.config.preview.enabled:
            return
        preview = PreviewLoop(
            audio_path,
            self.config.preview,
            self.transcriber.transcribe_preview,
            lambda text: self.overlay.update("listening", text),
        )
        try:
            preview.start()
        except Exception:
            LOGGER.exception("Nie można uruchomić podglądu; nagrywam bez niego")
            return
        self._preview = preview

    def _stop_preview(self) -> None:
        preview = self._preview
        self._preview = None
        if preview is None:
            return
        try:
            preview.stop()
        except Exception:
            LOGGER.exception("Błąd zatrzymywania podglądu")

    def _stop(self) -> dict[str, Any]:
        with self._lock:
            if self.state is not State.RECORDING:
                return {"ok": False, "message": f"Nagrywanie nie trwa (stan {self.state.value})", "state": self.state.value}
            self.state = State.TRANSCRIBING
        # Signal without joining: the hotkey must feel instant. The worker joins.
        if self._preview is not None:
            self._preview.request_stop()
        try:
            self._executor.submit(self._finish_recording_and_process)
        except RuntimeError as exc:
            with self._lock:
                self.state = State.IDLE
            LOGGER.exception("Nie można uruchomić wątku przetwarzania")
            self._fail(str(exc))
            return {"ok": False, "message": str(exc), "state": self.state.value}
        self.overlay.update("transcribing")
        return {"ok": True, "message": "Zakończono nagrywanie; trwa transkrypcja", "state": self.state.value}

    def _fail(self, message: str) -> None:
        """Report a failure and take the overlay down.

        Errors go to a notification on purpose: it persists in the tray, while
        the overlay is transient by design and would vanish unread.
        """
        self.overlay.stop()
        self.notifier.send(f"❌ Błąd: {message}", urgency="critical")

    def _finish_recording_and_process(self) -> None:
        # Free the model before the final pass so it never queues behind a preview.
        self._stop_preview()
        try:
            audio_path = self.recorder.stop()
        except Exception as exc:
            LOGGER.exception("Nie można zakończyć nagrywania")
            self._fail(f"nagranie: {exc}")
            with self._lock:
                self.state = State.IDLE
            return
        finally:
            # Restore the call as soon as capture ends; transcription can take a
            # moment and the conversation should not stay silenced for it.
            self.micmuter.unmute()
            self.presence.clear()
        self._transcribe_and_inject(audio_path)

    def _cancel(self) -> dict[str, Any]:
        with self._lock:
            if self.state is not State.RECORDING:
                return {"ok": False, "message": "Nie ma nagrania do anulowania", "state": self.state.value}
            self.state = State.IDLE
        self._stop_preview()
        self.micmuter.unmute()
        self.presence.clear()
        try:
            self.recorder.cancel()
        except Exception as exc:
            LOGGER.exception("Błąd anulowania nagrania")
            return {"ok": False, "message": str(exc), "state": self.state.value}
        # The overlay vanishing is the confirmation; a notification would be noise.
        self.overlay.stop()
        return {"ok": True, "message": "Nagranie anulowane", "state": self.state.value}

    def _transcribe_and_inject(self, audio_path: Path) -> None:
        try:
            result = self.transcriber.transcribe(audio_path)
            if not result.text:
                self.notifier.send("Nie rozpoznano mowy")
                LOGGER.info("Transkrypcja jest pusta; pomijam wstrzykiwanie")
                return
            if self._shutdown_requested.is_set():
                LOGGER.info("Demon jest zatrzymywany; pomijam wstrzykiwanie")
                return
            injected = True
            try:
                injection: InjectionResult = self.injector.inject(result.text)
            except Exception:
                injected = False
                raise
            finally:
                # Record even failed injections: the text is exactly what the
                # user needs to recover via `voiceflow last` or the app.
                self.history.append(
                    Record.now(
                        result.text,
                        audio_seconds=result.audio_seconds,
                        transcription_seconds=result.transcription_seconds,
                        injected=injected,
                        store_text=self.config.history.store_text,
                    )
                )
            if injection.fallback_reason:
                LOGGER.info("Wstrzyknięto przez %s: %s", injection.method, injection.fallback_reason)
            # No success notification: the text landing in the focused window is
            # the confirmation, and a banner on every dictation is pure noise.
        except Exception as exc:
            LOGGER.exception("Błąd transkrypcji lub wstrzykiwania")
            self._fail(str(exc))
        finally:
            self.overlay.stop()
            try:
                audio_path.unlink(missing_ok=True)
            except OSError as exc:
                LOGGER.warning("Nie można usunąć pliku %s: %s", audio_path, exc)
            with self._lock:
                self.state = State.IDLE

    def _max_duration_reached(self) -> None:
        LOGGER.warning("Automatycznie kończę nagranie po limicie czasu")
        response = self._stop()
        if not response["ok"]:
            LOGGER.warning("Nie udało się zakończyć nagrania po limicie: %s", response["message"])

    def _status(self) -> dict[str, Any]:
        try:
            probe = self.injector.probe().to_dict()
        except Exception as exc:
            LOGGER.exception("Diagnostyka wstrzykiwania nie powiodła się")
            probe = {"summary": f"Błąd diagnostyki: {exc}"}
        return {
            "ok": True,
            "message": "Demon działa",
            "state": self.state.value,
            "model": self.config.model.name,
            "device": self.transcriber.device,
            "compute_type": self.transcriber.compute_type,
            "injection": probe,
        }

    def run(self) -> None:
        """Serve until shutdown.

        Linux: unix-socket server driven by the thin client and the GNOME
        hotkey. Windows: no client processes — the daemon registers the global
        hotkey itself and idles on an event."""
        if _WINDOWS:
            self._run_windows()
            return
        socket_path = daemon_socket_path()
        _remove_stale_socket(socket_path)
        server = _UnixServer(str(socket_path), _RequestHandler)
        server.voiceflow_daemon = self  # type: ignore[attr-defined]
        server.timeout = 0.25
        os.chmod(socket_path, 0o600)
        self._server = server

        def request_shutdown(signum: int, _frame: object) -> None:
            LOGGER.info("Odebrano sygnał %d; zatrzymuję demona", signum)
            self._shutdown_requested.set()

        previous_sigterm = signal.signal(signal.SIGTERM, request_shutdown)
        previous_sigint = signal.signal(signal.SIGINT, request_shutdown)
        LOGGER.info("Demon nasłuchuje na %s", socket_path)
        try:
            while not self._shutdown_requested.is_set():
                server.handle_request()
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
            signal.signal(signal.SIGINT, previous_sigint)
            self._cleanup(socket_path)

    def _run_windows(self) -> None:  # pragma: no cover - Windows runtime path
        from voiceflow.winplat.hotkey import HotkeyListener

        listener = HotkeyListener(self.config.hotkey.binding, lambda: self.handle_command("toggle"))
        listener.start()

        def request_shutdown(signum: int, _frame: object) -> None:
            LOGGER.info("Odebrano sygnał %d; zatrzymuję demona", signum)
            self._shutdown_requested.set()

        signal.signal(signal.SIGINT, request_shutdown)
        LOGGER.info("voiceflow działa — skrót: %s (Ctrl+C kończy)", self.config.hotkey.binding)
        try:
            while not self._shutdown_requested.wait(0.5):
                pass
        finally:
            listener.stop()
            self._cleanup(None)

    def _cleanup(self, socket_path: Path | None) -> None:
        with self._lock:
            was_recording = self.state is State.RECORDING
            if was_recording:
                self.state = State.IDLE
        self._stop_preview()
        self.overlay.stop()
        # If the daemon dies mid-recording, the call must not stay muted forever.
        self.micmuter.unmute()
        self.presence.clear()
        if was_recording:
            try:
                self.recorder.cleanup()
            except Exception:
                LOGGER.exception("Błąd sprzątania rejestratora")
        if self._server is not None:
            self._server.server_close()
        self._executor.shutdown(wait=True, cancel_futures=True)
        if socket_path is not None:
            try:
                socket_path.unlink(missing_ok=True)
            except OSError as exc:
                LOGGER.warning("Nie można usunąć socketu %s: %s", socket_path, exc)
        LOGGER.info("Demon zatrzymany")


def _remove_stale_socket(path: Path) -> None:
    if not path.exists():
        return
    try:
        response = send_request("ping", socket_path=path, timeout=0.35)
    except (OSError, RuntimeError):
        try:
            path.unlink()
        except OSError as exc:
            raise RuntimeError(f"Nie można usunąć osieroconego socketu {path}: {exc}") from exc
        LOGGER.warning("Usunięto osierocony socket %s", path)
        return
    # Any parseable reply means something is listening. Deleting the socket then
    # would cut off a live daemon, so refuse to start regardless of the ok flag.
    raise RuntimeError(f"Demon voiceflow już działa (socket {path}, odpowiedź: {response})")


def _remove_orphan_recordings(directory: Path) -> None:
    for recording in directory.glob("recording-*.wav"):
        try:
            recording.unlink()
            LOGGER.warning("Usunięto osierocone nagranie %s", recording)
        except OSError as exc:
            LOGGER.warning("Nie można usunąć osieroconego nagrania %s: %s", recording, exc)


def send_request(command: str, *, socket_path: Path | None = None, timeout: float = 1.0) -> dict[str, Any]:
    """Send one JSON-line request and return one JSON-line response."""
    path = socket_path or daemon_socket_path()
    payload = json.dumps({"command": command}, ensure_ascii=False).encode("utf-8") + b"\n"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    raw = b""
    try:
        client.connect(str(path))
        client.sendall(payload)
        with client.makefile("rb") as response_file:
            raw = response_file.readline(65537)
    except OSError as exc:
        raise RuntimeError(f"Demon voiceflow nie odpowiada: {exc}") from exc
    finally:
        client.close()
    if not raw or len(raw) > 65536:
        raise RuntimeError("Demon zwrócił pustą lub zbyt dużą odpowiedź")
    try:
        response = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Demon zwrócił nieprawidłową odpowiedź: {exc}") from exc
    if not isinstance(response, dict):
        raise RuntimeError("Demon zwrócił odpowiedź innego typu niż obiekt JSON")
    return response
