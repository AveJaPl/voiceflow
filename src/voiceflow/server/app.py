"""Aplikacja FastAPI wystawiająca Whisper voiceflow po HTTP.

Serwer żyje osobno od demona: nie ma mikrofonu, skrótów ani wklejania —
dostaje gotowe nagranie i oddaje tekst. Rozpoznawanie to ten sam
``Transcriber`` co przy dyktowaniu na komputerze, więc słownik, VAD i filtr
halucynacji działają identycznie.
"""

from __future__ import annotations

import hmac
import logging
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from voiceflow.config import ModelConfig

LOGGER = logging.getLogger("voiceflow.server")

MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MAX_AUDIO_SECONDS = 300.0
SAMPLE_RATE = 16_000


class TranscriberLike(Protocol):
    """To, czego serwer potrzebuje od transkrybera (łatwe do podstawienia w testach)."""

    device: str
    compute_type: str
    config: Any

    def transcribe_chunk(self, audio: Any) -> str: ...


@dataclass(frozen=True)
class ServerConfig:
    token: str
    model: ModelConfig
    root_path: str = "/api"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "ServerConfig":
        env = os.environ if env is None else env
        token = env.get("VOICEFLOW_API_TOKEN", "").strip()
        if not token:
            raise RuntimeError(
                "Brak VOICEFLOW_API_TOKEN — serwer bez tokenu byłby otwartym mikrofonem dla całego internetu."
            )
        vocabulary = tuple(
            word.strip() for word in env.get("VOICEFLOW_VOCABULARY", "").split(",") if word.strip()
        )
        language = env.get("VOICEFLOW_LANGUAGE", "pl").strip() or None
        model = ModelConfig(
            name=env.get("VOICEFLOW_MODEL", "large-v3-turbo").strip() or "large-v3-turbo",
            device=env.get("VOICEFLOW_DEVICE", "cpu").strip() or "cpu",
            compute_type=env.get("VOICEFLOW_COMPUTE_TYPE", "int8").strip() or "int8",
            language=None if language in (None, "auto") else language,
            beam_size=int(env.get("VOICEFLOW_BEAM_SIZE", "5") or 5),
            cpu_threads=int(env.get("VOICEFLOW_CPU_THREADS", "0") or 0),
            vocabulary=vocabulary,
        )
        root_path = "/" + env.get("VOICEFLOW_ROOT_PATH", "/api").strip("/")
        return cls(token=token, model=model, root_path="" if root_path == "/" else root_path)


def decode_upload(path: Path) -> Any:
    """Nagranie z przeglądarki (webm/opus, ogg, m4a, wav) → próbki 16 kHz mono.

    PyAV z faster-whisper dekoduje wszystko, co umie ffmpeg, więc serwer nie
    narzuca klientowi formatu; ``Transcriber.transcribe`` wymaga WAV, dlatego
    idziemy przez ``transcribe_chunk`` z gotowymi próbkami.
    """
    from faster_whisper.audio import decode_audio

    return decode_audio(str(path), sampling_rate=SAMPLE_RATE)


def create_app(transcriber: TranscriberLike, config: ServerConfig) -> FastAPI:
    app = FastAPI(title="voiceflow API", root_path=config.root_path, docs_url=None, redoc_url=None)

    def token_ok(request: Request) -> bool:
        header = request.headers.get("authorization", "")
        scheme, _, token = header.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(token.strip(), config.token)

    @app.middleware("http")
    async def brama(request: Request, call_next: Any) -> Any:
        """Obcy request odpada przed odczytem ciała.

        Projekt jest publiczny, więc ścieżka API jest jawna — ochroną jest
        token, a nie sekretny adres. Odrzucamy w middleware, żeby ktoś bez
        tokenu nie kosztował nas ani dekodowania nagrania, ani sekundy CPU:
        ciało wieloczęściowe nie jest nawet czytane. ``/health`` zostaje
        otwarte dla monitoringu, ale zdradza tylko, że serwer żyje.
        """
        if request.url.path.rstrip("/").endswith("/health") or token_ok(request):
            return await call_next(request)
        return JSONResponse({"detail": "Nieprawidłowy token"}, status_code=401)

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"status": "ok", "service": "voiceflow-api"}

    @app.get("/v1/model")
    def model_info() -> dict[str, Any]:
        """Szczegóły modelu tylko dla posiadacza tokenu."""
        return {
            "model": config.model.name,
            "device": transcriber.device,
            "compute_type": transcriber.compute_type,
            "language": config.model.language,
        }

    @app.post("/v1/transcribe")
    async def transcribe(audio: UploadFile = File(...)) -> JSONResponse:
        data = await audio.read(MAX_UPLOAD_BYTES + 1)
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="Nagranie przekracza 25 MB")
        if not data:
            raise HTTPException(status_code=400, detail="Puste nagranie")
        suffix = Path(audio.filename or "nagranie.webm").suffix or ".webm"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
            tmp.write(data)
            tmp.flush()
            try:
                samples = decode_upload(Path(tmp.name))
            except Exception as exc:  # noqa: BLE001 — każdy błąd dekodera to zły plik od klienta
                LOGGER.warning("Nie udało się zdekodować nagrania (%s): %s", audio.content_type, exc)
                raise HTTPException(status_code=400, detail="Nie udało się odczytać nagrania") from exc
        audio_seconds = float(len(samples)) / SAMPLE_RATE
        if audio_seconds > MAX_AUDIO_SECONDS:
            raise HTTPException(status_code=413, detail="Nagranie dłuższe niż 5 minut")
        import time

        started = time.perf_counter()
        text = transcriber.transcribe_chunk(samples)
        elapsed = time.perf_counter() - started
        LOGGER.info("Transkrypcja %.1f s audio zajęła %.2f s", audio_seconds, elapsed)
        return JSONResponse(
            {
                "text": text,
                "language": config.model.language,
                "audio_seconds": round(audio_seconds, 2),
                "transcription_seconds": round(elapsed, 2),
            }
        )

    return app


def build_app() -> FastAPI:
    """Wejście dla uvicorna: konfiguracja ze środowiska i prawdziwy model."""
    from voiceflow.transcriber import Transcriber

    config = ServerConfig.from_env()
    LOGGER.info(
        "Ładuję model %s (%s, %s)…", config.model.name, config.model.device, config.model.compute_type
    )
    transcriber = Transcriber(config.model)
    LOGGER.info("Model gotowy w %.1f s (rozgrzewka %.1f s)", transcriber.load_seconds, transcriber.warmup_seconds)
    return create_app(transcriber, config)


def main(argv: list[str] | None = None) -> int:
    import argparse

    import uvicorn

    parser = argparse.ArgumentParser(prog="voiceflow serve", description="serwer HTTP transkrypcji")
    parser.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8000")))
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        app = build_app()
    except RuntimeError as exc:
        print(f"Błąd konfiguracji: {exc}")
        return 2
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
    return 0
