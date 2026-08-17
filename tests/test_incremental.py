"""Transcribing a dictation while it is still being spoken.

Two things must hold, and everything here is about one of them: a cut never
falls inside speech (or a word is lost, silently, in text the user is about to
paste), and what was committed while they talked is exactly what comes back at
the end — no piece dropped, none counted twice.

The VAD and the model are stubbed. Real speech detection belongs to
faster-whisper; what belongs here is the arithmetic on top of it.
"""

from __future__ import annotations

import struct
import threading
from pathlib import Path

import numpy as np
import pytest

from voiceflow.config import IncrementalConfig, PreviewConfig
from voiceflow.incremental import (
    Committer,
    DictationLoop,
    join_text,
    split_point,
)
from voiceflow.pcm import SAMPLE_RATE, WAV_HEADER_BYTES


def _write_growing_wav(path: Path, samples: list[int]) -> None:
    payload = b"".join(struct.pack("<h", value) for value in samples)
    path.write_bytes(b"\x00" * WAV_HEADER_BYTES + payload)


def _seconds(count: float) -> int:
    return int(count * SAMPLE_RATE)


# -- where to cut ------------------------------------------------------------


_SPLIT = {
    "min_chunk": _seconds(25),
    "min_silence": _seconds(0.7),
    "margin": _seconds(0.4),
}


def test_cuts_in_the_pause_after_a_sentence() -> None:
    speech = [(_seconds(0.2), _seconds(26.0))]

    cut = split_point(speech, _seconds(27.5), **_SPLIT)

    assert cut == _seconds(26.4)  # the last word, plus the margin after it


def test_no_cut_while_the_user_is_still_talking() -> None:
    """Silence that has not lasted long enough is a breath, not a pause."""
    speech = [(_seconds(0.2), _seconds(26.0))]

    assert split_point(speech, _seconds(26.4), **_SPLIT) is None


def test_no_cut_before_the_piece_is_worth_a_decode() -> None:
    """A short piece costs a whole encoder window; committing it loses time."""
    speech = [(_seconds(0.2), _seconds(6.0))]

    assert split_point(speech, _seconds(8.0), **_SPLIT) is None


def test_the_last_usable_pause_wins() -> None:
    """Committing as much as possible is the whole point."""
    speech = [
        (_seconds(0.2), _seconds(26.0)),
        (_seconds(27.0), _seconds(31.0)),
    ]

    cut = split_point(speech, _seconds(33.0), **_SPLIT)

    assert cut == _seconds(31.4)


def test_the_margin_never_reaches_into_the_next_sentence() -> None:
    """A guard, not a working case: today's margin is shorter than any pause.

    It is here because the two numbers are configurable and independent, and
    the day someone sets a margin longer than the silence they require, the cut
    must land on the next word's first sample rather than inside it.
    """
    speech = [
        (_seconds(0.2), _seconds(26.0)),
        (_seconds(26.75), _seconds(29.0)),
    ]

    cut = split_point(
        speech,
        _seconds(29.2),
        min_chunk=_seconds(25),
        min_silence=_seconds(0.7),
        margin=_seconds(2.0),
    )

    assert cut == _seconds(26.75)


def test_silence_alone_offers_nothing_to_cut() -> None:
    assert split_point([], _seconds(60), **_SPLIT) is None


def test_join_text_ignores_the_empty_pieces() -> None:
    assert join_text(["  pierwsze zdanie ", "", None or "", "drugie "]) == (
        "pierwsze zdanie drugie"
    )


# -- committing --------------------------------------------------------------


def _committer(path: Path, transcribe, speech, **overrides) -> Committer:
    config = IncrementalConfig(
        enabled=True,
        min_chunk_seconds=overrides.get("min_chunk_seconds", 25.0),
        min_silence_seconds=overrides.get("min_silence_seconds", 0.7),
    )
    return Committer(path, config, transcribe, speech=speech)


def test_a_finished_sentence_is_transcribed_and_left_behind(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(30))
    committer = _committer(
        wav,
        lambda _audio: "pierwsze zdanie",
        lambda _audio: [(0, _seconds(26.0))],
    )

    assert committer.try_commit() is True
    assert committer.text == "pierwsze zdanie"
    assert committer.committed_samples == _seconds(26.4)


def test_the_next_commit_starts_where_the_last_one_ended(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(70))
    seen: list[int] = []

    def transcribe(audio: np.ndarray) -> str:
        seen.append(audio.size)
        return f"zdanie {len(seen)}"

    committer = _committer(wav, transcribe, lambda _audio: [(0, _seconds(26.0))])

    committer.try_commit()
    committer.try_commit()

    # Each pass sees only audio nobody has transcribed yet.
    assert seen == [_seconds(26.4), _seconds(26.4)]
    assert committer.text == "zdanie 1 zdanie 2"
    assert committer.committed_samples == _seconds(52.8)


def test_nothing_is_committed_from_a_short_dictation(tmp_path: Path) -> None:
    """Under the minimum there is no wait to shorten, so nothing is decoded."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(10))
    calls: list[int] = []
    committer = _committer(
        wav,
        lambda _audio: calls.append(1) or "cokolwiek",
        lambda _audio: [(0, _seconds(8.0))],
    )

    assert committer.try_commit() is False
    assert calls == []
    assert committer.committed_samples == 0


def test_a_piece_that_transcribes_to_nothing_still_moves_on(tmp_path: Path) -> None:
    """Otherwise silence would be re-read, and re-decoded, every single tick."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [0] * _seconds(30))
    committer = _committer(wav, lambda _audio: "   ", lambda _audio: [(0, _seconds(26.0))])

    assert committer.try_commit() is True
    assert committer.text == ""
    assert committer.committed_samples == _seconds(26.4)


