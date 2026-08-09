"""Tests for model warmup, which is the last chance to catch a dead GPU."""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

from voiceflow.config import ModelConfig
from voiceflow.transcriber import Transcriber


class _CapturingModel:
    """Records the decode options warmup asks for."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def transcribe(self, _audio: Any, **options: Any) -> tuple[list[Any], None]:
        self.calls.append(options)
        return [], None


def _bare_transcriber(model: _CapturingModel) -> Transcriber:
    """Build a Transcriber without loading a real multi-gigabyte model."""
    transcriber = Transcriber.__new__(Transcriber)
    transcriber.config = ModelConfig()
    transcriber.initial_prompt = None
    transcriber.model = model
    transcriber._lock = threading.Lock()
    return transcriber


def test_warmup_reaches_the_encoder() -> None:
    """Regression: with the VAD on, silent warmup audio was discarded before the
    encoder ran, so a GPU missing cuBLAS/cuDNN warmed up "successfully" and then
    failed on the user's first real dictation — past any chance of falling back."""
    model = _CapturingModel()

    _bare_transcriber(model)._consume_warmup(Path("silence.wav"))

    assert len(model.calls) == 1
    assert model.calls[0]["vad_filter"] is False


def test_real_transcription_still_uses_the_vad() -> None:
    """The VAD is what keeps room noise out of a dictation; only warmup skips it."""
    model = _CapturingModel()
    transcriber = _bare_transcriber(model)

    transcriber.transcribe(Path("missing.wav"))

    assert model.calls[0]["vad_filter"] is True
