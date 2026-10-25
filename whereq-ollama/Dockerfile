# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Ollama server with the latest 1B / 3B / 7B-class models pre-pulled.
# Latest stable Ollama release as of build: v0.30.7
# ---------------------------------------------------------------------------

ARG OLLAMA_VERSION=0.30.7

FROM ollama/ollama:${OLLAMA_VERSION} AS ollama-base

# ---------------------------------------------------------------------------
# Build stage: pull the model blobs into a named volume-friendly layer.
# We run the server in the background, wait for it to come up, then pull.
# ---------------------------------------------------------------------------
FROM ollama-base AS model-bake

# 1B  -> gemma3:1b         (Google, ~1B params, very fast, great for tests/edge)
# 3B  -> llama3.2:3b        (Meta, 3.2B params, strong general-purpose)
# 7B  -> qwen3:8b           (Alibaba, 8B params — the strongest "7B-tier" model
#                            currently available, dense, multilingual)
#
# Override at build time with --build-arg if you want different tags, e.g.
#   docker build --build-arg MODEL_7B=llama3.1:8b ...
ARG MODEL_1B=gemma3:1b
ARG MODEL_3B=llama3.2:3b
ARG MODEL_7B=qwen3:8b

# ollama needs to bind to 127.0.0.1:11434 inside the build to pull models
ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_KEEP_ALIVE=24h

# Pull each model. Done sequentially to avoid OOM during the build.
RUN set -eux; \
    mkdir -p /root/.ollama; \
    ollama serve & \
    OLLAMA_PID=$$!; \
    echo "Waiting for Ollama to become ready..."; \
    for i in $(seq 1 60); do \
      if ollama list >/dev/null 2>&1; then break; fi; \
      sleep 2; \
    done; \
    ollama pull "${MODEL_1B}"; \
    ollama pull "${MODEL_3B}"; \
    ollama pull "${MODEL_7B}"; \
    ollama list; \
    kill "$$OLLAMA_PID" || true; \
    wait "$$OLLAMA_PID" || true

# ---------------------------------------------------------------------------
# Runtime stage: smaller, with the model store already populated.
# We re-declare the ARG so docker history stays tidy.
# ---------------------------------------------------------------------------
FROM ollama-base AS runtime

ARG MODEL_1B=gemma3:1b
ARG MODEL_3B=llama3.2:3b
ARG MODEL_7B=qwen3:8b

ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_KEEP_ALIVE=24h
# Copy the populated model store from the bake stage.
COPY --from=model-bake /root/.ollama /root/.ollama

# Expose the Ollama HTTP API.
EXPOSE 11434

# Healthcheck against the local API.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:11434/api/tags >/dev/null || exit 1

# Default entrypoint is the upstream ollama serve.
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]

# ---- Image metadata -------------------------------------------------------
LABEL org.opencontainers.image.title="ollama-1b-3b-7b" \
      org.opencontainers.image.description="Ollama ${OLLAMA_VERSION} with ${MODEL_1B}, ${MODEL_3B}, ${MODEL_7B} pre-installed" \
      org.opencontainers.image.source="https://github.com/ollama/ollama" \
      org.opencontainers.image.licenses="MIT"
