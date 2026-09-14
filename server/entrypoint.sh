#!/bin/sh
# Pobiera model (raz, do /models) i startuje whisper-server pod ścieżką
# zgodną z OpenAI. `--convert` pozwala przyjąć m4a/mp3 (ffmpeg w obrazie);
# apki i tak wysyłają WAV 16 kHz mono.
set -e
MODEL_FILE="/models/ggml-${WHISPER_MODEL}.bin"
if [ ! -s "$MODEL_FILE" ]; then
    echo "[voiceflow-server] pobieram model ${WHISPER_MODEL} do /models"
    curl -fL "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin" -o "$MODEL_FILE.part"
    mv "$MODEL_FILE.part" "$MODEL_FILE"
fi
echo "[voiceflow-server] model ${WHISPER_MODEL}, język ${WHISPER_LANGUAGE}, wątki ${WHISPER_THREADS}, port ${PORT}"
exec /app/build/bin/whisper-server \
    --model "$MODEL_FILE" \
    --language "$WHISPER_LANGUAGE" \
    --threads "$WHISPER_THREADS" \
    --host 0.0.0.0 --port "$PORT" \
    --inference-path /v1/audio/transcriptions \
    --convert \
    --flash-attn \
    --no-prints
