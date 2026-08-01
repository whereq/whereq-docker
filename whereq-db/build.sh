#!/usr/bin/env bash
# Build the whereq-postgres image from this directory's Dockerfile.
#   ./build.sh            → tags whereq-postgres:17
#   ./build.sh 17-02      → also tags whereq-postgres:17-02 (immutable pin)
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=whereq-postgres
PRIMARY=17
EXTRA="${1:-}"
echo "▶ building ${IMAGE}:${PRIMARY}${EXTRA:+ (+ ${IMAGE}:${EXTRA})} from $(pwd)/Dockerfile"
docker build -t "${IMAGE}:${PRIMARY}" ${EXTRA:+-t "${IMAGE}:${EXTRA}"} .
echo "✓ built:"
docker image ls "${IMAGE}" --format '  {{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}'
