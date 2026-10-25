# syntax=docker/dockerfile:1.7
# ============================================================================
# whereq-llm-cli — a portable container for Claude Code, Codex and Copilot
# ============================================================================
# One image with:
#
#   * Claude Code, OpenAI Codex, GitHub Copilot CLI.
#   * Node.js LTS + npm, and the newest stable CPython with a broad
#     pre-installed scientific / web / automation stack, so a CLI can write a
#     throwaway Python script and just run it — no pip install at runtime.
#   * The shell toolbox agents actually reach for (rg, fd, jq, fzf, git, …).
#
# Design notes:
#   * Two stages. Every download and native build happens in `builder`; the
#     runtime stage copies only the artefacts, so npm/apt caches never ship.
#   * linux/amd64 only. Multi-arch support was dropped along with Goose/Crush/
#     aider/aichat/Gemini/Qwen/opencode — re-add TARGETARCH-based arch
#     resolution if an arm64 host is ever in scope again.
#   * All persistent state lives under two mount points: /config (API keys,
#     sessions, memory, history, per-CLI config) and /workspace (your code).
#   * Backend-agnostic: WQ_API_KEY / WQ_BASE_URL / WQ_MODEL are fanned out to
#     every CLI's own variable names by the entrypoint, so switching between
#     Anthropic, OpenAI, DeepSeek, MiniMax, OpenRouter or a local Ollama is a
#     one-line change in compose. Copilot is the exception — it authenticates
#     with a GitHub token instead.
#
#   docker build -t whereq/llm-cli .
#   docker run --rm -it -v llm-config:/config -v "$PWD":/workspace \
#     -e LLM_PROVIDER=anthropic -e WQ_API_KEY=sk-ant-… whereq/llm-cli
# ============================================================================

ARG UBUNTU_VERSION=26.04

# ─────────────────────────────── builder ────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG DEBIAN_FRONTEND=noninteractive

# ── Toolchains ──
ARG NODE_VERSION=24.22.1          # Node LTS ("Krypton"); Current is 26.x
ARG UV_VERSION=0.13.5
ARG PYTHON_VERSION=3.15.1         # newest stable CPython (3.16 is still alpha)
ARG PYTHON_BUILD=20261021         # python-build-standalone release tag

# ── LLM CLI versions (all latest stable at the time of writing) ──
ARG CLAUDE_CODE_VERSION=2.1.309
ARG CODEX_VERSION=0.163.0
ARG COPILOT_VERSION=1.0.103

# ── Hermes Agent (Nous Research) ──
# Hermes caps at Python <3.15 (pyproject: requires-python ">=3.11,<3.15") and
# gates every direct dependency behind `python_version >= '3.14'`, because
# 3.14 is the newest CPython its Rust-backed deps (pydantic-core) ship wheels
# for. The shared /opt/python is 3.15, so Hermes gets its OWN 3.14
# interpreter in a dedicated venv — installed into /opt/venvs/hermes, kept
# OFF PATH so `python3` still means the shared 3.15 for everything else.
ARG HERMES_VERSION=v0.22.5
ARG HERMES_PYTHON_VERSION=3.14.9
# The upstream commit the release tag points at. Baked into the install stamp
# so `hermes --version` reports real provenance instead of "unknown".
ARG HERMES_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e

# ── Feature switches: build a slim image by turning the big ones off ──
ARG INSTALL_CLAUDE_CODE=1
ARG INSTALL_CODEX=1
ARG INSTALL_COPILOT=1
ARG INSTALL_HERMES=1
# Runtime user's uid/gid — the toolchains are handed over to it in the builder
# so the runtime stage never has to copy files up just to change their owner.
ARG USER_UID=1000
ARG USER_GID=1000
ARG INSTALL_MEDIA=1               # ffmpeg + imagemagick
ARG INSTALL_BUILD_TOOLS=1         # gcc/make — lets `pip install` work at runtime
# Extra packages appended to the pre-installed Python stack.
ARG PYTHON_EXTRAS=""

ENV PATH=/opt/node/bin:/opt/uv:$PATH \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_CACHE_DIR=/tmp/uv-cache \
    UV_LINK_MODE=copy \
    npm_config_cache=/tmp/npm-cache \
    npm_config_update_notifier=false \
    DEBIAN_FRONTEND=noninteractive

# Build-time toolchain: uv, and a compiler for the packages that still ship an
# sdist on a brand-new CPython (currently just PyYAML).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config ca-certificates curl \
        libyaml-dev libffi-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 dedupe-binaries.sh /usr/local/bin/dedupe-binaries

