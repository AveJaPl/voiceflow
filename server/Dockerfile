# Własny serwer transkrypcji dla VoiceFlow — whisper.cpp `whisper-server`
# z kontraktem zgodnym z OpenAI (`POST /v1/audio/transcriptions`, multipart:
# `file`, `language`, `prompt`, `response_format=json` → `{"text": "..."}`).
#
# Apki (Mac, iPhone) mają w Zaawansowanych jedno pole „Adres serwera
# transkrypcji” — pod to samo pole podłącza się też każdy inny serwer z tym
# kontraktem (faster-whisper-server, Speaches, OpenAI, Groq).
#
# Obraz bazowy to oficjalny obraz whisper.cpp (CPU). Model pobiera się przy
# pierwszym starcie do wolumenu /models.
FROM ghcr.io/ggml-org/whisper.cpp:main

ENV WHISPER_MODEL=large-v3-turbo-q5_0 \
    WHISPER_LANGUAGE=pl \
    WHISPER_THREADS=4 \
    PORT=8090

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
VOLUME ["/models"]
EXPOSE 8090
ENTRYPOINT ["/entrypoint.sh"]
