#!/usr/bin/env bash
# =============================================================================
# whereq-hermes entrypoint
# =============================================================================
# Three jobs, in order:
#   1. Drop privileges (when started as root) and adopt the mounted volumes.
#   2. Work out which model backend we are pointed at and fan its credentials
#      out to the env var names Hermes understands.
#   3. Exec the command.
#
# Configuration precedence (later wins):
#   image defaults  →  /config/env (mount a single file here)
#                   →  -e VAR=… / compose environment
# =============================================================================
set -euo pipefail

log()  { printf '\033[36m▶\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m⚠\033[0m  %s\n' "$*" >&2; }

USER_NAME="${USER_NAME:-hermes}"
HERMES_HOME="${HERMES_HOME:-/config/hermes}"
TARGET_UID="${HERMES_UID:-$(id -u "${USER_NAME}" 2>/dev/null || echo 10000)}"
TARGET_GID="${HERMES_GID:-$(id -g "${USER_NAME}" 2>/dev/null || echo 10000)}"

# ── 1. Privileges ───────────────────────────────────────────────────────────
# This happens BEFORE the configuration is loaded. Dropping privileges re-execs
# this script, so loading the config first would print every message twice.
for d in "$HERMES_HOME" /config/.local /config/.config /workspace; do
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
done

if [ "$(id -u)" = "0" ]; then
  # Started as root: adopt the mounted volumes for the runtime user, then drop
  # privileges.
  #
  # /config is container-managed state, so everything in it that is still
  # root's is adopted, at any depth. `--from=0` leaves files that already
  # belong to somebody else alone. The recursion matters: a volume that an
  # earlier root-running container created holds root-owned files inside, and
  # Hermes refuses to start when its install state is not writable by the
  # runtime user.
  chown -R --from=0:0 "${TARGET_UID}:${TARGET_GID}" /config 2>/dev/null || true
  # HERMES_HOME normally lives inside /config; if it was pointed elsewhere,
  # adopt that tree too.
  if [ "$HERMES_HOME" != "/config/hermes" ] && [ -d "$HERMES_HOME" ]; then
    chown -R --from=0:0 "${TARGET_UID}:${TARGET_GID}" "$HERMES_HOME" 2>/dev/null || true
  fi
  # /workspace is a bind mount of the user's own project — only the top-level
  # directory is adopted, and only when it is still root-owned. A directory
  # that already belongs to somebody else is left alone: chowning it would
  # silently change ownership OUTSIDE the container (a host project owned by
  # your desktop uid, say).
  if [ "$(stat -c %u /workspace 2>/dev/null || echo 0)" = "0" ]; then
    chown "${TARGET_UID}:${TARGET_GID}" /workspace 2>/dev/null || true
  fi
  exec setpriv --reuid "$TARGET_UID" --regid "$TARGET_GID" --clear-groups -- \
    /usr/local/bin/hermes-entrypoint "${@}"
fi

if [ "$(id -u)" != "$TARGET_UID" ]; then
  warn "running as uid $(id -u) but the image expects ${TARGET_UID} (set HERMES_UID/HERMES_GID or run as ${USER_NAME})"
fi

# ── 2. Configuration ────────────────────────────────────────────────────────
load_env_file() {
  # shellcheck disable=SC1090
  [ -f "$1" ] || return 0
  set -a; . "$1"; set +a
}

load_env_file /config/env   # user drop-in, mounted as a single file

# One set of credentials, understood by every backend. Whatever is already in
# the environment — passed with `docker -e` / compose — wins; the canonical
# WQ_* variables fill in the blanks.
if [ -n "${WQ_API_KEY:-}" ]; then
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$WQ_API_KEY}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$WQ_API_KEY}"
  export GEMINI_API_KEY="${GEMINI_API_KEY:-$WQ_API_KEY}"
  export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$WQ_API_KEY}"
fi
if [ -n "${WQ_BASE_URL:-}" ]; then
  export OPENAI_BASE_URL="${OPENAI_BASE_URL:-$WQ_BASE_URL}"
  export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-$WQ_BASE_URL}"
fi
if [ -n "${WQ_MODEL:-}" ]; then
  export HERMES_MODEL="${HERMES_MODEL:-$WQ_MODEL}"
  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-$WQ_MODEL}"
  export OPENAI_MODEL="${OPENAI_MODEL:-$WQ_MODEL}"
fi

# Hermes reaches a local Ollama through OLLAMA_HOST (it does its own model
# discovery there), not through the OpenAI-compatible WQ_BASE_URL path.
# OLLAMA_HOST wants the bare host:port, so the /v1 suffix is stripped.
if [ -n "${OLLAMA_HOST:-}" ] || [ "${LLM_PROVIDER:-}" = "ollama" ]; then
  export OLLAMA_HOST="${OLLAMA_HOST:-${WQ_BASE_URL:-}}"
  export OLLAMA_HOST="${OLLAMA_HOST%/v1}"
fi

# Credential warnings — never print the value, only whether one is present.
if [ -n "${WQ_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; then
  log "credentials: present (${LLM_PROVIDER:-custom backend})"
elif [ -n "${OLLAMA_HOST:-}" ]; then
  log "credentials: none needed (local Ollama at ${OLLAMA_HOST})"
else
  warn "no API key found — set WQ_API_KEY, mount /config/env, or log in interactively"
fi

# ── 3. Mounts ───────────────────────────────────────────────────────────────
# A state directory the container user cannot write is the most common reason
# a session "doesn't save" — say so up front rather than let it fail quietly.
if [ ! -w "$HERMES_HOME" ]; then
  warn "${HERMES_HOME} is not writable by uid $(id -u) — memories, skills and sessions will not persist."
  warn "the volumes are owned by the uid the image was built with (${HERMES_IMAGE_UID:-unknown});"
  warn "set HERMES_UID/HERMES_GID in .env to \$(id -u)/\$(id -g) and rebuild:  docker compose build"
fi
if [ ! -w /workspace ]; then
  warn "/workspace is not writable by uid $(id -u) — Hermes cannot edit or write files there."
  warn "set HERMES_UID/HERMES_GID in .env to \$(id -u)/\$(id -g) and rebuild:  docker compose build"
fi

# Agents clone and edit code that may be owned by another uid.
git config --global --add safe.directory '*' 2>/dev/null || true

# ── 4. Run ──────────────────────────────────────────────────────────────────
if [ "$#" -eq 0 ]; then
  set -- hermes
fi
exec "$@"
