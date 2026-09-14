"""Tests for the preview's PCM reader and its text trimming.

The loop that drives it moved to :mod:`voiceflow.incremental`, and so did
its tests — what is left here is what preview.py still owns.
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
import pytest

from voiceflow.preview import (
    BYTES_PER_SAMPLE,
    SAMPLE_RATE,
    WAV_HEADER_BYTES,
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
