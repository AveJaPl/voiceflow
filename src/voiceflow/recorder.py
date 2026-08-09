"""PipeWire audio recording with safe WAV finalization."""

from __future__ import annotations

import logging
import signal
import subprocess
import tempfile
import threading
import uuid
import wave
from collections.abc import Callable
from pathlib import Path
from typing import IO

from voiceflow.config import AudioConfig

LOGGER = logging.getLogger(__name__)


class RecorderError(RuntimeError):
    """Raised when recording cannot be started or finalized."""


def build_record_command(config: AudioConfig, output: Path) -> list[str]:
    """Build the pw-record command for 16 kHz mono signed 16-bit WAV."""
    command = [
        "pw-record",
        "--rate",
        "16000",
        "--channels",
        "1",
        "--format",
        "s16",
    ]
    if config.source:
        command.extend(["--target", config.source])
    command.append(str(output))
    return command


class Recorder:
    """Manage one pw-record subprocess at a time."""

    def __init__(
        self,
        config: AudioConfig,
        runtime_directory: Path,
        on_max_duration: Callable[[], None] | None = None,
    ) -> None:
        self.config = config
        self.runtime_directory = runtime_directory
        self.on_max_duration = on_max_duration
        self._process: subprocess.Popen[bytes] | None = None
        self._path: Path | None = None
        self._timer: threading.Timer | None = None
        self._stderr: IO[bytes] | None = None
        self._lock = threading.Lock()

    @property
    def is_recording(self) -> bool:
        """Return whether a pw-record process is currently owned."""
        with self._lock:
            return self._process is not None

    def start(self) -> Path:
        """Start recording and return the temporary WAV path."""
        with self._lock:
            if self._process is not None:
                raise RecorderError("Nagrywanie już trwa")
            self.runtime_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            path = self.runtime_directory / f"recording-{uuid.uuid4().hex}.wav"
            command = build_record_command(self.config, path)
            # A pipe would deadlock pw-record if it ever filled the 64 KiB buffer
            # while nobody drains it mid-recording. A temporary file cannot block
            # the writer and still preserves the diagnostics on failure.
            stderr_file: IO[bytes] = tempfile.TemporaryFile()
            try:
                process = subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=stderr_file,
                    shell=False,
                )
            except OSError as exc:
                stderr_file.close()
                raise RecorderError(f"Nie można uruchomić pw-record: {exc}") from exc
            self._process = process
            self._stderr = stderr_file
            self._path = path
            self._timer = threading.Timer(self.config.max_seconds, self._limit_reached)
            self._timer.daemon = True
            self._timer.start()
            LOGGER.info("Rozpoczęto nagrywanie do %s (PID %d)", path, process.pid)
            return path

    def _limit_reached(self) -> None:
        LOGGER.warning("Osiągnięto limit nagrania: %d s", self.config.max_seconds)
        if self.on_max_duration is not None:
            try:
                self.on_max_duration()
            except Exception:
                LOGGER.exception("Błąd obsługi limitu czasu nagrania")

    def stop(self) -> Path:
        """Stop with SIGINT so pw-record can finalize the WAV header."""
        with self._lock:
            process = self._process
            path = self._path
            timer = self._timer
            stderr_file = self._stderr
            if process is None or path is None:
                raise RecorderError("Nagrywanie nie trwa")
            self._process = None
            self._path = None
            self._timer = None
            self._stderr = None
        if timer is not None:
            timer.cancel()
        try:
            self._finish_process(process, stderr_file)
        except RecorderError:
            path.unlink(missing_ok=True)
            raise
        finally:
            if stderr_file is not None:
                stderr_file.close()
        duration = _validate_wav(path)
        if duration is None:
            path.unlink(missing_ok=True)
            raise RecorderError("Nagranie jest puste lub ma nieprawidłowy nagłówek WAV")
        LOGGER.info(
            "Zakończono nagrywanie: %s (%d bajtów, %.2f s)", path, path.stat().st_size, duration
        )
        return path

    @staticmethod
    def _finish_process(
        process: subprocess.Popen[bytes],
        stderr_file: IO[bytes] | None = None,
    ) -> None:
        killed = False
        try:
            process.send_signal(signal.SIGINT)
        except ProcessLookupError:
            LOGGER.warning("Proces pw-record zakończył się przed wysłaniem SIGINT")
        try:
            return_code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            LOGGER.warning("pw-record nie zakończył się po SIGINT; wysyłam SIGKILL")
            killed = True
            process.kill()
            try:
                return_code = process.wait(timeout=2)
            except subprocess.TimeoutExpired as exc:
                raise RecorderError("Nie można zatrzymać procesu pw-record") from exc

        def detail() -> str:
            if stderr_file is None:
                return ""
            try:
                stderr_file.seek(0)
                return stderr_file.read().decode(errors="replace").strip()
            except OSError as exc:
                LOGGER.warning("Nie można odczytać stderr pw-record: %s", exc)
                return ""

        if killed:
            raise RecorderError(
                f"pw-record nie zareagował na SIGINT, więc nagranie jest uszkodzone: {detail()}"
            )
        # Verified on Ubuntu 26.04 / PipeWire: pw-record exits with code 1 after
        # SIGINT and writes only the output filename to stderr, even though the
        # WAV it produced is complete and valid. The exit code is therefore not a
        # usable success signal here — stop() validates the file itself instead.
        if return_code not in (0, 1, -signal.SIGINT):
            LOGGER.warning("pw-record zakończył się kodem %d: %s", return_code, detail())

    def cancel(self) -> None:
        """Stop recording safely and delete the captured audio."""
        try:
            path = self.stop()
        except RecorderError as exc:
            LOGGER.warning("Anulowanie nagrania: %s", exc)
            return
        path.unlink(missing_ok=True)
        LOGGER.info("Anulowano i usunięto nagranie %s", path)

    def cleanup(self) -> None:
        """Cancel a live recording during daemon shutdown."""
        if self.is_recording:
            self.cancel()


def _validate_wav(path: Path) -> float | None:
    """Return the recording length, or None if the file is unusable.

    This is the real success criterion for a stopped recording: pw-record's exit
    code says nothing useful, but a parseable header with frames in it does.
    """
    if not path.exists():
        return None
    try:
        with wave.open(str(path), "rb") as wav_file:
            rate = wav_file.getframerate()
            frames = wav_file.getnframes()
    except (OSError, wave.Error) as exc:
        LOGGER.warning("Nagranie %s nie jest poprawnym WAV: %s", path, exc)
        return None
    if not rate or not frames:
        return None
    return frames / rate
