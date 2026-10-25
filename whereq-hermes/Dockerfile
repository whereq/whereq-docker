# syntax=docker/dockerfile:1.7
# ============================================================================
# whereq-hermes — Hermes Agent (Nous Research) in a container
# https://github.com/NousResearch/hermes-agent
#
# Three CLI entry points ship:
#   - hermes       the interactive CLI (the default CMD)
#   - hermes-agent non-interactive / batch driver
#   - hermes-acp   ACP adapter for editor integrations
#
# ── Why a source checkout and not a wheel ───────────────────────────────────
# Upstream deliberately blocks wheel and sdist builds outside Nix — setup.py
# raises unless HERMES_NIX_BUILD=1 — and publishes no prebuilt artifacts. The
# supported non-Nix path is an editable install from a source checkout, which
# is also what keeps the bundled assets (locales, skills, optional-mcps,
# plugin manifests) that Hermes resolves from its install directory at
# runtime. A wheel would silently drop every one of them.
#
# ── Why CPython 3.14 ────────────────────────────────────────────────────────
# pyproject pins requires-python ">=3.11,<3.15" and gates every direct
# dependency behind python_version >= '3.14'; uv.lock is resolved for 3.14
# only. 3.14 is the newest CPython whose Rust-backed deps (pydantic-core)
# ship wheels.
#
# ── Keep these in step with whereq-llm-cli ──────────────────────────────────
# The same Hermes release is bundled in the whereq-llm-cli image. HERMES_VERSION,
# HERMES_COMMIT and HERMES_PYTHON_VERSION must match that image's values, so
# the two images run byte-identical Hermes code.
# ============================================================================

# ---------- uv: the publisher's own image, a single static binary -----------
# These two ARGs are global (declared before the first FROM) so that the FROM
# lines below can expand them.
ARG UV_VERSION=0.13.5
ARG HERMES_PYTHON_VERSION=3.14.9
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# ---------- Builder: fetch the source, resolve the lock, stamp the install ---
FROM python:${HERMES_PYTHON_VERSION}-slim-bookworm AS builder

ARG HERMES_VERSION=v0.22.5
ARG HERMES_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e
ARG HERMES_REPO=https://github.com/NousResearch/hermes-agent
ARG HERMES_PYTHON_VERSION=3.14.9

# uv, taken from the publisher's own image rather than pip — it is a single
# static binary and this is the channel uv documents for container builds.
COPY --from=uv /uv /uvx /usr/local/bin/

# The python:slim base has no curl; this layer lives only in the builder, so
# it costs the final image nothing.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/hermes

RUN --mount=type=cache,target=/root/.cache/uv \
    set -eux; \
    curl -fsSL "${HERMES_REPO}/archive/refs/tags/${HERMES_VERSION}.tar.gz" -o /tmp/hermes.tar.gz; \
    tar -xzf /tmp/hermes.tar.gz -C /opt/hermes --strip-components=1; \
    rm -f /tmp/hermes.tar.gz; \
    # --frozen means the shipped uv.lock is used verbatim: nothing is resolved,
    # nothing is upgraded, the build is reproducible from the tag alone.
    uv sync --frozen --python /usr/local/bin/python3; \
    # Without this stamp `hermes --version` reports "unknown" and the update
    # steward cannot tell that a package manager owns this tree. The upstream
    # image bakes the same "docker" marker into its install directory.
    /opt/hermes/.venv/bin/python scripts/write_install_stamp.py \
        --output /opt/hermes/install-stamp.json \
        --commit "${HERMES_COMMIT}" \
        --base-version "${HERMES_VERSION#v}" \
        --distance 0 \
        --source ci --distribution docker --update-mechanism external; \
    printf 'docker' > /opt/hermes/.install_method; \
    test -x /opt/hermes/.venv/bin/hermes; \
    test -x /opt/hermes/.venv/bin/hermes-agent; \
    test -x /opt/hermes/.venv/bin/hermes-acp; \
    /opt/hermes/.venv/bin/hermes --version

# ---------- Runtime: slim image, non-root, tini as PID 1 ---------------------
FROM python:${HERMES_PYTHON_VERSION}-slim-bookworm AS runtime

