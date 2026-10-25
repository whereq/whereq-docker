#!/usr/bin/env bash
# =============================================================================
# whereq-llm-cli entrypoint
# =============================================================================
# Three jobs, in order:
#   1. Drop privileges (when started as root) and prepare the mounts.
#   2. Work out which LLM backend we are pointed at and fan its credentials
#      out to the env var names every CLI understands.
#   3. Exec the command.
#
# Configuration precedence (later wins):
#   image defaults  →  /config/env (mount a single file here)
#                   →  /etc/llm/providers/<provider>.env   (image defaults)
#                   →  /config/providers/<provider>.env    (your overrides)
#                   →  -e VAR=… / compose environment
#
# Provider selection: set LLM_PROVIDER=<name> (anthropic, openai, gemini,
# deepseek, minimax, openrouter, ollama, custom). Each profile only defines
# WQ_BASE_URL / WQ_ANTHROPIC_BASE_URL; the key and model come from WQ_API_KEY
# and WQ_MODEL, which you set (via -e, /config/env, or the profile itself).
# =============================================================================
set -euo pipefail

log()  { printf '\033[36m▶\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m⚠\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[0;31m✖\033[0m %s\n' "$*" >&2; }

# ── 1. Privileges ───────────────────────────────────────────────────────────
# This happens BEFORE the configuration is loaded. Dropping privileges re-execs
# this script, so loading the config first would print every message twice.
TARGET_UID="${WQ_UID:-$(id -u "${USER_NAME:-llm}" 2>/dev/null || echo 1000)}"
TARGET_GID="${WQ_GID:-$(id -g "${USER_NAME:-llm}" 2>/dev/null || echo 1000)}"

for d in /config /workspace; do
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
done

if [ "$(id -u)" = "0" ]; then
  # Started as root: adopt the bind mounts for the runtime user, then drop
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
  if [ -n "${HERMES_HOME:-}" ] && [ "$HERMES_HOME" != "/config/hermes" ] && [ -d "$HERMES_HOME" ]; then
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
    /usr/local/bin/llm-entrypoint "${@}"
fi

if [ "$(id -u)" != "$TARGET_UID" ]; then
  warn "running as uid $(id -u) but the image expects ${TARGET_UID} (set WQ_UID/WQ_GID or run as ${USER_NAME:-llm})"
fi

# ── 2. Configuration ────────────────────────────────────────────────────────
load_env_file() {
  # shellcheck disable=SC1090
  [ -f "$1" ] || return 0
  set -a; . "$1"; set +a
}

load_env_file /config/env          # user drop-in, mounted as a single file

provider="${LLM_PROVIDER:-}"
if [ -n "$provider" ]; then
  for f in "/config/providers/${provider}.env" "/etc/llm/providers/${provider}.env"; do
    if [ -f "$f" ]; then
      load_env_file "$f"
      log "provider '${provider}' → ${f}"
      break
    fi
  done
  [ -n "${WQ_BASE_URL:-}" ] || warn "no provider profile found for '${provider}' (looked in /config/providers and /etc/llm/providers)"
fi

# One set of credentials, understood by every CLI. Whatever is already in the
# environment — passed with `docker -e` / compose, or set by a profile's own
# ANTHROPIC_*/OPENAI_* line — wins; the canonical WQ_* variables fill in the
# blanks.
if [ -n "${WQ_API_KEY:-}" ]; then
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$WQ_API_KEY}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$WQ_API_KEY}"
  export GEMINI_API_KEY="${GEMINI_API_KEY:-$WQ_API_KEY}"
  export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$WQ_API_KEY}"
fi
if [ -n "${WQ_BASE_URL:-}" ]; then
  export OPENAI_BASE_URL="${OPENAI_BASE_URL:-$WQ_BASE_URL}"
  export GOOGLE_GEMINI_BASE_URL="${GOOGLE_GEMINI_BASE_URL:-$WQ_BASE_URL}"
fi
# Some gateways (DeepSeek, MiniMax) speak the Anthropic protocol on a different
# path than their OpenAI-compatible one — the profile may override just that.
if [ -n "${WQ_ANTHROPIC_BASE_URL:-}" ] || [ -n "${WQ_BASE_URL:-}" ]; then
  export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${WQ_ANTHROPIC_BASE_URL:-$WQ_BASE_URL}}"
fi
if [ -n "${WQ_MODEL:-}" ]; then
  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-$WQ_MODEL}"
  export OPENAI_MODEL="${OPENAI_MODEL:-$WQ_MODEL}"
  export GEMINI_MODEL="${GEMINI_MODEL:-$WQ_MODEL}"
  # Hermes picks its default model from HERMES_MODEL.
  export HERMES_MODEL="${HERMES_MODEL:-$WQ_MODEL}"
fi

# Hermes reaches a local Ollama through OLLAMA_HOST (it does its own model
# discovery there), not through the OpenAI-compatible WQ_BASE_URL path.
# OLLAMA_HOST wants the bare host:port, so the /v1 suffix is stripped.
if [ "${provider:-}" = "ollama" ]; then
  export OLLAMA_HOST="${OLLAMA_HOST:-${WQ_BASE_URL:-}}"
  export OLLAMA_HOST="${OLLAMA_HOST%/v1}"
fi

# Credential warnings — never print the value, only whether one is present.
if [ -n "${WQ_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; then
  log "credentials: present (${provider:-custom backend})"
elif [ "${provider:-}" = "ollama" ]; then
  log "credentials: none needed (local Ollama)"
else
  warn "no API key found — set WQ_API_KEY, or mount /config/env, or log in interactively"
fi
if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
  log "GitHub Copilot CLI: token present"
fi

# ── 3. Mounts ───────────────────────────────────────────────────────────────
# A project directory the container user cannot write is by far the most common
# reason a CLI "doesn't create CLAUDE.md" or can't commit — say so up front
# rather than letting it fail mysteriously later.
if [ ! -w /workspace ]; then
  warn "/workspace is not writable by uid $(id -u) — a CLI running there cannot write CLAUDE.md, edit files or commit."
  warn "fix with one of:"
  warn "  docker compose run --rm -e WQ_UID=\"\$(id -u)\" -e WQ_GID=\"\$(id -g)\" llm-cli   # per run"
  warn "  docker build --build-arg USER_UID=\"\$(id -u)\" --build-arg USER_GID=\"\$(id -g)\" …  # permanent"
fi

# Agents clone and edit code that may be owned by another uid.
git config --global --add safe.directory '*' 2>/dev/null || true

# ── 4. Run ──────────────────────────────────────────────────────────────────
if [ "$#" -eq 0 ]; then
  set -- /bin/bash
fi
exec "$@"
