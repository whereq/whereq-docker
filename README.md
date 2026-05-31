# whereq-docker

Canonical base **Docker images** shared across the WhereQ Universe
(whereq.com, flowdesk.top, KeyToMarvel, catobigato, …). Each subdirectory is one
image with its own `Dockerfile`.

## Images

| Directory | Image tag | Purpose |
|-----------|-----------|---------|
| [`whereq-db/`](whereq-db/) | `whereq-postgres:17` | PostgreSQL 17 + PostGIS 3.5 — the shared `whereq-db` cluster (alpine/arm64) |

## whereq-db

Shared PostgreSQL serving every app's database from one cluster. PostGIS-enabled.

```bash
# Build (context = the image directory)
docker build -t whereq-postgres:17 whereq-db

# The container is launched by the shared postgres compose (currently
# flowdesk.top/docker/docker-compose.postgres.yml), which owns whereq-network.
# Recreate with the freshly built image (data is on a host bind mount):
cd ~/github/flowdesk.top/docker
docker compose -f docker-compose.postgres.yml --env-file .env up -d --no-build db
```

Notes:
- Base is `imresamu/postgis:17-3.5-alpine` (the maintainer's arm64+alpine PostGIS
  build; the official `postgis/postgis` is amd64-only and `postgres:17-alpine` +
  `apk add postgis` doesn't wire the extension into `/usr/local`).
- Cluster uses `C` collation (libc-independent) and postgres uid 70.
