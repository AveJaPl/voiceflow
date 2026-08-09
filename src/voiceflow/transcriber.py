"""faster-whisper model lifecycle and transcription."""

from __future__ import annotations

import ctypes
import importlib.util
import logging
import tempfile
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import numpy as np

from voiceflow.config import ModelConfig

LOGGER = logging.getLogger(__name__)

#: Whisper's decoder reserves half its 448-token context for the bias prompt. Long
#: prompts crowd out the audio and start leaking into the transcript, so the
#: vocabulary is capped well below that. Roughly 4 characters per token.
MAX_PROMPT_CHARS = 600


def build_initial_prompt(vocabulary: tuple[str, ...]) -> str | None:
    """Turn a vocabulary list into a decoding bias prompt, or None if empty.

    Duplicates are dropped and order preserved so the config reads as written.
    Terms past the length cap are dropped rather than truncated mid-word, which
    would bias the model towards a word fragment that does not exist.
    """
    seen: set[str] = set()
    kept: list[str] = []
    length = 0
    dropped = 0
    for term in vocabulary:
        lowered = term.casefold()
        if lowered in seen:
            continue
        addition = len(term) + 2  # the ", " separator
        if length + addition > MAX_PROMPT_CHARS:
            dropped += 1
            continue
        seen.add(lowered)
        kept.append(term)
        length += addition
    if dropped:
        LOGGER.warning(
            "Słownik przekracza %d znaków; pomijam %d ostatnich terminów",
            MAX_PROMPT_CHARS,
            dropped,
        )
    if not kept:
        return None
    return ", ".join(kept) + "."


@dataclass(frozen=True, slots=True)
class TranscriptionResult:
    """Text and performance metadata returned by the recognizer."""

    text: str
    language: str | None
    audio_seconds: float
    transcription_seconds: float