# ── Node.js (checksum-verified against the official SHASUMS256.txt) ──
RUN set -eux; cd /tmp; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    file="node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    curl -fsSLO "${base}/${file}"; \
    curl -fsSLO "${base}/SHASUMS256.txt"; \
    grep " ${file}\$" SHASUMS256.txt | sha256sum -c -; \
    mkdir -p /opt/node; \
    tar -xJf "${file}" -C /opt/node --strip-components=1; \
    rm -f "${file}" SHASUMS256.txt; \
    /opt/node/bin/node --version

# ── uv (kept in the final image: `uv pip install` / `uv run` at runtime) ──
RUN set -eux; cd /tmp; \
    base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"; \
    file="uv-x86_64-unknown-linux-gnu.tar.gz"; \
    curl -fsSLO "${base}/${file}"; \
    curl -fsSLO "${base}/${file}.sha256"; \
    sha256sum -c "${file}.sha256"; \
    mkdir -p /opt/uv; \
    tar -xzf "${file}" -C /opt/uv --strip-components=1 "uv-x86_64-unknown-linux-gnu/uv"; \
    rm -f "${file}" "${file}.sha256"; \
    /opt/uv/uv --version

# ── CPython: python-build-standalone, i.e. the same interpreter `uv` uses ──
RUN set -eux; cd /tmp; \
    url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}"; \
    file="cpython-${PYTHON_VERSION}+${PYTHON_BUILD}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"; \
    curl -fsSLO "${url}/${file}"; \
    mkdir -p /opt/python; \
    tar -xzf "${file}" -C /opt/python --strip-components=1; \
    rm -f "${file}"; \
    /opt/python/bin/python3 -VV

# ── The npm CLIs: ONE npm invocation ──
# Splitting them across layers makes each install prune the previous ones
# (npm treats --prefix as its project and removes "extraneous" packages).
RUN --mount=type=cache,target=/tmp/npm-cache \
    set -eux; \
    pkgs=""; \
    [ "${INSTALL_CLAUDE_CODE}" = "1" ] && pkgs="${pkgs} @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" || true; \
    [ "${INSTALL_CODEX}" = "1" ]        && pkgs="${pkgs} @openai/codex@${CODEX_VERSION}" || true; \
    [ "${INSTALL_COPILOT}" = "1" ]      && pkgs="${pkgs} @github/copilot@${COPILOT_VERSION}" || true; \
    if [ -n "$pkgs" ]; then \
      npm install -g --prefix /opt/npm $pkgs; \
    fi; \
    # The postinstall of some CLIs copies their native binary into the
    # package's bin/ — a second copy of the same 200-300 MB file. Swap the
    # copy for a symlink.
    /usr/local/bin/dedupe-binaries /opt/npm/lib/node_modules

# ── The pre-installed Python stack ──
# This is the whole point: a CLI writes `pandas`/`httpx`/`matplotlib` code and
# it just runs. Everything is version-pinned so rebuilds are reproducible.
COPY requirements/ /tmp/requirements/
RUN --mount=type=cache,target=/tmp/uv-cache \
    set -eux; \
    /opt/uv/uv pip install --python /opt/python/bin/python3 \
      -r /tmp/requirements/python-base.txt; \
    if [ -n "${PYTHON_EXTRAS}" ]; then \
      /opt/uv/uv pip install --python /opt/python/bin/python3 ${PYTHON_EXTRAS}; \
    fi; \
    rm -rf /tmp/requirements

