"""Reading raw samples out of a WAV file that is still being written.

``wave`` cannot open a growing file: its header still advertises a zero-length
payload, so the module reports an empty recording right up until the recorder
closes it. Everything that wants to look at a dictation before it is finished —
the live preview and the incremental transcription — therefore reads the PCM
after the header itself, which is exactly as simple as it sounds because the
recorders on both platforms write 16 kHz mono s16 and nothing else.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
#: Canonical size of the RIFF header the recorders write before any PCM data.
WAV_HEADER_BYTES = 44

_EMPTY = np.empty(0, dtype=np.float32)


def sample_count(path: Path) -> int:
    """How many whole samples are in the file right now."""
    try:
        payload = max(path.stat().st_size - WAV_HEADER_BYTES, 0)
    except OSError:
        return 0
    return payload // BYTES_PER_SAMPLE


def read_range(path: Path, start_sample: int = 0, end_sample: int | None = None) -> np.ndarray:
    """Samples ``[start_sample, end_sample)`` as floats in −1..1.

    A short read is normal rather than exceptional: the recorder appends from
    PortAudio's realtime thread while this runs, so the file grows between the
    seek and the read and can end mid-sample.
    """
    if start_sample < 0:
        start_sample = 0
    with path.open("rb") as handle:
        handle.seek(0, 2)
        available = max(handle.tell() - WAV_HEADER_BYTES, 0) // BYTES_PER_SAMPLE
        last = available if end_sample is None else min(end_sample, available)
        if last <= start_sample:
            return _EMPTY
        handle.seek(WAV_HEADER_BYTES + start_sample * BYTES_PER_SAMPLE)
        raw = handle.read((last - start_sample) * BYTES_PER_SAMPLE)
    usable = len(raw) - (len(raw) % BYTES_PER_SAMPLE)
    if usable <= 0:
        return _EMPTY
    return np.frombuffer(raw[:usable], dtype="<i2").astype(np.float32) / 32768.0


def read_tail(
    path: Path,
    *,
    window_seconds: float,
    start_sample: int = 0,
    sample_rate: int = SAMPLE_RATE,
) -> np.ndarray:
    """The most recent ``window_seconds``, never reaching before ``start_sample``.

    ``start_sample`` is where the uncommitted audio begins: once a stretch has
    been transcribed for good, previewing it again would only spend the CPU the
    rest of the dictation needs.
    """
    total = sample_count(path)
    window = int(window_seconds * sample_rate)
    return read_range(path, max(start_sample, total - window))
