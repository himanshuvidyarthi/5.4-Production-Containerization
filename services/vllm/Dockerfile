# Multi-stage GPU Dockerfile — 12.4 GB naive -> 6.8 GB
# Builder stage: nvidia/cuda:devel (has nvcc for compilation)
# Runtime stage: nvidia/cuda:runtime (no compiler, no headers)
# COPY --from=builder brings only the installed wheels.

FROM nvidia/cuda:12.2.0-devel-ubuntu22.04 AS builder
RUN apt-get update && apt-get install -y \
    python3.11 python3-pip git build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/build/deps -r requirements.txt

FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04
RUN apt-get update && apt-get install -y \
    python3.11 python3-distutils curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/deps /usr/local/lib/python3.11/dist-packages
WORKDIR /app
ENV PYTHONPATH=/usr/local/lib/python3.11/dist-packages
EXPOSE 8000
# start_period: 120s — vLLM takes 90-120s to load 8B weights into VRAM.
# Without this, healthcheck fires before model is ready, vllm is marked
# unhealthy, litellm's depends_on blocks indefinitely.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", \
     "--model", "meta-llama/Llama-3.1-8B-Instruct", "--host", "0.0.0.0"]
