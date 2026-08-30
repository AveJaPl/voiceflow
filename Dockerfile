# voiceflow serve — serwer HTTP transkrypcji na VM (CPU, bez pulpitu i CUDA).
# Model ląduje w wolumenie /models (HF_HOME) przy pierwszym starcie.
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/models \
    VOICEFLOW_ROOT_PATH=/api \
    PORT=8000

WORKDIR /app

# Zależności serwera wprost — `pip install .` ciągnąłby nvidia-cublas/cudnn
# (ponad 1 GB), których na maszynie bez GPU nie ma po co instalować.
RUN pip install --no-cache-dir \
      "faster-whisper>=1.2" numpy PyYAML websockets \
      fastapi "uvicorn[standard]" python-multipart

COPY pyproject.toml README.md LICENSE ./
COPY src ./src
RUN pip install --no-cache-dir --no-deps .

VOLUME ["/models"]
EXPOSE 8000

CMD ["python", "-m", "voiceflow.server"]