class Transcriber:
    """Keep one Whisper model loaded and ready for repeated requests."""

    def __init__(self, config: ModelConfig) -> None:
        self.config = config
        self.model: Any = None
        self.device = ""
        self.compute_type = ""
        self.load_seconds = 0.0
        self.warmup_seconds = 0.0
        # One model, two callers: the final pass and the live preview. The final
        # pass must never queue behind a preview, so previews yield instead.
        self._lock = threading.Lock()
        self.initial_prompt = build_initial_prompt(config.vocabulary)
        if self.initial_prompt:
            LOGGER.info("Słownik nachylający dekodowanie: %s", self.initial_prompt)
        self._load_model()
        self._warmup()

    def _load_model(self) -> None:
        requested_device = "cuda" if self.config.device == "auto" else self.config.device
        if requested_device == "cuda":
            _preload_pip_cuda_libraries()
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise RuntimeError("Brak faster-whisper. Uruchom: uv sync") from exc

        requested_compute = self.config.compute_type
        if requested_device == "cpu" and requested_compute == "float16":
            requested_compute = "int8"
            LOGGER.warning("float16 nie jest obsługiwane na CPU; używam int8")
        started = time.perf_counter()
        try:
            self.model = WhisperModel(
                self.config.name,
                device=requested_device,
                compute_type=requested_compute,
            )
            self.device = requested_device
            self.compute_type = requested_compute
        except Exception as exc:
            if requested_device != "cuda":
                raise RuntimeError(f"Nie można załadować modelu Whisper: {exc}") from exc
            LOGGER.warning(
                "Nie udało się uruchomić modelu na CUDA (%s). Próbuję CPU/int8.",
                exc,
            )
            try:
                self.model = WhisperModel(self.config.name, device="cpu", compute_type="int8")
                self.device = "cpu"
                self.compute_type = "int8"
            except Exception as cpu_exc:
                raise RuntimeError(
                    f"Nie można załadować modelu ani na CUDA ({exc}), ani na CPU ({cpu_exc})"
                ) from cpu_exc
        self.load_seconds = time.perf_counter() - started
        LOGGER.info(
            "Załadowano model %s na %s/%s w %.2f s",
            self.config.name,
            self.device,
            self.compute_type,
            self.load_seconds,
        )

    def _warmup(self) -> None:
        if self.model is None:
            raise RuntimeError("Model Whisper nie został załadowany")
        started = time.perf_counter()
        silence_path: Path | None = None
        cuda_fallback_attempted = False
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
                silence_path = Path(temporary.name)
            with wave.open(str(silence_path), "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(16000)
                wav_file.writeframes(b"\x00\x00" * 8000)
            try:
                self._consume_warmup(silence_path)
            except Exception as exc:
                if self.device != "cuda":
                    raise
                # CUDA libraries and memory allocation are often touched only
                # when the first inference runs, not in WhisperModel.__init__.
                LOGGER.warning(
                    "Warmup CUDA nie powiódł się (%s). Próbuję modelu CPU/int8.",
                    exc,
                )
                cuda_fallback_attempted = True
                from faster_whisper import WhisperModel

                self.model = WhisperModel(self.config.name, device="cpu", compute_type="int8")
                self.device = "cpu"
                self.compute_type = "int8"
                self._consume_warmup(silence_path)
        except Exception as exc:
            if cuda_fallback_attempted:
                raise RuntimeError(f"Nie udało się uruchomić awaryjnego modelu CPU/int8: {exc}") from exc
            LOGGER.warning("Warmup modelu nie powiódł się; kontynuuję: %s", exc)
        finally:
            if silence_path is not None:
                silence_path.unlink(missing_ok=True)
        self.warmup_seconds = time.perf_counter() - started
        LOGGER.info("Warmup modelu zajął %.2f s", self.warmup_seconds)

    def _consume_warmup(self, silence_path: Path) -> None:
        segments, _ = self.model.transcribe(
            str(silence_path),
            language=self.config.language,
            vad_filter=True,
            condition_on_previous_text=False,
            initial_prompt=self.initial_prompt,
            beam_size=self.config.beam_size,
        )
        list(segments)

    def transcribe(self, audio_path: Path) -> TranscriptionResult:
        """Transcribe a WAV file and return stripped text with diagnostics."""
        if self.model is None:
            raise RuntimeError("Model Whisper nie został załadowany")
        audio_seconds = _wav_duration(audio_path)
        started = time.perf_counter()
        with self._lock:
            segments, info = self.model.transcribe(
                str(audio_path),
                language=self.config.language,
                vad_filter=True,
                condition_on_previous_text=False,
                initial_prompt=self.initial_prompt,
                beam_size=self.config.beam_size,
            )
            text = " ".join(segment.text.strip() for segment in segments if segment.text.strip()).strip()
        elapsed = time.perf_counter() - started
        language = getattr(info, "language", self.config.language)
        LOGGER.info(
            "Transkrypcja %.2f s audio zajęła %.2f s (język: %s)",
            audio_seconds,
            elapsed,
            language,
        )
        return TranscriptionResult(text, language, audio_seconds, elapsed)

    def transcribe_preview(self, audio: "np.ndarray") -> str | None:
        """Transcribe raw samples for the live preview, or skip if the model is busy.

        Returns ``None`` when the final pass holds the model: a dropped preview
        frame is invisible, while a queued one would delay the text the user is
        actually waiting for. Uses ``beam_size=1`` because preview quality is
        disposable and latency is not.
        """
        if self.model is None:
            raise RuntimeError("Model Whisper nie został załadowany")
        if not self._lock.acquire(blocking=False):
            LOGGER.debug("Model zajęty; pomijam cykl podglądu")
            return None
        try:
            segments, _ = self.model.transcribe(
                audio,
                language=self.config.language,
                vad_filter=True,
                condition_on_previous_text=False,
                initial_prompt=self.initial_prompt,
                beam_size=1,
            )
            return " ".join(segment.text.strip() for segment in segments if segment.text.strip()).strip()
        finally:
            self._lock.release()


def _wav_duration(path: Path) -> float:
    try:
        with wave.open(str(path), "rb") as wav_file:
            rate = wav_file.getframerate()
            return wav_file.getnframes() / rate if rate else 0.0
    except (OSError, wave.Error) as exc:
        LOGGER.warning("Nie można odczytać czasu WAV %s: %s", path, exc)
        return 0.0


def _preload_pip_cuda_libraries() -> None:
    """Expose pip-installed cuBLAS/cuDNN shared objects to CTranslate2.

    NVIDIA's Python wheels place shared libraries outside the dynamic loader's
    default paths. Loading them globally by absolute path avoids requiring a
    CUDA Toolkit installation or a hand-written ``LD_LIBRARY_PATH``.
    """
    library_paths: list[Path] = []
    for package in ("nvidia.cublas.lib", "nvidia.cudnn.lib"):
        try:
            specification = importlib.util.find_spec(package)
        except (ImportError, ModuleNotFoundError, AttributeError) as exc:
            LOGGER.debug("Nie można znaleźć pakietu %s: %s", package, exc)
            continue
        if specification is None or specification.submodule_search_locations is None:
            continue
        for location in specification.submodule_search_locations:
            library_paths.extend(Path(location).glob("*.so*"))

    def priority(path: Path) -> tuple[int, str]:
        name = path.name
        if "cublasLt" in name:
            return (0, name)
        if name.startswith("libcublas.so"):
            return (1, name)
        if name.startswith("libcudnn.so"):
            return (2, name)
        return (3, name)

    pending = sorted(set(library_paths), key=priority)
    for _attempt in range(2):
        failed: list[Path] = []
        for library in pending:
            try:
                ctypes.CDLL(str(library), mode=ctypes.RTLD_GLOBAL)
            except OSError as exc:
                LOGGER.debug("Nie można wstępnie załadować %s: %s", library, exc)
                failed.append(library)
        if not failed or len(failed) == len(pending):
            break
        pending = failed
