#!/usr/bin/env bash
# Full cluster backup (pg_dumpall) → ~/backups/. Run before any recreate.
set -euo pipefail
cd "$(dirname "$0")"
set -a; [ -f .env ] && . ./.env; set +a
OUT="${HOME}/backups/whereq-db-pgdumpall-$(date +%Y%m%d-%H%M%S).sql.gz"
mkdir -p "$(dirname "$OUT")"
echo "▶ dumping all databases → $OUT"
docker exec whereq-db pg_dumpall -U "${POSTGRES_USER:-whereq}" | gzip > "$OUT"
echo "✓ $(du -h "$OUT" | cut -f1)  $OUT"
