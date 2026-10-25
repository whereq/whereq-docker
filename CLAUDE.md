# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Docker image definitions **and shared lifecycle scripts** for the WhereQ Universe (whereq.com, flowdesk.top, KeyToMarvel/k2m, catobigato, chroniq, whereq-monitor, and the ccbus/buzz stack). Each top-level directory is a self-contained image: a Dockerfile, usually a `docker-compose.yml`, and a README — there is no root README. There is no shared build system, no tests, and no lint — verification means building the image and running the container.

**Memory hierarchy:** this file holds what is shared across all images. `whereq-llm-cli/CLAUDE.md` is a nested, image-specific file that is authoritative for that image and deliberately does **not** repeat anything from here — when working inside `whereq-llm-cli/`, read both, and prefer the nested file for image-specific questions.

## Shared scripts (`bin/` + `lib/`)

- **`lib/common.sh`** — a sourced Bash library reused by every control script and by application repos' own dev scripts. It centralises the WSL **docker-vs-docker.exe** quirk (`wq_docker` picks whichever binary actually reaches an engine), plus `wq_engine_up`, `wq_load_env`, `wq_ensure_network`, `wq_container_state`, `wq_wait_healthy`, and `wq_log/ok/warn/err/dim`. Source it: `source ~/git/whereq-docker/lib/common.sh`.
- **`bin/whereq-db`** — canonical, idempotent lifecycle for the shared `whereq-db` container (`up`/`down`/`restart`/`status`/`logs`/`build`/`psql`/`create-app`/`doctor`). The **same script serves local and prod** — only `whereq-db/.env` differs per host. This is the single source of truth for bringing the database up; application repos delegate to it (e.g. catobigato's `bin/dev.sh` calls `bin/whereq-db up`). Config comes from `whereq-db/.env` (copy from `whereq-db/.env.example`; `.env` is gitignored). Two script-internal couplings: no argument means `up`, and `--help` prints `sed -n '2,40p'` of the script itself — the header comment must stay inside that line range or the help text truncates.

New shared services follow the same pattern: add `bin/whereq-<svc>` that sources `lib/common.sh` and reads `<svc>/.env`.

## Commands

Each image builds independently with its directory as the build context:

```bash
# Compose-managed images (whereq-hermes, whereq-ollama)
cd whereq-hermes && docker compose build        # or: docker compose up -d --build

# whereq-llm-cli: copy .env.example to .env first (set LLM_PROVIDER + WQ_API_KEY)
cd whereq-llm-cli && docker compose build
docker compose run --rm llm-cli                 # interactive shell
docker compose run --rm llm-cli claude          # launch a specific CLI
docker compose run --rm llm-cli hermes          # Hermes Agent
docker compose run --rm llm-cli llm-doctor      # what's installed, is it wired up

# whereq-db: use the lifecycle script (build + run + manage) — not raw docker
bin/whereq-db build      # build whereq-postgres:17
bin/whereq-db up         # create-or-start the container (idempotent, local & prod)
bin/whereq-db status     # state / health / reachability
```

Version pins live in build args (`HERMES_VERSION`, `HERMES_COMMIT`, `HERMES_PYTHON_VERSION`, `OLLAMA_VERSION`, `MODEL_1B/3B/7B`, and in `whereq-llm-cli` also `NODE_VERSION`, `PYTHON_VERSION`, `UV_VERSION`, `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `COPILOT_VERSION`) declared in both the Dockerfile and the compose `build.args` — keep the two in sync when bumping. `HERMES_VERSION` is the upstream **semver release tag** (`v0.22.5`) in both Hermes images, and the two images must stay on the same one; the legacy `v2026.*` date tags are a separate, older release line and are not used.

Verification is manual and out-of-band: build the image and run the container. The only local check available for shell changes is a syntax pass — `bash -n bin/whereq-db lib/common.sh`, and `bash -n docker-entrypoint.sh llm-doctor.sh dedupe-binaries.sh` inside `whereq-llm-cli/` (the scripts carry `# shellcheck` directives, but shellcheck is not installed here).

## Images and their non-obvious constraints

**whereq-db** — shared PostgreSQL 17 + PostGIS 3.5 + pgvector 0.8.0 cluster serving multiple apps. The base image choice (`imresamu/postgis:17-3.5-alpine`, not official `postgres` + apk postgis) is load-bearing: the official Alpine postgres lives in `/usr/local` so Alpine's apk postgis package never links against it, the Alpine postgres uid (70) matches the existing host data dir, and the PROD host is arm64 which `postgis/postgis` doesn't publish. pgvector is likewise built **from source** in the Dockerfile, for the same prefix reason (the Alpine apk build targets a different PostgreSQL) — but the extension is only *available*, not enabled cluster-wide; `CREATE EXTENSION vector` belongs in each app's own migrations, same as PostGIS. `init.sql` runs only against a fresh/empty data directory (cluster-wide extensions only). Data is on a host bind mount, so rebuilds never lose data.

**whereq-db has two overlapping control surfaces.** `bin/whereq-db` is the canonical cross-app lifecycle (local + prod, one script). The image directory also carries PROD-compose-oriented per-directory scripts — `whereq-db/build.sh`, `backup.sh`, `restart.sh`, `status.sh` and `docker-compose-prod.yml` — which operate on the PROD compose file. Both read the same `whereq-db/.env`, but with **different variable names**: `bin/whereq-db` uses `WHEREQ_DB_*` (image/container/network/port/data) plus `POSTGRES_USER|DB|PASSWORD`, while `docker-compose-prod.yml` uses `POSTGRES_*` plus `DB_PORT` and `POSTGRES_DATA_PATH`. `whereq-db/.env.example` therefore lists the union — keep `WHEREQ_DB_PORT`/`DB_PORT` and `WHEREQ_DB_DATA`/`POSTGRES_DATA_PATH` in step.

**whereq-hermes** — Hermes Agent (Nous Research) on its own, 895 MB, **published publicly on Docker Hub** as `whereq/hermes-agent:latest` and `:v1.0.0` (digest `sha256:8c73cd9732db…`, 0.21 GB compressed, `linux/amd64`): the agent plus its Python runtime, nothing else. It is the *same* Hermes release the `whereq-llm-cli` image bundles (`v0.22.5`, upstream commit `bf0203a7`) — keep `HERMES_VERSION`, `HERMES_COMMIT` and `HERMES_PYTHON_VERSION` in step between the two. It is installed from a **source checkout**, not a wheel: upstream blocks wheel/sdist builds outside Nix (`setup.py` raises unless `HERMES_NIX_BUILD=1`) and publishes no prebuilt artifacts, so the build does an editable install (`uv sync --frozen` against the shipped `uv.lock`) at `/opt/hermes`; a wheel would also drop the bundled assets (locales, skills, optional-mcps, plugin manifests). **CPython 3.14** (`python:3.14.9-slim-bookworm`) because upstream's pyproject gates every direct dependency behind `python_version >= '3.14'` and `uv.lock` is resolved for 3.14 only. Three entry points ship: `hermes` (interactive, the default CMD), `hermes-agent` (batch), `hermes-acp` (editor adapter). The install stamp (`install-stamp.json` + `.install_method=docker`) is what makes `hermes --version` report the real version instead of `vunknown`. State lives under `HERMES_HOME=/config/hermes` (memories, skills, sessions, logs, `state.db`, `profiles/<name>/`), with `/config/.local` holding the per-profile launcher wrappers Hermes writes into `~/.local/bin`. The runtime user is `hermes` at uid 1000 and the entrypoint drops privileges with `setpriv` (tini is PID 1), adopting a mounted directory **only when it is still root-owned** — chowning a host-owned directory would change ownership outside the container. `HERMES_UID`/`HERMES_GID` are **build args**, not just runtime env: the build arg is what owns the volumes, so changing them makes compose rebuild. Handing the tree over with `COPY --chown` rather than a builder-side `chown -R` is deliberate — the latter copies every file into a second layer and cost 170 s of build time.

**whereq-ollama** — Ollama server with 1B/3B/7B-class models baked into the image at build time: a `model-bake` stage starts `ollama serve` in the background, pulls the models sequentially (to avoid OOM), and the runtime stage copies the populated `/root/.ollama` store. First build downloads ~10–15 GB. `helm/all-in-one.txt` is a reference dump of a Helm chart for running Hermes + Ollama on Kubernetes, not part of the Docker build.

**whereq-ollama-mistral7b** — same `model-bake`/runtime pattern as `whereq-ollama`, but pins all three tiers to non-Chinese models (`gemma3:1b`, `llama3.2:3b`, `mistral:7b`) — the 7B choice is deliberate: Qwen/DeepSeek/Yi/GLM are Chinese-origin, Llama's smallest dense tier is 8B, so Mistral 7B is the lightest well-supported non-Chinese 7B. Swap tiers via `MODEL_1B`/`MODEL_3B`/`MODEL_7B` build args.

**The two Ollama images are alternatives, not a fleet**: both compose files publish host port `11434` and mount `/root/.ollama`, so only one can run per host — change `ports:` before starting the other. They are separate because each bakes a different model set into its own image.

**whereq-llm-cli** — portable toolbox image bundling **four** agentic CLIs (Claude Code, Codex, Copilot, Hermes Agent) on Node LTS + CPython 3.15 from `python-build-standalone`, so a CLI can clone a repo, write and run a throwaway script, and commit without installing anything at runtime. Two stages, **amd64 only**, 70 pinned Python packages (176 distributions installed), current image **5.65 GB** uncompressed (4.91 GB with `INSTALL_HERMES=0`). **It has its own `whereq-llm-cli/CLAUDE.md` — that file is authoritative for this image; read it before changing anything here.** Non-obvious constraints, all of them learned by building it:

- Gemini CLI, Qwen Code, opencode, Crush, Goose, aider and aichat were **deliberately dropped** to keep the image scoped to the CLIs actually in use — the old 7.2 GB / 1.8 GB compressed size and the aider venv are gone. `whereq-llm-cli/CLAUDE.md` and its `README.md` say "see git history" to resurrect one, but the directory is still untracked in git, so there is no history for it — the dropped components have to be re-added from scratch.
- The npm CLIs must install in **one** `npm install` — splitting them across layers makes each install prune the others, because npm treats `--prefix` as its project and removes "extraneous" packages. This stays relevant when adding a fourth CLI.
- **Hermes Agent is the exception to that rule** — it is a Python package installed from a **source checkout**, because upstream blocks wheel/sdist builds outside Nix and publishes no prebuilt artifacts. The build does an editable install (`uv sync --frozen` against the shipped `uv.lock`) at `/opt/hermes`; a wheel would also silently drop the bundled assets (locales, skills, plugin manifests).
- **Hermes needs its own CPython 3.14** (`/opt/python314`) — upstream pins `requires-python <3.15` and gates every direct dependency behind `python_version >= '3.14'`, because 3.14 is the newest CPython its Rust-backed deps ship wheels for. Its venv (`/opt/hermes/.venv`) is deliberately **off** `PATH` so `python3` still means the shared 3.15 for every other tool; only the three console scripts are symlinked into `/usr/local/bin`.
- **All Hermes state lives in `/config/hermes`** via `HERMES_HOME` — the default profile's memories, skills, sessions, logs, `state.db`, plus one directory per named profile under `profiles/<name>/`. `HERMES_HOME` is honoured completely: with it set, Hermes never creates `~/.hermes`. The `~/.hermes` symlink only covers the native-home fallback.
- Hermes writes per-profile launcher shims into `~/.local/bin` when a profile is created, so the whole `~/.local` tree is symlinked to `/config/.local` and `/config/.local/bin` is on `PATH` — the shims survive a container recreate.
- The builder stage needs `PATH=/opt/node/bin` explicitly; the runtime `ENV PATH` does not apply to the builder, and `npm` is simply not found without it.
- `ubuntu:26.04` ships a stock `ubuntu` user at uid/gid 1000 — it must be deleted (or renamed) before the runtime user can take those ids.
- Never `chown -R /opt` in the runtime stage: overlayfs copies every file up into a second layer (6.4 GB). Hand the toolchains to the runtime uid **in the builder** instead; `COPY` preserves the ownership.
- Claude Code's postinstall copies its native binary into the package's `bin/` — a second byte-identical copy (280 MB). `dedupe-binaries.sh` swaps it for a symlink by content hash; it currently handles only `@anthropic-ai/claude-code/bin/claude.exe`.
- On Debian/Ubuntu the binaries are `fdfind` and `batcat`; symlink them to `fd` and `bat`.
- The entrypoint drops privileges *before* loading the provider config, otherwise the re-exec prints every message twice. It only `chown`s `/config` and `/workspace` when they are **still root-owned** — chowning a directory that already belongs to the host user would silently change ownership on the host side.
- `tini` is PID 1 (these CLIs spawn process trees: MCP servers, shells, git) and `setpriv` does the privilege drop.
- `litellm` is deliberately absent from the base Python stack: it pins `openai<3` and `huggingface-hub<2`, which would drag the LLM SDKs a major version back. Add it via `--build-arg PYTHON_EXTRAS=litellm`.
- `.dockerignore` is an allowlist (`*` plus explicit `!` entries) so the build context stays tiny.
- The image is **published publicly on Docker Hub** as `whereq/llm-cli:latest` and `whereq/llm-cli:v1.1.0` (same image, digest `sha256:b5c44b4c3af9…`, 1.45 GB compressed / 5.65 GB uncompressed, `linux/amd64` only). `docker pull` it rather than building, when the local build is not needed. `v1.0.0` is the older pre-Hermes build (4.91 GB) and stays published.

The entrypoint fans one canonical triple (`WQ_API_KEY` / `WQ_BASE_URL` / `WQ_MODEL`) onto each CLI's own env var names, loading a profile from `/etc/llm/providers/<name>.env` (shadowed by `/config/providers/`). DeepSeek and MiniMax speak Anthropic's protocol on a *different* path than their OpenAI-compatible one, so their profiles also set `WQ_ANTHROPIC_BASE_URL`, which only affects `ANTHROPIC_BASE_URL`. All state lives under `/config`; `/workspace` is the code and the CLI's working directory.

## Cross-stack wiring

The hermes and ollama stacks are separate compose projects. To let Hermes use the local Ollama, uncomment the `networks:` block in `whereq-hermes/docker-compose.yml` (it joins the external `whereq-ollama_default` network) and set `OLLAMA_HOST: http://ollama:11434`.

## Cloudflare tunnels (PROD)

`cloudflare/README.md` is the infra design doc for how the WhereQ Universe exposes services on the PROD host ("mini server") via Cloudflare Tunnels — not part of the Docker build, but read it before changing anything tunnel- or ingress-related. Key facts it establishes:

- **Two Cloudflare accounts, two tunnels, two connector processes** (irreducible — one connector = one tunnel = one account). The whereq-family tunnel runs as a **host systemd service** (`cloudflared.service`) and reaches apps via `http://localhost:<host-port>`; it cannot use container names. The ccbus tunnel (currently just `buzz-api`) runs as a **Docker container inside buzz's own compose**, on `whereq-network`, and routes by container name.
- Ingress (hostname → service) is configured entirely in each account's **Cloudflare Zero Trust dashboard** — there is no local `config.yml` and no tunnel ID/token committed to this repo.
- To expose a new whereq-family app: publish a host port on its frontend (the `808x` convention, next free is **8084** per the port registry at the bottom of the doc), add a Public Hostname in the whereq dashboard pointing at `http://localhost:<port>`, and register the URL with Keycloak (realm `flowdesk.top`, client `flowdesk-spa`) if it's an SPA.

**Architecture constraints on the PROD host.** The PROD mini server is **arm64**. `whereq-llm-cli` is **amd64-only** (no `TARGETARCH` resolution in its Dockerfile), so it cannot run on PROD as it stands — re-add arch resolution there first if that changes. `whereq-db`'s base image choice (`imresamu/postgis:17-3.5-alpine`) is likewise arm64-driven, because `postgis/postgis` publishes no arm64 build.

## Repo state

Most of the tree is still untracked in git — only `whereq-db/Dockerfile`, `whereq-db/init.sql`, and `cloudflare/README.md` are committed, and the old ASCII-art root `README.md` is deleted in the working tree. Don't read git history as a description of the current layout, and check `git status` before assuming a file is versioned.

In particular `whereq-llm-cli/` is **entirely untracked** — including its own `CLAUDE.md`. Anything that says "see git history" about that directory (its `README.md` and `CLAUDE.md` both do, about the dropped Gemini/Qwen/opencode/Crush/Goose/aider/aichat CLIs) has no history to point at; those components must be re-added from scratch rather than reverted.
