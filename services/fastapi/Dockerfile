# CPU-only. FastAPI gateway has zero GPU work.
# Multi-stage: builder installs deps; runtime gets only the wheels.
# Target final image size: < 320 MB

# ---- Stage 1: builder ----
FROM python:3.11-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --timeout=120 --retries=5 --target=/build/deps -r requirements.txt

# ---- Stage 2: runtime ----
FROM python:3.11-slim

# Non-root user — never run as UID 0 in production
RUN useradd --create-home --shell /bin/bash app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/deps /usr/local/lib/python3.11/site-packages

WORKDIR /app
COPY ./app /app

USER app

EXPOSE 8000

# HEALTHCHECK drives depends_on condition: service_healthy in compose.
# Without HEALTHCHECK the depends_on condition is never satisfied.
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD curl -fsS http://localhost:8000/health || exit 1

# python -m uvicorn (not the bare `uvicorn` script) — pip install --target
# does not put console-script entry points on PATH.
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
