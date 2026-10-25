#!/usr/bin/env bash
# =============================================================================
# llm-doctor — what is installed in this image, and is it wired up?
# =============================================================================
# Safe to run offline. Never prints secrets — only whether a key is set.
#   docker run --rm whereq/llm-cli llm-doctor
# =============================================================================
set -uo pipefail

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else
  B=''; D=''; G=''; Y=''; R=''; N=''
fi

section() { printf '\n%s── %s %s\n' "$B" "$1" "$N"; }
have()    { command -v "$1" >/dev/null 2>&1; }

version_of() { timeout 20 "$@" --version 2>/dev/null | head -1 | tr -d '\r'; }

section "platform"
printf '  %-14s %s\n' "arch"     "$(uname -m)"
printf '  %-14s %s\n' "os"       "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
printf '  %-14s %s\n' "user"     "$(id -un) (uid $(id -u))"
printf '  %-14s %s\n' "home"     "$HOME"
printf '  %-14s %s\n' "workdir"  "$(pwd)"

section "toolchains"
printf '  %-14s %s\n' "node"     "$(version_of node)"
printf '  %-14s %s\n' "npm"      "$(version_of npm)"
printf '  %-14s %s\n' "python"   "$(version_of python3)"
printf '  %-14s %s\n' "uv"       "$(version_of uv)"
printf '  %-14s %s\n' "pip"      "$(python3 -m pip --version 2>/dev/null | cut -d' ' -f1-2)"

section "llm clis"
missing=0
for cli in claude codex copilot; do
  if have "$cli"; then
    printf '  %s%-14s%s %s\n' "$G" "$cli" "$N" "$(version_of "$cli")"
  else
    printf '  %s%-14s%s %s(not installed)%s\n' "$D" "$cli" "$Y" "$N"
    missing=$((missing + 1))
  fi
done

section "python stack"
python3 - <<'PY' 2>/dev/null || echo "  (python stack unavailable)"
import importlib.metadata as md
groups = {
    "data": ["numpy","pandas","polars","pyarrow","scipy","scikit-learn","matplotlib","openpyxl"],
    "web": ["requests","httpx","aiohttp","beautifulsoup4","lxml","fastapi","uvicorn","flask"],
    "llm": ["anthropic","openai","tiktoken","litellm","huggingface-hub"],
    "db": ["SQLAlchemy","alembic","psycopg","redis","boto3"],
    "docs": ["python-docx","python-pptx","pypdf","pdfplumber"],
    "dev": ["pytest","ruff","black","mypy","ipython"],
}
total = len(list(md.distributions()))
print(f"  {total} distributions installed")
for g, pkgs in groups.items():
    have = []
    for p in pkgs:
        try:
            have.append(f"{p}=={md.version(p)}")
        except md.PackageNotFoundError:
            pass
    print(f"  {g:5} {', '.join(have) if have else '(none)'}")
PY

section "mounts"
for d in /config /workspace; do
  if mountpoint -q "$d" 2>/dev/null; then
    printf '  %s%s%s mounted\n' "$G" "$d" "$N"
  else
    printf '  %s%s%s NOT mounted — state will be lost when the container is removed\n' "$Y" "$d" "$N"
  fi
done
printf '  %-14s %s\n' "provider"  "${LLM_PROVIDER:-<unset>}"
printf '  %-14s %s\n' "openai url" "${OPENAI_BASE_URL:-<default>}"
printf '  %-14s %s\n' "anthropic"  "${ANTHROPIC_BASE_URL:-<default>}"
if [ -n "${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}${WQ_API_KEY:-}" ]; then
  printf '  %-14s %sset%s\n' "api key" "$G" "$N"
else
  printf '  %-14s %snot set%s\n' "api key" "$Y" "$N"
fi
if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
  printf '  %-14s %sset (Copilot CLI)%s\n' "github" "$G" "$N"
fi

section "cli config dirs (all under /config)"
for d in claude codex copilot; do
  [ -e "/config/$d" ] && printf '  /config/%-9s %s\n' "$d" "$(ls -A "/config/$d" 2>/dev/null | wc -l) entries"
done

[ "$missing" -gt 0 ] && printf '\n%snote:%s %d CLI(s) absent — rebuild with the matching INSTALL_* build arg.\n' "$Y" "$N" "$missing"
exit 0
