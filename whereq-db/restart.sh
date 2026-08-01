#!/usr/bin/env bash
# Recreate the whereq-db container from docker-compose-prod.yml (no rebuild).
# Reattaches the existing bind-mount data dir → no data loss; ~seconds downtime
# for the shared cluster. Backs up first unless --no-backup is given.
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE=docker-compose-prod.yml

if [ "${1:-}" != "--no-backup" ]; then
  ./backup.sh
fi

if docker container inspect whereq-db >/dev/null 2>&1; then
  echo "▶ stopping & removing existing whereq-db (data on host bind mount, preserved)…"
  docker stop whereq-db >/dev/null && docker rm whereq-db >/dev/null
fi

echo "▶ up -d --no-build db"
docker compose -f "$COMPOSE" --env-file .env up -d --no-build db

echo "▶ waiting for healthy…"
for i in $(seq 1 30); do
  s=$(docker inspect whereq-db --format '{{.State.Health.Status}}' 2>/dev/null || echo none)
  [ "$s" = healthy ] && { echo "✓ healthy"; break; }
  sleep 2
done
echo
exec ./status.sh
