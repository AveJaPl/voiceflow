"""Tests for model warmup, which is the last chance to catch a dead GPU."""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

import pytest

from voiceflow.config import ModelConfig
from voiceflow.transcriber import Transcriber, resolve_cpu_threads


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


@pytest.mark.parametrize(
    ("configured", "physical", "logical", "expected"),
    [
        (8, 12, 16, 8),  # written down by hand: obeyed, whatever the machine is
        (0, 12, 16, 12),  # a hybrid laptop: every physical core, no hyperthreads
        (0, None, 16, 8),  # psutil absent (Linux): half the logical count
        (0, None, 4, 4),  # ...but never fewer than CTranslate2 would have taken
        (0, None, 1, 0),  # one core: no arithmetic of ours beats the library's
        (0, None, None, 0),  # nothing knowable: leave the decision to the library
    ],
    ids=["configured", "hybrid-laptop", "no-psutil", "small-machine", "single-core", "unknown"],
)
def test_cpu_threads_follow_the_machine(configured, physical, logical, expected) -> None:
    assert resolve_cpu_threads(configured, physical, logical) == expected
