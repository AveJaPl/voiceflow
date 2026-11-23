# Serwer API transkrypcji (`voiceflow serve`)

Data: 2026-08-30. Zleceniodawca: Filip. Status: zatwierdzony w rozmowie, do wdrożenia.

## Cel

Ten sam Whisper, który dyktuje na komputerze Filipa, ma działać na VM PB Devs
jako usługa HTTP, żeby aplikacje webowe (najpierw CRM na tablecie) mogły
wysłać nagranie i dostać tekst. Audio nie opuszcza infrastruktury PB Devs.

## Zakres

- Nowy pakiet `voiceflow.server` (FastAPI + uvicorn), uruchamiany przez
  `voiceflow serve` albo `python -m voiceflow.server` (Docker).
- Jeden załadowany `Transcriber` z `voiceflow.transcriber` (CPU, int8),
  ta sama ścieżka co finalny przebieg dyktowania: VAD, słownik, filtr
  halucynacji. Zero nowego kodu rozpoznawania.
- Endpointy pod prefiksem `VOICEFLOW_ROOT_PATH` (domyślnie `/api`, żeby dało
  się powiesić API obok strony na tej samej domenie):
  - `GET  /api/health` → `{status, service}` (bez tokenu, bez szczegółów).
  - `GET  /api/v1/model` → `{model, device, compute_type, language}` (token).
  - `POST /api/v1/transcribe` — `multipart/form-data`, pole `audio`
    (webm/ogg/wav/m4a — dekoduje PyAV z faster-whisper), nagłówek
    `Authorization: Bearer <VOICEFLOW_API_TOKEN>`. Odpowiedź
    `{text, language, audio_seconds, transcription_seconds}`.
- Limity: 25 MB na nagranie, 300 s audio; ponad → 413.
- Bezpieczeństwo: repo i ścieżki są publiczne, więc jedyną ochroną jest
  token. Middleware odrzuca request bez tokenu **przed** odczytem ciała
  (zero kosztu CPU dla obcych), porównanie stałoczasowe, brak `/docs`.
  Adres produkcyjnej instancji nie pojawia się w repozytorium.
- Konfiguracja wyłącznie zmiennymi środowiskowymi (kontener nie ma
  `config.yaml`): `VOICEFLOW_API_TOKEN` (wymagany, bez niego serwer nie
  startuje), `VOICEFLOW_MODEL` (`large-v3-turbo`), `VOICEFLOW_COMPUTE_TYPE`
  (`int8`), `VOICEFLOW_LANGUAGE` (`pl`), `VOICEFLOW_CPU_THREADS` (`0`),
  `VOICEFLOW_VOCABULARY` (lista po przecinku), `VOICEFLOW_ROOT_PATH`, `PORT`.
- Dockerfile w katalogu głównym: `python:3.13-slim`, tylko zależności
  serwera (bez CUDA, GTK, PyGObject), model w wolumenie `/models`
  (`HF_HOME`), pobierany przy pierwszym starcie.

## Poza zakresem

Strumieniowanie w trakcie mówienia (podgląd), wiele modeli naraz, konta
użytkowników. Jeden token = jedna instalacja; per-aplikacja tokeny, gdy
dojdzie druga aplikacja.

## Klient (CRM)

Przycisk mikrofonu nagrywa `MediaRecorder` (webm/opus), po zatrzymaniu
wysyła nagranie do własnego endpointu CRM-a, który dokleja token i woła
`/api/v1/transcribe`. Tekst trafia do pola, do którego przycisk był
przypięty w chwili kliknięcia — niezależnie od tego, co ma focus.

## Testy

`tests/test_server.py` z `TestClient` i atrapą transkrybera: autoryzacja,
limit rozmiaru, poprawna odpowiedź, `health`, brak tokenu = brak startu.
