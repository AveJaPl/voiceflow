"""Live preview of what the recognizer hears while the user is still speaking.

The preview is informational only. The text actually injected is assembled from
full-quality passes — the pieces committed during the pauses plus the final tail
— so the preview is free to change its mind between updates and no agreement
policy is needed or wanted here.

The loop that drives it lives in :mod:`voiceflow.incremental`, because on the
same timer it does the work that actually shortens the wait; what is left here
is how a preview is read off disk and how it is shown.
"""

from __future__ import annotations

import logging
from pathlib import Path

import numpy as np

from voiceflow.pcm import BYTES_PER_SAMPLE, SAMPLE_RATE, WAV_HEADER_BYTES, read_tail

LOGGER = logging.getLogger(__name__)

__all__ = [
    "BYTES_PER_SAMPLE",
    "MIN_PREVIEW_SECONDS",
    "SAMPLE_RATE",
    "WAV_HEADER_BYTES",
    "format_preview",
    "read_tail_pcm",
]

#: Whisper needs some signal to say anything useful about it.
MIN_PREVIEW_SECONDS = 0.4


def read_tail_pcm(
    path: Path,
    *,
    window_seconds: float,
    sample_rate: int = SAMPLE_RATE,
) -> np.ndarray:
    """The most recent audio from a WAV file that is still being written."""
    return read_tail(path, window_seconds=window_seconds, sample_rate=sample_rate)


def format_preview(text: str, max_chars: int) -> str:
    """Trim a preview to its tail, which is the part the user just spoke."""
    collapsed = " ".join(text.split())
    if max_chars <= 0 or len(collapsed) <= max_chars:
        return collapsed
    return "…" + collapsed[-max_chars:]
