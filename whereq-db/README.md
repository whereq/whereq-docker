# whereq-db — shared PostgreSQL 17 + PostGIS + pgvector

The single Postgres cluster for the WhereQ Universe (whereq.com, flowdesk, k2m,
catobigato). One container, `whereq-db`, on the `whereq-network`, with data on a
host bind mount so rebuilds never lose data.

## Lifecycle — `bin/whereq-db`

Use the shared control script for everything (it works the same on **local** and
**prod** — only `whereq-db/.env` differs per host):

```bash
../bin/whereq-db up            # create-or-start + wait healthy (idempotent)
../bin/whereq-db status        # state, health, port, reachability
../bin/whereq-db down          # stop (data preserved)
../bin/whereq-db restart
../bin/whereq-db logs -f
../bin/whereq-db build         # (re)build whereq-postgres:17 from this dir
../bin/whereq-db psql          # psql as the cluster superuser
../bin/whereq-db create-app catobigato catobigato '<password>'
../bin/whereq-db doctor        # diagnose docker / image / container / data / .env
```

Any application repo can bring the DB up with one call — e.g. catobigato's
`bin/dev.sh` delegates to `~/git/whereq-docker/bin/whereq-db up`.

### Per-directory scripts (PROD-oriented)

These sit next to the image and operate on the **PROD** compose file:

```bash
./build.sh [tag]        # build whereq-postgres:17 (+ optional immutable tag)
./backup.sh             # pg_dumpall → ~/backups/, run before any recreate
./restart.sh [--no-backup]  # backup, recreate from docker-compose-prod.yml, wait healthy
./status.sh              # container health, PG version, PostGIS version, per-app DB reachability
```

`bin/whereq-db` is the canonical cross-app lifecycle; these are the
PROD-compose equivalents. Both read the same `whereq-db/.env`.

## Configuration

```bash
cp .env.example .env           # gitignored; edit per host
```

`.env` sets the image/container/network names, host port, the data-dir bind
mount, and the cluster **superuser** (used only when the cluster is first
initialised on an empty data dir). See `.env.example` for the documented dev
defaults. `up` on an existing container just does `docker start` and needs none
of these.

**Two consumers read that file with different variable names.** `bin/whereq-db`
uses `WHEREQ_DB_*` (image, container, network, port, data path) plus
`POSTGRES_USER` / `POSTGRES_DB` / `POSTGRES_PASSWORD`;
`docker-compose-prod.yml` uses `POSTGRES_*` plus `DB_PORT` and
`POSTGRES_DATA_PATH`. `.env.example` therefore lists both sets — keep the pairs
(`WHEREQ_DB_PORT`/`DB_PORT`, `WHEREQ_DB_DATA`/`POSTGRES_DATA_PATH`) in step.

## Extensions

- **PostGIS** comes from the base image (`imresamu/postgis:17-3.5-alpine`).
- **pgvector 0.8.0** is built from source in the image's Dockerfile (the Alpine
  apk build targets a different PostgreSQL prefix — same reason PostGIS comes
  from the base image, not apk). The extension is **available but not enabled
  cluster-wide**: `CREATE EXTENSION vector` belongs in each application's own
  database, like PostGIS.

## Provisioning an application database

Each app gets its own database + login role in the shared cluster:

```bash
../bin/whereq-db create-app <db> <role> <password>
```

This is idempotent (skips role/db that already exist). Per-database extensions
(e.g. PostGIS, pgvector) belong in each application's own migrations, not in the
cluster bootstrap `init.sql`.

## Why this base image

See the top of `Dockerfile` — `imresamu/postgis:17-3.5-alpine` is load-bearing
(correct PostGIS linkage, matching uid for the host data dir, arm64 for the PROD
Raspberry Pi).
