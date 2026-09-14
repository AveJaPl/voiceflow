"""Transcribing a dictation while it is still being spoken.

The wait a dictation tool is judged by is the one after the hotkey is released,
and until now that wait was the whole recording: nothing was transcribed before
the user stopped talking. Yet a dictation is not one indivisible utterance — it
is sentences with pauses between them, and a sentence that has been over for a
second is never going to change. So it is transcribed there and then, and what
remains at the end is the tail after the last pause: a second or two of audio
instead of twenty.

Cutting at a pause is what makes this cost nothing in quality. Whisper is asked
for each stretch with ``condition_on_previous_text=False`` already — every
segment is decoded on its own audio and nothing else — so a recording split at
silence decodes to the same words as the recording whole. The only thing that
must never happen is a cut through the middle of a word, which is why the split
is looked for in the *silence between* speech the VAD found, never in the
speech itself, and why the cut keeps a margin past the last word (see
``MARGIN_SECONDS``, which was not guessed).

How *big* a piece is not a matter of taste either, and it is the one number
that decides whether any of this helps. Whisper's encoder always processes a
30-second window, however little audio is in it: on an i7-1260P, decoding 6 s
of speech costs 7.6 s and decoding 29 s costs 11.8 s. Committing every few
seconds therefore does not divide the work between the pauses — it multiplies
it, and the first version of this module made the wait *longer* than one pass
did. A piece is worth committing only when it is nearly a window's worth of
audio, and a dictation shorter than that is transcribed in one pass exactly as
it always was. What this buys is a wait that no longer grows with how much was
said: a minute of dictation is one window behind at the end rather than two.

Nothing here is Windows- or Linux-specific: both recorders write the same 16 kHz
mono PCM, and both platforms wait for the same reason.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable, Sequence
from pathlib import Path

import numpy as np

from voiceflow.config import IncrementalConfig, PreviewConfig
from voiceflow.pcm import SAMPLE_RATE, read_range, read_tail
from voiceflow.preview import format_preview

LOGGER = logging.getLogger(__name__)

#: How much silence to keep after the last word of a committed piece.
#:
#: Measured the hard way. At 0.15 s a rehearsal turned "zbliżającym" into "zbli
#: za jacym": the VAD ends a stretch of speech where the *energy* stops, which
#: is a little before the word does, and the piece that followed began inside
#: it. Four tenths of a second is past the end of any word, and it costs
#: nothing — the audio is transcribed either way, only on which side of the cut
#: is at stake.
MARGIN_SECONDS = 0.4

#: Whisper needs some signal to say anything useful about it.
MIN_PREVIEW_SECONDS = 0.4


def split_point(
    speech: Sequence[tuple[int, int]],
    total: int,
    *,
    min_chunk: int,
    min_silence: int,
    margin: int,
) -> int | None:
    """Where can this buffer be cut without cutting through speech?

    ``speech`` is the sample ranges the VAD found, relative to the start of the
    buffer. A cut is allowed just after a stretch of speech that is followed by
    at least ``min_silence`` of quiet — the pause between two sentences, or the
    one before the user carries on. The *last* such place wins: committing as
    much as possible is the entire point, and what is left over is what the
    user will wait for.

    Returns ``None`` when there is nothing safe to cut yet, which is the normal
    answer for most of a dictation and always the answer for a short one.
    """
    if not speech or total <= 0:
        return None
    best: int | None = None
    for index, (_start, end) in enumerate(speech):
        # The quiet after this stretch runs to the next one, or to the end of
        # what has been recorded so far.
        quiet_ends = speech[index + 1][0] if index + 1 < len(speech) else total
        if quiet_ends - end < min_silence:
            continue
        cut = min(end + margin, quiet_ends, total)
        if cut >= min_chunk:
            best = cut
    return best


def join_text(parts: "Sequence[str]") -> str:
    """Glue transcribed pieces into one line, ignoring the empty ones."""
    return " ".join(part.strip() for part in parts if part and part.strip()).strip()


def detect_speech(audio: np.ndarray, *, min_silence_seconds: float) -> list[tuple[int, int]]:
    """Speech ranges in a buffer, from the same VAD the final pass uses.

    ``speech_pad_ms=0`` because the padding exists to give the decoder room and
    would only blur the boundary this module is looking for; the margin is added
    deliberately at the cut instead.
    """
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    options = VadOptions(
        min_silence_duration_ms=int(min_silence_seconds * 1000),
        speech_pad_ms=0,
    )
    found = get_speech_timestamps(audio, options, sampling_rate=SAMPLE_RATE)
    return [(int(item["start"]), int(item["end"])) for item in found]


class Committer:
    """The part of a dictation that is already transcribed for good.

    Safe to ask from any thread: the daemon reads the text from the worker that
    finishes the recording, while the loop below is still writing to it.
    """

    def __init__(
        self,
        audio_path: Path,
        config: IncrementalConfig,
        transcribe: Callable[[np.ndarray], str],
        speech: Callable[[np.ndarray], list[tuple[int, int]]] | None = None,
    ) -> None:
        self.audio_path = audio_path
        self.config = config
        self._transcribe = transcribe
        self._speech = speech or (
            lambda audio: detect_speech(audio, min_silence_seconds=config.min_silence_seconds)
        )
        self._lock = threading.Lock()
        self._committed = 0
        self._texts: list[str] = []

    @property
    def committed_samples(self) -> int:
        """Where the audio that still needs transcribing begins."""
        with self._lock:
            return self._committed

    @property
    def text(self) -> str:
        with self._lock:
            return join_text(self._texts)

    def try_commit(self) -> bool:
        """Transcribe one finished piece, if the user has left one behind."""
        start = self.committed_samples
        audio = read_range(self.audio_path, start)
        if audio.size < self.config.min_chunk_seconds * SAMPLE_RATE:
            return False
        cut = split_point(
            self._speech(audio),
            audio.size,
            min_chunk=int(self.config.min_chunk_seconds * SAMPLE_RATE),
            min_silence=int(self.config.min_silence_seconds * SAMPLE_RATE),
            margin=int(MARGIN_SECONDS * SAMPLE_RATE),
        )
        if cut is None:
            return False
        text = self._transcribe(audio[:cut])
        with self._lock:
            # Advance even when the piece transcribed to nothing: it was silence
            # or a false start, and re-reading it every second would be the one
            # way to make a dictation slower than not doing this at all.
            self._committed = start + cut
            if text and text.strip():
                self._texts.append(text.strip())
        LOGGER.info(
            "Domknięto %.1f s dyktowania w trakcie mówienia (łącznie %.1f s)",
            cut / SAMPLE_RATE,
            (start + cut) / SAMPLE_RATE,
        )
        return True


class DictationLoop:
    """Everything that happens on a timer while the user is still speaking.

    Two jobs, one thread, in this order: commit what is finished, then preview
    what is not. One thread because both talk to the same model — a second one
    would spend its life waiting for the first — and commits go first because a
    preview is a nicety while a commit is the reason the text arrives quickly.

    Knows nothing about recorders, models or overlays: the daemon injects the
    callables, which is what keeps this testable without a GPU or a microphone.
    """

    def __init__(
        self,
        audio_path: Path,
        config: PreviewConfig,
        transcribe: Callable[[np.ndarray], str | None],
        display: Callable[[str], None],
        committer: Committer | None = None,
    ) -> None:
        self.audio_path = audio_path
        self.config = config
        self._transcribe = transcribe
        self._display = display
        self._committer = committer
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_shown = ""

    @property
    def previews(self) -> bool:
        return self.config.enabled

    def start(self) -> None:
        """Begin working in a background thread, if there is any work to do."""
        if not self.config.enabled and self._committer is None:
            return
        if self._thread is not None:
            raise RuntimeError("Pętla dyktowania już działa")
        self._stop.clear()
        thread = threading.Thread(target=self._run, name="voiceflow-dictation", daemon=True)
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
                LOGGER.warning("Wątek dyktowania nie zakończył się w %.1f s", timeout)

    def _run(self) -> None:
        while not self._stop.wait(self.config.interval_seconds):
            try:
                self._tick()
            except Exception:
                # A broken preview must never take the recording down with it.
                LOGGER.exception("Cykl dyktowania nie powiódł się; kontynuuję")

    def _tick(self) -> None:
        committed, spoken = 0, ""
        if self._committer is not None:
            try:
                self._committer.try_commit()
            except Exception:
                LOGGER.exception("Nie udało się domknąć fragmentu; kontynuuję")
            committed = self._committer.committed_samples
            spoken = self._committer.text
        if not self.config.enabled:
            return
        try:
            audio = read_tail(
                self.audio_path,
                window_seconds=self.config.window_seconds,
                start_sample=committed,
            )
        except OSError as exc:
            LOGGER.debug("Nie można odczytać nagrania do podglądu: %s", exc)
            return
        tail = ""
        if audio.size >= MIN_PREVIEW_SECONDS * SAMPLE_RATE:
            # Only the part nobody has transcribed yet: re-reading the committed
            # audio would cost exactly the CPU the rest of the dictation needs.
            tail = self._transcribe(audio) or ""
        if self._stop.is_set():
            return
        shown = format_preview(join_text([spoken, tail]), self.config.max_chars)
        if shown and shown != self._last_shown:
            self._last_shown = shown
            self._display(shown)
