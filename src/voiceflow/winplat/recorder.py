"""Microphone recording on Windows via PortAudio (the sounddevice package).

Mirrors the Linux ``Recorder`` interface exactly: ``start() -> Path``,
``stop() -> Path``, ``cancel()``, ``cleanup()`` — the daemon composes it the
same way. Audio is written incrementally as raw 16 kHz mono s16 frames so the
live-preview tail reader works unchanged (it reads PCM past the WAV header).
"""

from __future__ import annotations

import logging
import threading
import uuid
import wave
from collections.abc import Callable
from pathlib import Path

from voiceflow.config import AudioConfig

LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16000


class RecorderError(RuntimeError):
    """Raised when recording cannot be started or finalized."""


class WinRecorder:
    """One PortAudio input stream at a time, written straight to a WAV file."""

    def __init__(
        self,
        config: AudioConfig,
        runtime_directory: Path,
        on_max_duration: Callable[[], None] | None = None,
    ) -> None:
        self.config = config
        self.runtime_directory = runtime_directory
        self.on_max_duration = on_max_duration
        self._stream = None
        self._wave: wave.Wave_write | None = None
        self._path: Path | None = None
        self._timer: threading.Timer | None = None
        self._lock = threading.Lock()

    @property
    def is_recording(self) -> bool:
        with self._lock:
            return self._stream is not None

    def start(self) -> Path:
        try:
            import sounddevice  # lazy: Windows-only dependency
        except ImportError as exc:  # pragma: no cover - dependency environment
            raise RecorderError(
                "Brak pakietu sounddevice — uruchom: uv sync"
            ) from exc
        with self._lock:
            if self._stream is not None:
                raise RecorderError("Nagrywanie już trwa")
            self.runtime_directory.mkdir(parents=True, exist_ok=True)
            path = self.runtime_directory / f"recording-{uuid.uuid4().hex}.wav"
            handle = wave.open(str(path), "wb")
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(SAMPLE_RATE)

            def callback(indata, _frames, _time, status) -> None:
                if status:
                    LOGGER.debug("PortAudio status: %s", status)
                # Called from PortAudio's realtime thread. writeframesraw, not
                # writeframes: the latter rewrites the RIFF header on every
                # block, and three extra seeks per 20 ms of audio is exactly the
                # kind of stall that shows up as dropped words. close() patches
                # the header once at the end instead.
                #
                # Nothing may propagate out of here either — an exception on
                # PortAudio's thread takes down the stream, not the caller.
                try:
                    handle.writeframesraw(bytes(indata))
                except Exception:  # noqa: BLE001 - closed mid-callback during stop()
                    pass

            try:
                stream = sounddevice.RawInputStream(
                    samplerate=SAMPLE_RATE,
                    channels=1,
                    dtype="int16",
                    device=self.config.source,
                    callback=callback,
                )
                stream.start()
            except Exception as exc:
                handle.close()
                path.unlink(missing_ok=True)
                raise RecorderError(f"Nie można uruchomić nagrywania: {exc}") from exc
            self._stream = stream
            self._wave = handle
            self._path = path
            self._timer = threading.Timer(self.config.max_seconds, self._limit_reached)
            self._timer.daemon = True
            self._timer.start()
            LOGGER.info("Rozpoczęto nagrywanie do %s", path)
            return path

    def _limit_reached(self) -> None:
        LOGGER.warning("Osiągnięto limit nagrania: %d s", self.config.max_seconds)
        if self.on_max_duration is not None:
            try:
                self.on_max_duration()
            except Exception:
                LOGGER.exception("Błąd obsługi limitu czasu nagrania")

    def stop(self) -> Path:
        with self._lock:
            stream, handle, path, timer = self._stream, self._wave, self._path, self._timer
            if stream is None or handle is None or path is None:
                raise RecorderError("Nagrywanie nie trwa")
            self._stream = self._wave = self._path = self._timer = None
        if timer is not None:
            timer.cancel()
        try:
            stream.stop()
            stream.close()
        finally:
            handle.close()
        if not path.exists() or path.stat().st_size <= 44:
            path.unlink(missing_ok=True)
            raise RecorderError("Nagranie jest puste")
        return path

    def cancel(self) -> None:
        try:
            path = self.stop()
        except RecorderError as exc:
            LOGGER.warning("Anulowanie nagrania: %s", exc)
            return
        path.unlink(missing_ok=True)

    def cleanup(self) -> None:
        if self.is_recording:
            self.cancel()
