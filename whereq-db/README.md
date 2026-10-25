# whereq-db — shared PostgreSQL 17 + PostGIS

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

## Configuration

```bash
cp .env.example .env           # gitignored; edit per host
```

`.env` sets the image/container/network names, host port, the data-dir bind
mount, and the cluster **superuser** (used only when the cluster is first
initialised on an empty data dir). See `.env.example` for the documented dev
defaults. `up` on an existing container just does `docker start` and needs none
of these.

## Provisioning an application database

Each app gets its own database + login role in the shared cluster:

```bash
../bin/whereq-db create-app <db> <role> <password>
```

This is idempotent (skips role/db that already exist). Per-database extensions
(e.g. PostGIS) belong in each application's own migrations, not in the cluster
bootstrap `init.sql`.

## Why this base image

See the top of `Dockerfile` — `imresamu/postgis:17-3.5-alpine` is load-bearing
(correct PostGIS linkage, matching uid for the host data dir, arm64 for the PROD
Raspberry Pi).
