"""Tests for the live preview loop, its PCM reader, and its text trimming."""

from __future__ import annotations

import struct
import threading
from pathlib import Path

import numpy as np
import pytest

from voiceflow.config import PreviewConfig
from voiceflow.preview import (
    BYTES_PER_SAMPLE,
    SAMPLE_RATE,
    WAV_HEADER_BYTES,
    PreviewLoop,
    format_preview,
    read_tail_pcm,
)


def _write_growing_wav(path: Path, samples: list[int], *, trailing_half_sample: bool = False) -> None:
    """Write a header plus raw PCM, mimicking a file pw-record is still filling."""
    payload = b"".join(struct.pack("<h", value) for value in samples)
    if trailing_half_sample:
        payload += b"\x01"
    path.write_bytes(b"\x00" * WAV_HEADER_BYTES + payload)


def test_reads_samples_and_scales_to_unit_range(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [0, 16384, -32768])

    audio = read_tail_pcm(wav, window_seconds=30)

    assert audio.dtype == np.float32
    assert audio.tolist() == pytest.approx([0.0, 0.5, -1.0])


def test_ignores_half_written_trailing_sample(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000, 2000], trailing_half_sample=True)

    audio = read_tail_pcm(wav, window_seconds=30)

    assert audio.size == 2


def test_header_only_file_yields_no_audio(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [])

    assert read_tail_pcm(wav, window_seconds=30).size == 0


def test_window_keeps_the_most_recent_audio(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    samples = list(range(1000))
    _write_growing_wav(wav, samples)

    window_seconds = 100 / SAMPLE_RATE
    audio = read_tail_pcm(wav, window_seconds=window_seconds)

    assert audio.size == 100
    # The tail, not the head: the last written sample must be present.
    assert audio[-1] == pytest.approx(999 / 32768.0)


def test_window_start_stays_sample_aligned(tmp_path: Path) -> None:
    """An odd byte offset would swap every sample's halves into noise."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [100, 200, 300, 400, 500])

    # A window of 2.5 samples must not begin mid-sample.
    audio = read_tail_pcm(wav, window_seconds=2.5 / SAMPLE_RATE)

    assert audio.size * BYTES_PER_SAMPLE % BYTES_PER_SAMPLE == 0
    assert audio[-1] == pytest.approx(500 / 32768.0)


def test_format_preview_keeps_tail_not_head() -> None:
    assert format_preview("abcdefghij", 4) == "…ghij"


def test_format_preview_collapses_whitespace() -> None:
    assert format_preview("  napisz   mi\nfunkcję ", 100) == "napisz mi funkcję"


def test_format_preview_leaves_short_text_alone() -> None:
    assert format_preview("krótko", 100) == "krótko"


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

    loop = PreviewLoop(wav, _config(), lambda _audio: "napisz mi funkcję", display)
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

    loop = PreviewLoop(wav, _config(), transcribe, lambda _text: None)
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
    loop = PreviewLoop(wav, _config(), transcribe, shown.append)
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

    loop = PreviewLoop(wav, _config(), transcribe, shown.append)
    loop.start()
    assert enough.wait(2.0)
    loop.stop()

    assert shown == ["to samo"]


def test_disabled_preview_never_starts_a_thread(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * SAMPLE_RATE)
    calls: list[int] = []

    loop = PreviewLoop(wav, _config(enabled=False), lambda _a: calls.append(1) or "x", lambda _t: None)
    loop.start()
    loop.stop()

    assert calls == []


def test_silence_shorter_than_minimum_is_not_transcribed(tmp_path: Path) -> None:
    """Too little audio wastes a GPU pass and makes Whisper hallucinate."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1000] * 100)  # ~6 ms
    calls: list[int] = []

    loop = PreviewLoop(wav, _config(), lambda _a: calls.append(1) or "x", lambda _t: None)
    loop.start()
    threading.Event().wait(0.1)
    loop.stop()

    assert calls == []
