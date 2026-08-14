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


# --- halucynacje pożegnań ---------------------------------------------------
#
# Whisper uczony na napisach z YouTube'a „kończy odcinek", gdy nagranie kończy
# się ciszą albo oddechem: dopisuje „Dziękuję.", „Dziękuję za oglądanie."
# i podobne, choć nikt nic takiego nie powiedział (zgłoszenie Filipa
# 2026-08-14). Wycinamy TYLKO znane frazy, TYLKO z końca i TYLKO wtedy, gdy
# metadane segmentu zdradzają zmyślenie — prawdziwe „dziękuję" ma zostać.

from types import SimpleNamespace

from voiceflow.transcriber import drop_trailing_hallucinations


def _segment(text, no_speech=0.05, logprob=-0.2):
    return SimpleNamespace(text=text, no_speech_prob=no_speech, avg_logprob=logprob)


def test_farewell_glued_to_silence_is_dropped() -> None:
    segments = [
        _segment(" Zrefaktoruj moduł autoryzacji."),
        _segment(" Dziękuję za oglądanie.", no_speech=0.82, logprob=-0.9),
    ]

    kept = drop_trailing_hallucinations(segments)

    assert [s.text for s in kept] == [" Zrefaktoruj moduł autoryzacji."]


def test_genuinely_spoken_thanks_survives() -> None:
    """Ktoś naprawdę kończy „dziękuję" — pewny segment nie jest ruszany."""
    segments = [
        _segment(" Popraw literówkę."),
        _segment(" Dziękuję.", no_speech=0.04, logprob=-0.15),
    ]

    assert drop_trailing_hallucinations(segments) == segments


def test_stacked_farewells_fall_one_after_another() -> None:
    segments = [
        _segment(" Dodaj testy."),
        _segment(" Dziękuję.", no_speech=0.7, logprob=-0.8),
        _segment(" Dziękuję za oglądanie!", no_speech=0.9, logprob=-1.1),
    ]

    kept = drop_trailing_hallucinations(segments)

    assert [s.text for s in kept] == [" Dodaj testy."]


def test_unknown_text_is_never_dropped_even_with_bad_metadata() -> None:
    """Tniemy wyłącznie znane frazy: niepewność modelu przy zwykłym zdaniu
    to nie powód, żeby wyrzucać czyjeś słowa."""
    segments = [_segment(" Wdróż to na produkcję.", no_speech=0.9, logprob=-1.5)]

    assert drop_trailing_hallucinations(segments) == segments


def test_farewell_in_the_middle_is_not_touched() -> None:
    segments = [
        _segment(" Dziękuję za oglądanie.", no_speech=0.9, logprob=-1.2),
        _segment(" A teraz do rzeczy."),
    ]

    assert drop_trailing_hallucinations(segments) == segments


def test_recording_of_pure_silence_ends_up_empty() -> None:
    segments = [_segment(" Dziękuję za oglądanie.", no_speech=0.95, logprob=-1.3)]

    assert drop_trailing_hallucinations(segments) == []


def test_transcribe_applies_the_filter() -> None:
    class _Model:
        def transcribe(self, _audio, **_options):
            return iter([
                _segment(" Napisz maila do klienta."),
                _segment(" Dziękuję za oglądanie.", no_speech=0.8, logprob=-1.0),
            ]), None

    transcriber = _bare_transcriber(_Model())

    result = transcriber.transcribe(Path("missing.wav"))

    assert result.text == "Napisz maila do klienta."
