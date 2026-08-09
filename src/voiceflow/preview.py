"""Live preview of what the recognizer hears while the user is still speaking.

The preview is informational only. The text actually injected comes from a
single final pass over the whole recording, so the preview is free to change
its mind between updates — no agreement policy is needed or wanted here.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from pathlib import Path

import numpy as np

from voiceflow.config import PreviewConfig

LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
#: Canonical size of the RIFF header pw-record writes before any PCM data.
WAV_HEADER_BYTES = 44
#: Whisper needs some signal to say anything useful about it.
MIN_PREVIEW_SECONDS = 0.4


def read_tail_pcm(
    path: Path,
    *,
    window_seconds: float,
    sample_rate: int = SAMPLE_RATE,
) -> np.ndarray:
    """Read the most recent audio from a WAV file that is still being written.

    ``wave`` cannot open a growing file because its header still advertises a
    zero-length payload, so the raw PCM after the header is read directly.
    """
    window_bytes = int(window_seconds * sample_rate) * BYTES_PER_SAMPLE
    with path.open("rb") as handle:
        handle.seek(0, 2)
        end = handle.tell()
        payload = max(end - WAV_HEADER_BYTES, 0)
        if payload <= 0:
            return np.empty(0, dtype=np.float32)
        start = WAV_HEADER_BYTES + max(payload - window_bytes, 0)
        # Never start mid-sample, or every frame would be byte-swapped noise.
        start -= (start - WAV_HEADER_BYTES) % BYTES_PER_SAMPLE
        handle.seek(start)
        raw = handle.read(end - start)
    # A concurrent write can leave a half-written sample at the tail.
    usable = len(raw) - (len(raw) % BYTES_PER_SAMPLE)
    if usable <= 0:
        return np.empty(0, dtype=np.float32)
    samples = np.frombuffer(raw[:usable], dtype="<i2")
    return samples.astype(np.float32) / 32768.0


def format_preview(text: str, max_chars: int) -> str:
    """Trim a preview to its tail, which is the part the user just spoke."""
    collapsed = " ".join(text.split())
    if max_chars <= 0 or len(collapsed) <= max_chars:
        return collapsed
    return "…" + collapsed[-max_chars:]


class PreviewLoop:
    """Periodically transcribe the audio recorded so far and display it.

    Knows nothing about recorders, models, or notifications: the daemon injects
    the callables. That keeps this loop testable without a GPU or a microphone.
    """

    def __init__(
        self,
        audio_path: Path,
        config: PreviewConfig,
        transcribe: Callable[[np.ndarray], str | None],
        display: Callable[[str], None],
    ) -> None:
        self.audio_path = audio_path
        self.config = config
        self._transcribe = transcribe
        self._display = display
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_shown = ""

    def start(self) -> None:
        """Begin previewing in a background thread."""
        if not self.config.enabled:
            return
        if self._thread is not None:
            raise RuntimeError("Podgląd już działa")
        self._stop.clear()
        thread = threading.Thread(target=self._run, name="voiceflow-preview", daemon=True)
        self._thread = thread
        thread.start()

    def request_stop(self) -> None:
        """Ask the loop to end without waiting for it.

        Called from the socket handler so pressing the hotkey stays instant; the
        worker thread does the blocking join afterwards.
        """
        self._stop.set()

    def stop(self, *, timeout: float = 2.0) -> None:
        """Signal the loop to end and wait briefly for the thread to finish."""
        self._stop.set()
        thread = self._thread
        self._thread = None
        if thread is not None and thread.is_alive():
            thread.join(timeout=timeout)
            if thread.is_alive():
                LOGGER.warning("Wątek podglądu nie zakończył się w %.1f s", timeout)

    def _run(self) -> None:
        while not self._stop.wait(self.config.interval_seconds):
            try:
                self._tick()
            except Exception:
                # A broken preview must never take the recording down with it.
                LOGGER.exception("Cykl podglądu nie powiódł się; kontynuuję")

    def _tick(self) -> None:
        try:
            audio = read_tail_pcm(self.audio_path, window_seconds=self.config.window_seconds)
        except OSError as exc:
            LOGGER.debug("Nie można odczytać nagrania do podglądu: %s", exc)
            return
        if audio.size < MIN_PREVIEW_SECONDS * SAMPLE_RATE:
            return
        text = self._transcribe(audio)
        if self._stop.is_set() or not text:
            return
        shown = format_preview(text, self.config.max_chars)
        if shown and shown != self._last_shown:
            self._last_shown = shown
            self._display(shown)
