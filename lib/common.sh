# =============================================================================
# whereq-docker — shared shell library
# =============================================================================
# Reusable helpers for the WhereQ Universe's container control scripts. Source
# it from any per-service script (or from an application repo's own dev script):
#
#   source "/home/whereq/git/whereq-docker/lib/common.sh"
#   WQ_DOCKER="$(wq_docker)" || { wq_err "no docker engine"; exit 1; }
#
# Design goals:
#   * One place for the WSL docker-vs-docker.exe quirk (see wq_docker).
#   * No global side effects on source — just function + colour definitions.
#   * Pure Bash; every whereq app family (whereq.com, flowdesk, k2m, catobigato)
#     can rely on the same primitives to reach the shared cluster.
# =============================================================================

# Guard against double-sourcing.
[[ -n "${_WQ_COMMON_SH:-}" ]] && return 0
_WQ_COMMON_SH=1

# ── Colours + logging ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  WQ_RED=$'\033[0;31m'; WQ_GREEN=$'\033[0;32m'; WQ_YELLOW=$'\033[1;33m'
  WQ_CYAN=$'\033[0;36m'; WQ_BOLD=$'\033[1m'; WQ_DIM=$'\033[2m'; WQ_NC=$'\033[0m'
else
  WQ_RED=''; WQ_GREEN=''; WQ_YELLOW=''; WQ_CYAN=''; WQ_BOLD=''; WQ_DIM=''; WQ_NC=''
fi

wq_log()  { printf '%s▶%s %s\n'  "$WQ_CYAN"   "$WQ_NC" "$*"; }
wq_ok()   { printf '%s✔%s %s\n'  "$WQ_GREEN"  "$WQ_NC" "$*"; }
wq_warn() { printf '%s⚠%s  %s\n' "$WQ_YELLOW" "$WQ_NC" "$*"; }
wq_err()  { printf '%s✖%s %s\n'  "$WQ_RED"    "$WQ_NC" "$*" >&2; }
wq_dim()  { printf '%s  %s%s\n'  "$WQ_DIM"    "$*" "$WQ_NC"; }

# ── Docker binary resolution ─────────────────────────────────────────────────
# In the WSL setup the native /usr/bin/docker is a non-functional stub
# ("enable WSL integration"); Docker Desktop's docker.exe works once the engine
# is up. Prefer whichever `info` actually reaches an engine. Prints the chosen
# binary on stdout; returns non-zero if none reach an engine.
#
# Cache the result in WQ_DOCKER across calls to avoid re-probing (docker.exe is
# slow to spawn).
WQ_DOCKER="${WQ_DOCKER:-}"
wq_docker() {
  if [[ -n "$WQ_DOCKER" ]]; then printf '%s\n' "$WQ_DOCKER"; return 0; fi
  local cand
  for cand in docker docker.exe; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" info >/dev/null 2>&1; then
      WQ_DOCKER="$cand"; printf '%s\n' "$WQ_DOCKER"; return 0
    fi
  done
  # None reached an engine; still report a present binary (for messaging).
  for cand in docker docker.exe; do
    if command -v "$cand" >/dev/null 2>&1; then printf '%s\n' "$cand"; return 1; fi
  done
  return 1
}

# True if a docker binary reaches a running engine.
wq_engine_up() { local d; d="$(wq_docker)" && "$d" info >/dev/null 2>&1; }

# ── Env file loading ─────────────────────────────────────────────────────────
# Export KEY=VALUE lines from a file if it exists (comments + blanks ignored).
# Later files override earlier ones — call with defaults first, real .env last.
wq_load_env() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

# ── Network / container helpers ──────────────────────────────────────────────
wq_ensure_network() {
  local net="$1" d; d="$(wq_docker)" || return 1
  if ! "$d" network inspect "$net" >/dev/null 2>&1; then
    wq_log "Creating docker network '$net'…"
    "$d" network create "$net" >/dev/null
  fi
}

# Echoes: running | stopped | absent
wq_container_state() {
  local name="$1" d; d="$(wq_docker)" || { echo absent; return; }
  if "$d" ps --format '{{.Names}}' | grep -qx "$name"; then echo running
  elif "$d" ps -a --format '{{.Names}}' | grep -qx "$name"; then echo stopped
  else echo absent; fi
}

# Wait until a container reports healthy (or at least running, if it has no
# healthcheck). Args: <name> [timeout_seconds=30]
wq_wait_healthy() {
  local name="$1" timeout="${2:-30}" d; d="$(wq_docker)" || return 1
  local i=0
  while (( i < timeout )); do
    local health
    health="$("$d" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo '')"
    case "$health" in
      healthy|running) return 0 ;;
      unhealthy)       return 1 ;;
    esac
    sleep 1; ((i++))
  done
  return 1
}
