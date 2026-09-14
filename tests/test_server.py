"""Serwer HTTP: autoryzacja, limity i kształt odpowiedzi — bez modelu i bez ffmpeg."""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from voiceflow.config import ModelConfig  # noqa: E402
from voiceflow.server import app as server  # noqa: E402


class _FakeTranscriber:
    device = "cpu"
    compute_type = "int8"
    config = ModelConfig(name="tiny", device="cpu", compute_type="int8")

    def __init__(self) -> None:
        self.calls: list[Any] = []

    def transcribe_chunk(self, audio: Any) -> str:
        self.calls.append(audio)
        return "dzień dobry"


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> tuple[TestClient, _FakeTranscriber]:
    monkeypatch.setattr(server, "decode_upload", lambda path: np.zeros(SAMPLES, dtype=np.float32))
    transcriber = _FakeTranscriber()
    config = server.ServerConfig(token="sekret", model=transcriber.config, root_path="/api")
    return TestClient(server.create_app(transcriber, config)), transcriber


SAMPLES = 16_000 * 3


def test_health_bez_tokenu(client: tuple[TestClient, _FakeTranscriber]) -> None:
    c, _ = client
    response = c.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "voiceflow-api"}
    # Szczegóły modelu nie wyciekają bez tokenu — repo jest publiczne, adres też.
    assert c.get("/v1/model").status_code == 401
    assert c.get("/v1/model", headers={"Authorization": "Bearer sekret"}).json()["model"] == "tiny"


def test_transcribe_wymaga_tokenu(client: tuple[TestClient, _FakeTranscriber]) -> None:
    c, transcriber = client
    files = {"audio": ("nagranie.webm", b"\x00" * 10, "audio/webm")}
    assert c.post("/v1/transcribe", files=files).status_code == 401
    assert c.post("/v1/transcribe", files=files, headers={"Authorization": "Bearer zly"}).status_code == 401
    assert transcriber.calls == []


def test_transcribe_zwraca_tekst_i_metryki(client: tuple[TestClient, _FakeTranscriber]) -> None:
    c, transcriber = client
    files = {"audio": ("nagranie.webm", b"\x00" * 10, "audio/webm")}
    response = c.post("/v1/transcribe", files=files, headers={"Authorization": "Bearer sekret"})
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "dzień dobry"
    assert body["audio_seconds"] == 3.0
    assert body["language"] == "pl"
    assert "transcription_seconds" in body
    assert len(transcriber.calls) == 1


def test_puste_i_za_duze_nagranie(client: tuple[TestClient, _FakeTranscriber]) -> None:
    c, _ = client
    headers = {"Authorization": "Bearer sekret"}
    assert c.post("/v1/transcribe", files={"audio": ("a.webm", b"", "audio/webm")}, headers=headers).status_code == 400
    duze = b"\x00" * (server.MAX_UPLOAD_BYTES + 1)
    assert c.post("/v1/transcribe", files={"audio": ("a.webm", duze, "audio/webm")}, headers=headers).status_code == 413


def test_za_dlugie_audio(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        server, "decode_upload", lambda path: np.zeros(int(server.MAX_AUDIO_SECONDS * 16_000) + 16_000, dtype=np.float32)
    )
    transcriber = _FakeTranscriber()
    config = server.ServerConfig(token="sekret", model=transcriber.config)
    c = TestClient(server.create_app(transcriber, config))
    response = c.post(
        "/v1/transcribe", files={"audio": ("a.webm", b"\x00", "audio/webm")}, headers={"Authorization": "Bearer sekret"}
    )
    assert response.status_code == 413
    assert transcriber.calls == []


def test_zly_plik_to_400(monkeypatch: pytest.MonkeyPatch) -> None:
    def padnij(path: Any) -> Any:
        raise ValueError("nie audio")

    monkeypatch.setattr(server, "decode_upload", padnij)
    transcriber = _FakeTranscriber()
    c = TestClient(server.create_app(transcriber, server.ServerConfig(token="sekret", model=transcriber.config)))
    response = c.post(
        "/v1/transcribe", files={"audio": ("a.txt", b"czesc", "text/plain")}, headers={"Authorization": "Bearer sekret"}
    )
    assert response.status_code == 400


def test_konfiguracja_ze_srodowiska() -> None:
    with pytest.raises(RuntimeError, match="VOICEFLOW_API_TOKEN"):
        server.ServerConfig.from_env({})
    config = server.ServerConfig.from_env(
        {
            "VOICEFLOW_API_TOKEN": "abc",
            "VOICEFLOW_VOCABULARY": "Coolify, WooCommerce ,",
            "VOICEFLOW_ROOT_PATH": "api/",
            "VOICEFLOW_LANGUAGE": "auto",
        }
    )
    assert config.token == "abc"
    assert config.model.name == "large-v3-turbo"
    assert config.model.device == "cpu"
    assert config.model.compute_type == "int8"
    assert config.model.language is None
    assert config.model.vocabulary == ("Coolify", "WooCommerce")
    assert config.root_path == "/api"
    assert server.ServerConfig.from_env({"VOICEFLOW_API_TOKEN": "x", "VOICEFLOW_ROOT_PATH": "/"}).root_path == ""
