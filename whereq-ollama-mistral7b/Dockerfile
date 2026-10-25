# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Ollama server with 1B / 3B / 7B-class models pre-pulled, all non-Chinese.
#
#   1B -> gemma3:1b    (Google)     ~815 MB, fast even on CPU, edge/tests.
#   3B -> llama3.2:3b  (Meta)       ~2.0 GB, strong general-purpose, tuned.
#   7B -> mistral:7b   (Mistral AI, France) ~4.4 GB at Q4_K_M.
#
# The 7B tier deliberately uses Mistral 7B: a genuine 7B dense model that is
# NOT Chinese-origin (rules out Qwen / DeepSeek / Yi / GLM), and the lightest
# well-supported non-Chinese 7B available today. Llama is 8B, Gemma's tiers
# are 2B/9B.
#
# Latest stable Ollama release as of build: v0.30.7
# ---------------------------------------------------------------------------

ARG OLLAMA_VERSION=0.30.7

FROM ollama/ollama:${OLLAMA_VERSION} AS ollama-base

# ---------------------------------------------------------------------------
# Build stage: pull the model blobs into a layer.
# We run the server in the background, wait for it to come up, then pull.
# ---------------------------------------------------------------------------
FROM ollama-base AS model-bake

# Override any tier at build time with --build-arg, e.g.
#   docker build --build-arg MODEL_7B=mistral:7b-instruct ...
ARG MODEL_1B=gemma3:1b
ARG MODEL_3B=llama3.2:3b
ARG MODEL_7B=mistral:7b

# ollama needs to bind to 127.0.0.1:11434 inside the build to pull models
ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_KEEP_ALIVE=24h

# Pull each model. Done sequentially to avoid OOM during the build.
RUN set -eux; \
    mkdir -p /root/.ollama; \
    ollama serve & \
    OLLAMA_PID=$!; \
    echo "Waiting for Ollama to become ready..."; \
    for i in $(seq 1 60); do \
      if ollama list >/dev/null 2>&1; then break; fi; \
      sleep 2; \
    done; \
    ollama pull "${MODEL_1B}"; \
    ollama pull "${MODEL_3B}"; \
    ollama pull "${MODEL_7B}"; \
    ollama list; \
    kill "$OLLAMA_PID" || true; \
    wait "$OLLAMA_PID" || true

# ---------------------------------------------------------------------------
# Runtime stage: smaller, with the model store already populated.
# We re-declare the ARG so docker history stays tidy.
# ---------------------------------------------------------------------------
FROM ollama-base AS runtime

ARG MODEL_1B=gemma3:1b
ARG MODEL_3B=llama3.2:3b
ARG MODEL_7B=mistral:7b

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
LABEL org.opencontainers.image.title="ollama-1b-3b-mistral7b" \
      org.opencontainers.image.description="Ollama ${OLLAMA_VERSION} with ${MODEL_1B}, ${MODEL_3B}, ${MODEL_7B} pre-installed" \
      org.opencontainers.image.source="https://github.com/ollama/ollama" \
      org.opencontainers.image.licenses="Apache-2.0"
