# =============================================================================
# whereq shared PostgreSQL 17 + PostGIS  —  image: whereq-postgres:17
# =============================================================================
# Canonical image for the shared `whereq-db` container. The single cluster
# serves multiple apps across the WhereQ Universe (whereq.com, flowdesk.top,
# KeyToMarvel/k2m, catobigato). Data lives on a host bind mount, so rebuilding
# and recreating the container never loses data.
#
# Build (context = this directory):
#   docker build -t whereq-postgres:17 /home/whereq/git/whereq-docker/whereq-db
#
# Base: Alpine PostgreSQL 17 + PostGIS 3.5, published by the PostGIS Docker
# maintainer (Imre Samu) with the arm64 + Alpine variants the official
# `postgis/postgis` image does not provide.
#
# Why this base (not `postgres:17-alpine` + `apk add postgis`):
#   * The official postgres:alpine installs PostgreSQL into /usr/local, but
#     Alpine's apk `postgis` builds against Alpine's own postgres package
#     (different path) — so the extension is never found. This image builds
#     PostGIS against the /usr/local postgres correctly.
#   * Alpine/musl keeps postgres uid 70, matching the existing host data dir
#     (no chown), and avoids a glibc collation change (cluster is `C` anyway).
#   * arm64 is supported (PROD host is aarch64); `postgis/postgis` is amd64-only.
# =============================================================================
FROM imresamu/postgis:17-3.5-alpine

LABEL maintainer="whereq"
LABEL description="PostgreSQL 17 + PostGIS 3.5 for the shared whereq database cluster (alpine/arm64)"

# Cluster bootstrap — runs only on a fresh (empty) data directory.
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql

# =============================================================================
# pgvector 0.8.0 — semantic vector type/index for flowdesk.top (NOVA retrieval)
# Built from SOURCE against this image's /usr/local PostgreSQL. The Alpine apk
# postgresql-pgvector targets Alpine's /usr postgres (different prefix), not the
# /usr/local postgres this image uses — same reason PostGIS comes from the
# imresamu base, not apk. pg is built --with-llvm, so clang19/llvm19-dev are
# needed to emit the JIT bitcode.
# =============================================================================
RUN set -eux; \
    apk add --no-cache --virtual .pgvector-build build-base clang19 llvm19-dev git; \
    git clone --depth 1 --branch v0.8.0 https://github.com/pgvector/pgvector.git /tmp/pgvector; \
    cd /tmp/pgvector; \
    make; \
    make install; \
    cd /; rm -rf /tmp/pgvector; \
    apk del .pgvector-build

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD pg_isready -U "${POSTGRES_USER:-postgres}" || exit 1

EXPOSE 5432