# ── Hermes Agent (Nous Research) ──
# Installed from a source CHECKOUT, not a wheel. Upstream deliberately blocks
# wheel/sdist builds outside Nix — setup.py raises unless HERMES_NIX_BUILD=1
# — and publishes no prebuilt artifacts. An editable install (uv sync) is the
# supported path, and it keeps the bundled assets (locales, skills,
# optional-mcps, plugin manifests) that a wheel would silently drop.
#
# It gets its OWN CPython 3.14 at /opt/python314: Hermes pins requires-python
# ">=3.11,<3.15" and gates every direct dependency behind
# python_version >= '3.14', because 3.14 is the newest CPython its
# Rust-backed deps (pydantic-core) ship wheels for. The venv at
# /opt/hermes/.venv is deliberately NOT on PATH, so `python3` still means the
# shared 3.15 for every other tool in this image.
RUN --mount=type=cache,target=/tmp/uv-cache \
    set -eux; \
    mkdir -p /opt/python314 /opt/hermes; \
    if [ "${INSTALL_HERMES}" != "1" ]; then \
      echo "INSTALL_HERMES=${INSTALL_HERMES} — skipping Hermes Agent"; \
      exit 0; \
    fi; \
    export UV_PYTHON_INSTALL_DIR=/opt/hermes/.uv-python; \
    url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}"; \
    file="cpython-${HERMES_PYTHON_VERSION}+${PYTHON_BUILD}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"; \
    curl -fsSLO "${url}/${file}"; \
    tar -xzf "${file}" -C /opt/python314 --strip-components=1; \
    rm -f "${file}"; \
    /opt/python314/bin/python3 -VV; \
    curl -fsSL "https://github.com/NousResearch/hermes-agent/archive/refs/tags/${HERMES_VERSION}.tar.gz" -o /tmp/hermes.tar.gz; \
    tar -xzf /tmp/hermes.tar.gz -C /opt/hermes --strip-components=1; \
    rm -f /tmp/hermes.tar.gz; \
    cd /opt/hermes; \
    /opt/uv/uv sync --frozen --python /opt/python314/bin/python3; \
    rm -rf /opt/hermes/.uv-python; \
    # Stamp the install: without it `hermes --version` reports "unknown" and
    # the update steward cannot tell that a package manager owns this tree.
    # The upstream image bakes the same "docker" marker into its install dir.
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

# ── Hand the toolchains to the runtime user HERE, in the builder ──
# The runtime stage COPYs /opt with its ownership intact, so no file ever has
# to be copied up into a second layer just to change its owner. A `chown -R
# /opt` AFTER the COPY measured 6.4 GB in overlayfs — never reintroduce it.
RUN chown -R "${USER_UID}:${USER_GID}" /opt

# ─────────────────────────────── runtime ────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG PYTHON_VERSION=3.15.1
ARG USER_NAME=llm
ARG USER_UID=1000
ARG USER_GID=1000
ARG INSTALL_MEDIA=1
ARG INSTALL_BUILD_TOOLS=1

ENV DEBIAN_FRONTEND=noninteractive

# ── Shell toolbox ──
# Deliberately no python3-* apt packages: the interpreter comes from
# /opt/python so it stays independent of the distro's release cycle.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg openssh-client git git-lfs \
        jq ripgrep fd-find fzf bat tree file less \
        tar gzip bzip2 xz-utils zstd unzip zip rsync \
        nano vim-tiny tmux htop procps lsof \
        iproute2 iputils-ping dnsutils netcat-openbsd socat \
        libgomp1 libstdc++6 \
        util-linux locales tzdata tini; \
    if [ "${INSTALL_BUILD_TOOLS}" = "1" ]; then \
        apt-get install -y --no-install-recommends \
            build-essential pkg-config libyaml-dev libffi-dev libssl-dev; \
    fi; \
    if [ "${INSTALL_MEDIA}" = "1" ]; then \
        apt-get install -y --no-install-recommends ffmpeg imagemagick; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # Debian/Ubuntu rename these two to avoid clashing with other packages:
    # fd → fdfind, bat → batcat. Give the names everyone expects.
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── Copy the artefacts built above (nothing else from the builder) ──
COPY --from=builder /opt/node /opt/node
COPY --from=builder /opt/npm /opt/npm
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/uv/uv /opt/uv/uv
# Hermes Agent: its own CPython 3.14 and the source checkout it runs from.
# Both exist (possibly empty) even when INSTALL_HERMES=0, so the COPY never
# breaks the build for a slim variant.
COPY --from=builder /opt/python314 /opt/python314
COPY --from=builder /opt/hermes /opt/hermes

# Hermes console scripts on the global PATH. The venv's own bin/ stays OFF
# PATH on purpose — putting it there would make `python3` resolve to Hermes'
# 3.14 instead of the shared 3.15 that every other tool expects.
RUN set -eux; \
    for s in hermes hermes-agent hermes-acp; do \
      [ -x "/opt/hermes/.venv/bin/${s}" ] || continue; \
      ln -sf "/opt/hermes/.venv/bin/${s}" "/usr/local/bin/${s}"; \
    done

# `python3` / `python` / `pip` always point at the newest CPython, whatever
# PYTHON_VERSION was configured.
RUN set -eux; \
    pyver="${PYTHON_VERSION%.*}"; \
    pybin="/opt/python/bin/python${pyver}"; \
    [ -x "$pybin" ] || pybin=/opt/python/bin/python3; \
    ln -sf "$pybin" /usr/local/bin/python3; \
    ln -sf "$pybin" /usr/local/bin/python; \
    printf '#!/bin/sh\nexec %s -m pip "$@"\n' "$pybin" > /usr/local/bin/pip; \
    printf '#!/bin/sh\nexec %s -m pip "$@"\n' "$pybin" > /usr/local/bin/pip3; \
    chmod +x /usr/local/bin/pip /usr/local/bin/pip3; \
    python3 -VV