ARG HERMES_VERSION=v0.22.5
ARG HERMES_PYTHON_VERSION=3.14.9
ARG HERMES_UID=1000
ARG HERMES_GID=1000
ARG USER_NAME=hermes

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DEBIAN_FRONTEND=noninteractive

# Runtime system dependencies. Deliberately minimal — this image is the agent,
# not the toolbox. Add a package here only if a skill you load complains
# about a missing system library (ffmpeg for the media skills, say). For a
# full shell toolbox use the whereq-llm-cli image instead.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        tini \
        ripgrep \
        jq && \
    rm -rf /var/lib/apt/lists/*

# Non-root user. Override with HERMES_UID/HERMES_GID at BUILD time if your
# host UID doesn't match the default (1000) — the build arg is what owns the
# mounted volumes, so a runtime-only override is not enough.
RUN groupadd --gid "${HERMES_GID}" "${USER_NAME}" 2>/dev/null || true; \
    useradd --uid "${HERMES_UID}" --gid "${HERMES_GID}" -m -s /bin/bash "${USER_NAME}"

# COPY --chown hands the tree to the runtime user as part of the copy. A
# `chown -R` in the builder instead would cost a second full copy of every
# file into a new layer — it measured 170 s of build time on this tree.
COPY --chown=${HERMES_UID}:${HERMES_GID} --from=builder /opt/hermes /opt/hermes

# The console scripts are symlinked into /usr/local/bin as well as being on
# PATH, so `hermes` resolves even if the caller overrides PATH.
RUN set -eux; \
    for s in hermes hermes-agent hermes-acp; do \
      [ -x "/opt/hermes/.venv/bin/${s}" ] || continue; \
      ln -sf "/opt/hermes/.venv/bin/${s}" "/usr/local/bin/${s}"; \
    done

# ── State layout ─────────────────────────────────────────────────────────────
# HERMES_HOME is the single root for everything Hermes persists: the default
# profile's memories, skills, sessions, logs, cron jobs and state.db, plus one
# directory per named profile under profiles/. With it set, Hermes never
# creates ~/.hermes — the symlink below only covers the native-home fallback.
#
# Hermes also writes a per-profile launcher wrapper into ~/.local/bin when a
# profile is created, so the whole .local tree lives under /config too and
# those wrappers survive a container recreate.
RUN set -eux; \
    mkdir -p /config/hermes /config/.local/bin /config/.config \
             /config/.local/share /config/.local/state /config/.cache \
             /workspace; \
    ln -sfn /config/hermes "/home/${USER_NAME}/.hermes"; \
    ln -sfn /config/.local "/home/${USER_NAME}/.local"; \
    chown -R "${HERMES_UID}:${HERMES_GID}" /config /workspace "/home/${USER_NAME}"

ENV HOME=/home/${USER_NAME} \
    HERMES_HOME=/config/hermes \
    HERMES_IMAGE_UID=${HERMES_UID} \
    HERMES_IMAGE_GID=${HERMES_GID} \
    PATH=/opt/hermes/.venv/bin:/config/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    XDG_CONFIG_HOME=/config/.config \
    XDG_DATA_HOME=/config/.local/share \
    XDG_STATE_HOME=/config/.local/state \
    XDG_CACHE_HOME=/config/.cache \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-entrypoint

WORKDIR /workspace

# Tini as PID 1: reaps zombie subprocesses (MCP stdio children, git, shells)
# so they don't accumulate when Hermes spawns helper processes. The entrypoint
# runs between tini and the CLI: it adopts the mounted volumes for the runtime
# user, drops privileges, then execs the command.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hermes-entrypoint"]

# Default to the interactive CLI. Override with `--entrypoint` or a compose
# `command:` for non-interactive flows.
CMD ["hermes"]

# Quick metadata so `docker inspect` is useful.
LABEL org.opencontainers.image.title="whereq-hermes" \
      org.opencontainers.image.description="Hermes Agent (Nous Research) - source checkout, CPython 3.14" \
      org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent" \
      org.opencontainers.image.version="${HERMES_VERSION}" \
      org.opencontainers.image.licenses="MIT"
