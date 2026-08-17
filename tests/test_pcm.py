"""Reading a WAV file that the recorder is still appending to.

Every read here races a realtime audio thread, so the interesting cases are the
awkward ones: a file that has grown since the length was taken, a range that
reaches past the end, a half-written sample at the tail.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest

from voiceflow.pcm import (
    SAMPLE_RATE,
    WAV_HEADER_BYTES,
    read_range,
    read_tail,
    sample_count,
)


def _write_growing_wav(path: Path, samples: list[int], *, trailing_half_sample: bool = False) -> None:
    payload = b"".join(struct.pack("<h", value) for value in samples)
    if trailing_half_sample:
        payload += b"\x01"
    path.write_bytes(b"\x00" * WAV_HEADER_BYTES + payload)


def test_sample_count_ignores_the_header(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [1, 2, 3])

    assert sample_count(wav) == 3


def test_sample_count_of_a_missing_file_is_zero(tmp_path: Path) -> None:
    assert sample_count(tmp_path / "never-recorded.wav") == 0


def test_range_starts_where_it_is_told(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [100, 200, 300, 400])

    audio = read_range(wav, 2)

    assert audio.tolist() == pytest.approx([300 / 32768.0, 400 / 32768.0])


def test_range_can_stop_early(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [100, 200, 300, 400])

    audio = read_range(wav, 1, 3)

    assert audio.tolist() == pytest.approx([200 / 32768.0, 300 / 32768.0])


def test_range_past_the_end_is_empty_not_an_error(tmp_path: Path) -> None:
    """The committed offset can outrun a file the recorder just closed."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [100, 200])

    assert read_range(wav, 5).size == 0
    assert read_range(wav, 2).size == 0


def test_range_ignores_a_half_written_sample(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, [100, 200], trailing_half_sample=True)

    assert read_range(wav, 0).size == 2


def test_tail_never_reaches_before_what_was_committed(tmp_path: Path) -> None:
    """Re-reading committed audio would spend the CPU the tail needs."""
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, list(range(1000)))

    audio = read_tail(wav, window_seconds=1000 / SAMPLE_RATE, start_sample=900)

    assert audio.size == 100
    assert audio[0] == pytest.approx(900 / 32768.0)


def test_tail_keeps_the_most_recent_audio(tmp_path: Path) -> None:
    wav = tmp_path / "recording.wav"
    _write_growing_wav(wav, list(range(1000)))

    audio = read_tail(wav, window_seconds=100 / SAMPLE_RATE)

    assert audio.size == 100
    assert audio[-1] == pytest.approx(999 / 32768.0)
