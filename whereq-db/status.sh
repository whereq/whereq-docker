#!/usr/bin/env bash
# Verify the whereq-db container + PostGIS + every app database.
set -uo pipefail
cd "$(dirname "$0")"
set -a; [ -f .env ] && . ./.env; set +a
U="${POSTGRES_USER:-whereq}"
echo "── container ──"
docker ps --filter name=whereq-db --format '  {{.Names}}  {{.Image}}  {{.Status}}'
echo "  health: $(docker inspect whereq-db --format '{{.State.Health.Status}}' 2>/dev/null || echo n/a)"
echo "  image:  $(docker inspect whereq-db --format '{{.Config.Image}}' 2>/dev/null) ($(docker inspect whereq-db --format '{{.Image}}' 2>/dev/null | cut -c8-19))"
echo "── postgres ──"
docker exec whereq-db psql -U "$U" -d postgres -tAc 'SHOW server_version;' 2>&1 | sed 's/^/  version: /'
docker exec whereq-db psql -U "$U" -d whereq-com -tAc 'SELECT postgis_version();' 2>&1 | sed 's/^/  postgis: /'
echo "── databases ──"
for db in postgres k2m flowdesk catobigato whereq-com; do
  if docker exec whereq-db psql -U "$U" -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
    echo "  ✓ $db"
  else
    echo "  ✗ $db (unreachable)"
  fi
done
