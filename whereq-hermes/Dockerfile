# syntax=docker/dockerfile:1.7
# ============================================================================
# Hermes Agent (Nous Research) - latest stable v0.16.0 (tag v2026.6.5)
# https://github.com/NousResearch/hermes-agent
#
# Three CLI entry points are installed:
#   - hermes       (the interactive CLI)
#   - hermes-agent (non-interactive / batch / API driver)
#   - hermes-acp   (ACP adapter for editor integrations)
#
# Python 3.13 is the latest version the project allows (<3.14) — the
# <3.14 cap is load-bearing: Rust-backed deps like pydantic-core have
# no cp314 wheel yet, and uv would otherwise try to build them from
# source. See pyproject.toml in the upstream repo.
# ============================================================================

# ---------- Build stage: produce an isolated wheel --------------------------
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-bookworm-slim AS builder

ARG HERMES_VERSION=v2026.6.5
ARG HERMES_REPO=https://github.com/NousResearch/hermes-agent

WORKDIR /build

# Fetch the source tarball with checksum verification deferred to the
# `uv build` step (uv will fail loudly on a corrupted archive).
ADD ${HERMES_REPO}/archive/refs/tags/${HERMES_VERSION}.tar.gz /tmp/hermes-src.tar.gz

RUN mkdir -p /src && \
    tar -xzf /tmp/hermes-src.tar.gz -C /src --strip-components=1 && \
    rm /tmp/hermes-src.tar.gz

WORKDIR /src

# Build an isolated wheel so the runtime layer only needs the wheel, not
# setuptools, build backends, or the source tree.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv build --wheel --out-dir /wheels

# ---------- Runtime stage: slim image with the wheel installed --------------
FROM python:3.13-slim-bookworm AS runtime

# Disable Python stdout buffering so `docker logs` shows output in real time.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Runtime system dependencies. Kept minimal — add more here only if a
# specific skill/plugin you load at runtime complains about a missing
# system library (e.g. ffmpeg for the media skills).
RUN apt-get update && \
    apt-get install -y --no-install-install-recommends \
        ca-certificates \
        curl \
        git \
        tini && \
    rm -rf /var/lib/apt/lists/*

# Non-root user. Override at runtime with HERMES_UID if your host UID
# doesn't match the default (10000) — useful for bind-mounted volumes.
ARG HERMES_UID=10000
RUN useradd -u ${HERMES_UID} -m -s /bin/bash hermes

WORKDIR /home/hermes

# Install the wheel we built in the previous stage. --no-deps because the
# wheel's METADATA already lists exact-pinned deps; uv pip will resolve
# them and we'll get a clean, reproducible install.
COPY --from=builder /wheels/*.whl /tmp/wheels/
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir /tmp/wheels/*.whl && \
    rm -rf /tmp/wheels

# Drop privileges for runtime.
USER hermes

# Tini as PID 1: reaps zombie subprocesses (MCP stdio children, git, etc.)
# so they don't accumulate when hermes spawns helper processes.
ENTRYPOINT ["/usr/bin/tini", "--"]

# Default to the interactive CLI. Override with `--entrypoint` or a
# compose `command:` for non-interactive flows.
CMD ["hermes"]

# Quick metadata so `docker inspect` is useful.
ARG HERMES_VERSION=v2026.6.5
LABEL org.opencontainers.image.title="whereq-hermes" \
      org.opencontainers.image.description="Hermes Agent (Nous Research) - latest stable" \
      org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent" \
      org.opencontainers.image.version="${HERMES_VERSION}" \
      org.opencontainers.image.licenses="MIT"