# -- the loop ----------------------------------------------------------------


def _config(**overrides: object) -> PreviewConfig:
    values: dict[str, object] = {
        "enabled": True,
        "interval_seconds": 0.01,
        "window_seconds": 30.0,
        "max_chars": 120,
    }
    values.update(overrides)
    return PreviewConfig(**values)  # type: ignore[arg-type]


def test_loop_displays_transcribed_text(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    shown: list[str] = []
    seen = threading.Event()

    def display(text: str) -> None:
        shown.append(text)
        seen.set()

    loop = DictationLoop(wav, _config(), lambda _audio: "napisz mi funkcję", display)
    loop.start()
    assert seen.wait(2.0), "podgląd nie pokazał tekstu"
    loop.stop()

    assert shown[0] == "napisz mi funkcję"


def test_loop_survives_a_failing_transcription(tmp_path: Path) -> None:
    """A broken preview must never take the recording session down with it."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    calls: list[int] = []
    enough = threading.Event()

    def transcribe(_audio: np.ndarray) -> str:
        calls.append(1)
        if len(calls) >= 3:
            enough.set()
        raise RuntimeError("model wybuchł")

    loop = DictationLoop(wav, _config(), transcribe, lambda _text: None)
    loop.start()
    assert enough.wait(2.0), "pętla zatrzymała się po pierwszym błędzie"
    loop.stop()

    assert len(calls) >= 3


def test_loop_skips_when_model_is_busy(tmp_path: Path) -> None:
    """A None result means the final pass holds the model; show nothing."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    calls: list[int] = []
    enough = threading.Event()

    def transcribe(_audio: np.ndarray) -> None:
        calls.append(1)
        if len(calls) >= 2:
            enough.set()
        return None

    shown: list[str] = []
    loop = DictationLoop(wav, _config(), transcribe, shown.append)
    loop.start()
    assert enough.wait(2.0)
    loop.stop()

    assert shown == []


def test_loop_does_not_repeat_identical_text(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    shown: list[str] = []
    calls: list[int] = []
    enough = threading.Event()

    def transcribe(_audio: np.ndarray) -> str:
        calls.append(1)
        if len(calls) >= 4:
            enough.set()
        return "to samo"

    loop = DictationLoop(wav, _config(), transcribe, shown.append)
    loop.start()
    assert enough.wait(2.0)
    loop.stop()

    assert shown == ["to samo"]


def test_silence_shorter_than_minimum_is_not_transcribed(tmp_path: Path) -> None:
    """Too little audio wastes a GPU pass and makes Whisper hallucinate."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * 100)  # ~6 ms
    calls: list[int] = []

    loop = DictationLoop(wav, _config(), lambda _a: calls.append(1) or "x", lambda _t: None)
    loop.start()
    threading.Event().wait(0.1)
    loop.stop()

    assert calls == []


def test_loop_with_nothing_to_do_never_starts_a_thread(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    calls: list[int] = []

    loop = DictationLoop(
        wav, _config(enabled=False), lambda _a: calls.append(1) or "x", lambda _t: None
    )
    loop.start()
    loop.stop()

    assert calls == []


def test_commits_run_even_with_the_preview_switched_off(tmp_path: Path) -> None:
    """The preview is a nicety; committing is what shortens the wait."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(30))
    committed = threading.Event()

    def transcribe_chunk(_audio: np.ndarray) -> str:
        committed.set()
        return "domknięte zdanie"

    committer = _committer(wav, transcribe_chunk, lambda _audio: [(0, _seconds(26.0))])
    previews: list[int] = []
    loop = DictationLoop(
        wav,
        _config(enabled=False),
        lambda _a: previews.append(1) or "podgląd",
        lambda _t: None,
        committer=committer,
    )
    loop.start()
    assert committed.wait(2.0), "nic nie zostało domknięte"
    loop.stop()

    assert committer.text == "domknięte zdanie"
    assert previews == []


def test_the_preview_shows_what_was_already_committed(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(30))
    shown: list[str] = []
    seen = threading.Event()

    def display(text: str) -> None:
        shown.append(text)
        seen.set()

    committer = _committer(
        wav,
        lambda _audio: "pierwsze zdanie",
        lambda _audio: [(0, _seconds(26.0))],
    )
    loop = DictationLoop(
        wav, _config(), lambda _audio: "reszta", display, committer=committer
    )
    loop.start()
    assert seen.wait(2.0), "podgląd nie pokazał tekstu"
    loop.stop()

    # Committed text first, then whatever is being said right now.
    assert shown[-1] == "pierwsze zdanie reszta"


def test_a_failing_commit_does_not_stop_the_preview(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * _seconds(30))
    shown: list[str] = []
    seen = threading.Event()

    def explode(_audio: np.ndarray) -> str:
        raise RuntimeError("model wybuchł")

    committer = _committer(wav, explode, lambda _audio: [(0, _seconds(26.0))])
    loop = DictationLoop(
        wav,
        _config(),
        lambda _audio: "podgląd żyje",
        lambda text: (shown.append(text), seen.set()) and None,
        committer=committer,
    )
    loop.start()
    assert seen.wait(2.0), "podgląd padł razem z domykaniem"
    loop.stop()

    assert shown[0] == "podgląd żyje"
    assert committer.committed_samples == 0