# ── Non-root user ──
# Override at build time with --build-arg USER_UID=$(id -u) when bind-mounted
# volumes are owned by your host user; the entrypoint also honours WQ_UID /
# WQ_GID at runtime.
RUN set -eux; \
    # ubuntu:24.04+ ships a stock "ubuntu" user at uid/gid 1000. Reclaim it,
    # so the default USER_UID/USER_GID=1000 is free for the runtime user.
    if getent passwd ubuntu >/dev/null 2>&1; then \
        userdel -r ubuntu 2>/dev/null || userdel ubuntu; \
    fi; \
    # If the requested gid/uid is already taken by something else, rename that
    # account rather than failing the build.
    if getent group "${USER_GID}" >/dev/null 2>&1; then \
        existing="$(getent group "${USER_GID}" | cut -d: -f1)"; \
        [ "$existing" = "${USER_NAME}" ] || groupmod -n "${USER_NAME}" "$existing"; \
    else \
        groupadd --gid "${USER_GID}" "${USER_NAME}"; \
    fi; \
    if getent passwd "${USER_UID}" >/dev/null 2>&1; then \
        existing="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        [ "$existing" = "${USER_NAME}" ] || \
            usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m "$existing"; \
    else \
        useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USER_NAME}"; \
    fi; \
    id "${USER_NAME}"

# ── Every CLI writes its state under /config, so one bind mount persists it ──
RUN set -eux; \
    mkdir -p /config/providers /config/.config /config/.local/share \
             /config/.local/state /config/.local/bin /config/.cache \
             /config/.uv/python /config/.npm /workspace \
             /config/claude /config/codex /config/copilot /config/hermes \
             "/home/${USER_NAME}"; \
    : > /config/gitconfig; \
    for d in claude codex copilot; do \
      ln -sfn "/config/${d}" "/home/${USER_NAME}/.${d}"; \
    done; \
    # Hermes: HERMES_HOME points at /config/hermes (see ENV below), so the
    # default profile's memories, skills, sessions, logs and cron jobs — and
    # every named profile under profiles/ — live in the mounted volume. The
    # ~/.hermes symlink covers the native-home fallback path.
    ln -sfn /config/hermes "/home/${USER_NAME}/.hermes"; \
    # Hermes writes a per-profile launcher wrapper into ~/.local/bin when a
    # profile is created. Keep the whole .local tree in /config so those
    # wrappers survive a container recreate.
    ln -sfn /config/.local "/home/${USER_NAME}/.local"; \
    # /opt is already owned by the runtime user — the builder handed it over
    # before the COPY, so nothing here is copied up into a second layer.
    chown -R "${USER_UID}:${USER_GID}" /config /workspace "/home/${USER_NAME}"

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/llm-entrypoint
COPY --chmod=0755 llm-doctor.sh /usr/local/bin/llm-doctor
COPY providers/ /etc/llm/providers/

ENV HOME=/home/${USER_NAME} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PATH=/opt/node/bin:/opt/npm/bin:/opt/python/bin:/opt/uv:/config/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    XDG_CONFIG_HOME=/config/.config \
    XDG_DATA_HOME=/config/.local/share \
    XDG_STATE_HOME=/config/.local/state \
    XDG_CACHE_HOME=/config/.cache \
    UV_PYTHON_INSTALL_DIR=/config/.uv/python \
    GIT_CONFIG_GLOBAL=/config/gitconfig \
    npm_config_cache=/config/.npm \
    CLAUDE_CONFIG_DIR=/config/claude \
    CODEX_HOME=/config/codex \
    HERMES_HOME=/config/hermes \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /workspace

# Starts as root on purpose: the entrypoint chowns the bind mounts for the
# runtime user and then drops privileges with setpriv (the postgres-image
# pattern). Run with `docker run --user llm` if you would rather skip that.
# tini reaps the process trees these CLIs spawn (MCP servers, shells, git).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/llm-entrypoint"]
CMD ["/bin/bash"]

LABEL org.opencontainers.image.title="whereq-llm-cli" \
      org.opencontainers.image.description="Portable LLM CLI toolbox: Claude Code, Codex, Copilot + Node LTS + Python ${PYTHON_VERSION}" \
      org.opencontainers.image.source="https://github.com/whereq/whereq-docker" \
      org.opencontainers.image.licenses="MIT"
