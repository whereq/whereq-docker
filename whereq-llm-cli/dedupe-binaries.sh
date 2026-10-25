#!/usr/bin/env bash
# =============================================================================
# dedupe-binaries — remove the duplicate copies the npm CLIs make
# =============================================================================
# Claude Code's postinstall copies its native binary into the package's bin/
# directory — a second 280 MB copy of the very same file.
#
# For each known copy, find the original it was copied from (by content hash)
# and replace the copy with a symlink. Same bytes on disk, half the image.
#
#   before:  /opt/npm/.../claude-code/bin/claude.exe          280 MB
#            /opt/npm/.../claude-code-linux-x64/claude         280 MB
#   after:   /opt/npm/.../claude-code/bin/claude.exe -> ../…/claude
#            /opt/npm/.../claude-code-linux-x64/claude         280 MB
# =============================================================================
set -euo pipefail

NPM_ROOT="${1:-/opt/npm/lib/node_modules}"

dedupe() {
  local copy="$1" name size md5 cand
  copy="${NPM_ROOT}/${copy}"
  [ -f "$copy" ] || { echo "  skip ${copy##*/} (not present)"; return 0; }

  size=$(stat -c %s "$copy")
  if [ "$size" -lt 10485760 ]; then
    echo "  skip ${copy##*/} (only ${size} bytes)"
    return 0
  fi

  md5=$(md5sum "$copy" | cut -d' ' -f1)
  # Look for a byte-identical file elsewhere in the tree.
  while IFS= read -r cand; do
    [ "$cand" = "$copy" ] && continue
    if [ "$(md5sum "$cand" | cut -d' ' -f1)" = "$md5" ]; then
      local rel
      rel="$(realpath --relative-to="$(dirname "$copy")" "$cand")"
      ln -sfn "$rel" "$copy"
      printf '  deduped %-16s %6s MB -> symlink to %s\n' \
        "${copy##*/}" "$((size / 1048576))" "${cand#${NPM_ROOT}/}"
      return 0
    fi
  done < <(find "$NPM_ROOT" -type f -size +10M 2>/dev/null)

  echo "  kept ${copy##*/} (no identical original found)"
}

echo "deduplicating npm CLI binaries under ${NPM_ROOT}"
dedupe "@anthropic-ai/claude-code/bin/claude.exe"
