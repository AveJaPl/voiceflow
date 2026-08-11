"""Persistent Whisper daemon and its socket state machine.

The protocol is one JSON line in, one JSON line out, over whichever local
transport the platform offers: a unix socket on Linux, a loopback TCP port
guarded by a shared token on Windows. Everything above the transport — the
state machine, the request handler, the client — is identical on both.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import signal
import socket
import socketserver
import threading
from concurrent.futures import ThreadPoolExecutor
from enum import StrEnum
from pathlib import Path
from typing import Any, Protocol

from voiceflow.config import Config
from voiceflow.history import History, Record, read_records
from voiceflow.injector import InjectionResult, Injector
from voiceflow.micmute import MicMuter
from voiceflow.notifier import NotifierLike, build_notifier
from voiceflow.overlay import Overlay
from voiceflow.paths import daemon_endpoint_path, daemon_socket_path, runtime_dir
from voiceflow.presence import DiscordPresence
from voiceflow.preview import PreviewLoop
from voiceflow.recorder import Recorder
from voiceflow.room import RoomClient
from voiceflow.transcriber import Transcriber, TranscriptionResult
from voiceflow.stats import build_stats, write_stats
from voiceflow.tray import NullTray, Tray, build_payload
from voiceflow.updates import check as check_updates

_WINDOWS = os.name == "nt"

LOGGER = logging.getLogger(__name__)


class DaemonAlreadyRunning(RuntimeError):
    """A live daemon answered the endpoint, so this process must not start one.

    Its own exception type because it is not a failure: on Windows the Start
    Menu entry and the autostart shortcut launch the same command, so clicking
    the icon while voiceflow is already running is the *expected* path and
    deserves a reassuring answer rather than an error."""


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
        expected_token: str | None = getattr(self.server, "voiceflow_token", None)
        raw = self.rfile.readline(65537)
        if len(raw) > 65536:
            response = {"ok": False, "message": "Żądanie jest za duże"}
        else:
            try:
                request = json.loads(raw.decode("utf-8"))
                command = request.get("command") if isinstance(request, dict) else None
                if not isinstance(command, str):
                    raise ValueError("brak pola command")
                if expected_token is not None and not _token_matches(request, expected_token):
                    # Loopback is reachable by every local process; the token is
                    # what keeps one of them from driving somebody's microphone.
                    LOGGER.warning("Odrzucono żądanie bez prawidłowego tokenu")
                    response = {"ok": False, "message": "Nieprawidłowy token dostępu"}
                else:
                    response = daemon.handle_command(command)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                response = {"ok": False, "message": f"Nieprawidłowe żądanie: {exc}"}
            except Exception as exc:
                LOGGER.exception("Nieobsłużony błąd żądania")
                response = {"ok": False, "message": f"Błąd demona: {exc}"}
        self.wfile.write(json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n")


def _token_matches(request: dict[str, Any], expected: str) -> bool:
    supplied = request.get("token")
    return isinstance(supplied, str) and secrets.compare_digest(supplied, expected)


class _TcpServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    """Loopback transport for Windows, where unix sockets do not exist."""

    daemon_threads = True
    allow_reuse_address = False


if hasattr(socketserver, "UnixStreamServer"):

    class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True
        allow_reuse_address = False

else:  # Windows: the loopback server above stands in for it.
    _UnixServer = None  # type: ignore[assignment,misc]


class VoiceflowDaemon:
    """Coordinate recording, transcription, injection, and notifications."""

    def __init__(
        self,
        config: Config,
        *,
        recorder: RecorderLike | None = None,
        transcriber: TranscriberLike | None = None,
        injector: Injector | None = None,
        notifier: NotifierLike | None = None,
        overlay: Overlay | None = None,
        history: History | None = None,
        tray: Tray | None = None,
        micmuter: MicMuter | None = None,
        room: RoomClient | None = None,
    ) -> None:
        self.config = config
        self.state = State.IDLE
        self._lock = threading.RLock()
        self._shutdown_requested = threading.Event()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voiceflow-worker")
        self.notifier = notifier or build_notifier(config.notifications)
        if _WINDOWS and overlay is None:
            from voiceflow.winplat.overlay import WinOverlay

            self.overlay = WinOverlay(config.overlay)
        else:
            self.overlay = overlay or Overlay(config.overlay)
        if micmuter is not None:
            # Injectable like every other collaborator: a test that drives the
            # state machine must not reach the machine's real microphone.
            self.micmuter = micmuter
        elif _WINDOWS:
            from voiceflow.winplat.micmute import WinMicMuter

            self.micmuter = WinMicMuter(config.mute_apps)
        else:
            self.micmuter = MicMuter(config.mute_apps)
        self.history = history or History(config.history)
        # Zdalne ściszanie to DOKŁADNIE ten sam kod, którego używa własny skrót,
        # tylko wyzwolony cudzym zdarzeniem. Najtrudniejsza część — wierne
        # przywracanie głośności wokół strumieni, które znikają — jest już
        # napisana i przetestowana w MicMuter.
        self.room = room or RoomClient(
            config.room,
            on_remote_speaking=lambda _name: self.micmuter.mute(),
            on_remote_silence=self.micmuter.unmute,
        )
        if _WINDOWS and tray is None:
            self.tray = NullTray()
        else:
            self.tray = tray or Tray(config.tray)
        if not _WINDOWS and self.config.tray.enabled:
            self.tray.start()
            self._refresh_tray()
            threading.Thread(
                target=self._tray_refresh_loop, name="voiceflow-tray-refresh", daemon=True
            ).start()
        self.presence = DiscordPresence(config.presence)
        if _WINDOWS and injector is None:
            from voiceflow.winplat.injector import WinInjector

            self.injector = WinInjector(config.inject)
        else:
            self.injector = injector or Injector(config.inject)
        if transcriber is None:
            # Refuse a second instance before downloading/loading a large model.
            _ensure_single_instance()
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
        self._server: socketserver.BaseServer | None = None
        self._hotkey_listener: Any = None
        threading.Thread(
            target=self._announce_update, name="voiceflow-update-check", daemon=True
        ).start()
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
            allowed, blocked_by = self.room.may_start()
            if not allowed:
                # Ktoś inny w pokoju mówi. Karta podaje kto — „nie działa" bez
                # powodu jest gorsze niż brak funkcji. Mikrofon nie rusza.
                message = f"{blocked_by} teraz dyktuje"
                self.overlay.notice(message)
                return {"ok": False, "message": message, "state": self.state.value}
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
        self.room.report_started()
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
        # Set when the overlay has been handed a self-closing message, so the
        # cleanup below does not tear it down before it has been read.
        showed_notice = False
        try:
            result = self.transcriber.transcribe(audio_path)
            if not result.text:
                # Reported on the card rather than as a desktop notification:
                # a silent recording is a non-event, and it should vanish on
                # its own instead of parking a banner in the tray.
                self.overlay.notice("Nie wykryto mowy")
                showed_notice = True
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
                self.room.report_finished(
                    words=len(result.text.split()), seconds=result.audio_seconds
                )
                self.history.append(
                    Record.now(
                        result.text,
                        audio_seconds=result.audio_seconds,
                        transcription_seconds=result.transcription_seconds,
                        injected=injected,
                        store_text=self.config.history.store_text,
                    )
                )
                # Inside this finally so it still runs when inject() raised and
                # the exception is about to propagate past the line below.
                self._refresh_tray()
            if injection.fallback_reason:
                LOGGER.info("Wstrzyknięto przez %s: %s", injection.method, injection.fallback_reason)
            # No success notification: the text landing in the focused window is
            # the confirmation, and a banner on every dictation is pure noise.
        except Exception as exc:
            LOGGER.exception("Błąd transkrypcji lub wstrzykiwania")
            self._fail(str(exc))
        finally:
            if not showed_notice:
                self.overlay.stop()
            try:
                audio_path.unlink(missing_ok=True)
            except OSError as exc:
                LOGGER.warning("Nie można usunąć pliku %s: %s", audio_path, exc)
            with self._lock:
                self.state = State.IDLE

    def _announce_update(self) -> None:
        """Daily background check; a newer release becomes one calm notification."""
        try:
            info = check_updates(self.config.updates)
        except Exception:
            LOGGER.exception("Sprawdzenie aktualizacji nie powiodło się")
            return
        if info is not None and info.newer:
            LOGGER.info("Dostępna aktualizacja voiceflow: %s", info.latest)
            self.notifier.send(
                f"Dostępna nowa wersja voiceflow ({info.latest}) — "
                "zaktualizuj tą samą komendą, którą instalowałeś"
            )

    def _refresh_tray(self) -> None:
        try:
            records = read_records(self.history.path)
            payload = build_payload(records)
            self.tray.update(str(payload["label"]), list(payload["summary"]))  # type: ignore[arg-type]
            # Same numbers, second consumer: the GNOME Shell extension draws
            # its charts from this file rather than parsing the history in the
            # shell process. Written from the same pass so the panel and the
            # tray label can never disagree, and placed beside the history it
            # summarizes so a relocated history (tests, XDG overrides) takes
            # its statistics along with it.
            write_stats(build_stats(records), self.history.path.parent / "stats.json")
        except Exception:
            LOGGER.exception("Nie można przeliczyć statystyk wskaźnika")

    def _tray_refresh_loop(self) -> None:
        # Recomputes on a timer (not only after a dictation) so the "today"
        # label actually rolls over to zero at local midnight even if
        # nothing gets dictated right around then.
        while not self._shutdown_requested.wait(300):
            self._refresh_tray()

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
        status = {
            "ok": True,
            "message": "Demon działa",
            "state": self.state.value,
            "model": self.config.model.name,
            "device": self.transcriber.device,
            "compute_type": self.transcriber.compute_type,
            "injection": probe,
        }
        if _WINDOWS:
            # The daemon owns the shortcut here, so it is the only place that
            # can answer "which key am I actually listening for?".
            status["hotkey"] = self.config.hotkey.binding
            listener = self._hotkey_listener
            if listener is not None and listener.state != "pending":
                # Reporting the configured string alone made a dead shortcut
                # look healthy: the config says ctrl+shift+space, Windows gave
                # it to somebody else, and the dashboard cheerfully told the
                # user to press it. Report what was registered, not what was asked.
                status["hotkey_active"] = listener.state == "active"
                if listener.error:
                    status["hotkey_error"] = listener.error
        return status

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
        """Hotkey listener plus a loopback IPC server.

        Unlike GNOME, Windows has no place to hang a global shortcut outside the
        process, so the daemon registers it itself. The IPC server is what keeps
        ``voiceflow toggle``/``status``/``quit`` working exactly as on Linux."""
        from voiceflow.winplat.hotkey import HotkeyListener

        token = secrets.token_hex(16)
        server = _TcpServer(("127.0.0.1", 0), _RequestHandler)
        server.voiceflow_daemon = self  # type: ignore[attr-defined]
        server.voiceflow_token = token  # type: ignore[attr-defined]
        self._server = server
        endpoint = daemon_endpoint_path()
        _write_endpoint(endpoint, server.server_address[1], token)
        threading.Thread(target=server.serve_forever, name="voiceflow-ipc", daemon=True).start()

        listener = HotkeyListener(
            self.config.hotkey.binding,
            lambda: self.handle_command("toggle"),
            on_error=lambda message: self.notifier.send(f"❌ {message}", urgency="critical"),
        )
        self._hotkey_listener = listener
        listener.start()

        def request_shutdown(signum: int, _frame: object) -> None:
            LOGGER.info("Odebrano sygnał %d; zatrzymuję demona", signum)
            self._shutdown_requested.set()

        signal.signal(signal.SIGINT, request_shutdown)
        LOGGER.info(
            "voiceflow działa — skrót: %s, IPC na porcie %d",
            self.config.hotkey.binding,
            server.server_address[1],
        )
        try:
            while not self._shutdown_requested.wait(0.5):
                pass
        finally:
            listener.stop()
            server.shutdown()
            self._cleanup(endpoint)

    def _cleanup(self, socket_path: Path | None) -> None:
        with self._lock:
            was_recording = self.state is State.RECORDING
            if was_recording:
                self.state = State.IDLE
        self._stop_preview()
        self.overlay.stop()
        self.tray.stop()
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


def _ensure_single_instance() -> None:
    """Refuse to start when another daemon is already answering.

    Two daemons means two copies of a multi-gigabyte model in RAM and a hotkey
    that silently belongs to whichever won the race — worth a hard stop. On
    Windows this matters more than on Linux: the Start Menu entry and the
    autostart shortcut both launch the same thing, so a second instance is one
    stray double-click away."""
    _remove_stale_endpoint(daemon_endpoint_path() if _WINDOWS else daemon_socket_path())


def _remove_stale_endpoint(path: Path) -> None:
    if not path.exists():
        return
    try:
        response = send_request("ping", socket_path=path, timeout=0.35)
    except (OSError, RuntimeError):
        try:
            path.unlink()
        except OSError as exc:
            raise RuntimeError(f"Nie można usunąć osieroconego pliku {path}: {exc}") from exc
        LOGGER.warning("Usunięto osierocony punkt kontaktu %s", path)
        return
    # Any parseable reply means something is listening. Deleting the endpoint
    # then would cut off a live daemon, so refuse to start regardless of `ok`.
    raise DaemonAlreadyRunning(
        f"Demon voiceflow już działa ({path}, odpowiedź: {response})"
    )


#: Kept as the historical name; Linux callers and tests reach for this one.
_remove_stale_socket = _remove_stale_endpoint


def _write_endpoint(path: Path, port: int, token: str) -> None:
    path.write_text(json.dumps({"port": port, "token": token}), encoding="utf-8")


def _read_endpoint(path: Path) -> tuple[int, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return int(data["port"]), str(data["token"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise RuntimeError(
            f"Demon voiceflow nie działa (brak lub uszkodzony {path}): {exc}"
        ) from exc


def _remove_orphan_recordings(directory: Path) -> None:
    for recording in directory.glob("recording-*.wav"):
        try:
            recording.unlink()
            LOGGER.warning("Usunięto osierocone nagranie %s", recording)
        except OSError as exc:
            LOGGER.warning("Nie można usunąć osieroconego nagrania %s: %s", recording, exc)


def send_request(command: str, *, socket_path: Path | None = None, timeout: float = 1.0) -> dict[str, Any]:
    """Send one JSON-line request and return one JSON-line response."""
    request: dict[str, Any] = {"command": command}
    if _WINDOWS:
        path = socket_path or daemon_endpoint_path()
        port, token = _read_endpoint(path)
        request["token"] = token
        family: int = socket.AF_INET
        address: Any = ("127.0.0.1", port)
    else:
        path = socket_path or daemon_socket_path()
        family = socket.AF_UNIX
        address = str(path)
    payload = json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"
    client = socket.socket(family, socket.SOCK_STREAM)
    client.settimeout(timeout)
    raw = b""
    try:
        client.connect(address)
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
