# whereq-hermes — Hermes Agent in a container

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research) on
its own: the agent, its Python runtime, and its state — nothing else. If you
want the agent *plus* Claude Code, Codex, Copilot and a full shell toolbox, use
[`whereq-llm-cli`](../whereq-llm-cli) instead; it bundles this same Hermes
release.

| Component | Version | Notes |
|---|---|---|
| Hermes Agent | `v0.22.5` | upstream commit `bf0203a7`; installed from a source checkout |
| CPython | 3.14.9 | `python:3.14.9-slim-bookworm`; 3.14 is the newest CPython Hermes' Rust-backed deps ship wheels for |
| uv | 0.13.5 | resolves the upstream `uv.lock` verbatim (`--frozen`) |
| Base | `debian:bookworm-slim` | + `tini` (PID 1), `git`, `curl`, `ripgrep`, `jq` |

Three entry points ship:

```bash
hermes                       # the interactive CLI (the default CMD)
hermes-agent "summarise …"   # non-interactive / batch
hermes-acp                   # ACP adapter for editor integrations
```

Image size: **895 MB** uncompressed.

## Published image

Public on Docker Hub, `linux/amd64`:

```bash
docker pull whereq/hermes-agent:latest      # also tagged v1.0.0
```

Digest `sha256:8c73cd9732db…` — 11 layers, **0.21 GB compressed** / 895 MB
uncompressed.

## Quick start

```bash
cp .env.example .env          # set WQ_API_KEY (and LLM_PROVIDER)
docker compose build
docker compose run --rm hermes                              # → interactive
docker compose run --rm hermes hermes-agent "summarise the README"
```

Without compose:

```bash
docker build -t whereq/hermes-agent .
docker run --rm -it \
  -v hermes_home:/config/hermes -v "$PWD":/workspace \
  -e WQ_API_KEY=sk-… whereq/hermes-agent hermes
```

## Where Hermes keeps its state

Everything lives under **`HERMES_HOME=/config/hermes`**, so it all sits in the
mounted volume and survives a container recreate:

```
/config/hermes/
├── config.yaml          ← profile configuration (incl. skills.trusted_project_dirs)
├── .env                 ← profile secrets
├── state.db             ← session/memory database
├── memories/            ← MEMORY.md, USER.md — the agent's long-term memory
├── skills/              ← skills for the default profile
├── sessions/  logs/  cron/  cache/  hooks/  installs/
├── active_profile       ← which profile is selected
└── profiles/<name>/     ← one directory per named profile, same layout
```

`HERMES_HOME` is honoured completely — with it set, Hermes never creates
`~/.hermes`. The `~/.hermes` symlink in the image only covers the native-home
fallback path.

A second volume, `/config/.local`, holds the per-profile launcher wrappers
Hermes writes into `~/.local/bin` (see below).

## Profiles

A **profile** is a full parallel identity — its own config, `.env`, memories,
skills, sessions and workspace:

```bash
docker compose run --rm hermes hermes profile create work
docker compose run --rm hermes hermes profile list
docker compose run --rm hermes hermes -p work          # use it
docker compose run --rm work                           # or the wrapper
```

Creating a profile also drops a launcher shim into `~/.local/bin`. The whole
`~/.local` tree is mounted from `/config/.local` and `/config/.local/bin` is on
`PATH`, so those wrappers persist across a container recreate and are directly
runnable.

## Skills

Skills are plain directories holding a `SKILL.md`. They load from three
places, in precedence order:

1. the active profile's `skills/` (where the agent writes new ones)
2. `skills.external_dirs` in `config.yaml` — extra read-only directories,
   `~`/`${VAR}`-expanded and resolved relative to `HERMES_HOME`
3. project-local skills under `<project>/.hermes/skills/`

**Project-local skills need the project trusted first** — a repo's skills are
a code-execution surface, so upstream requires an explicit opt-in per root:

```bash
docker compose run --rm hermes hermes skills trust /workspace
# → Trusted: /workspace
#   1 project skill(s) will load in sessions started inside this repo
```

The trust lands in `config.yaml` (`skills.trusted_project_dirs`) and persists in
the mounted volume. `hermes skills list` only shows *installed* skills; project
skills are reported by the trust command and load into sessions.

Shared team skill directories:

```bash
docker compose run --rm hermes hermes config set skills.external_dirs '["/config/hermes/shared-skills"]'
docker compose run --rm hermes hermes skills search "deploy"
```

## Backends

Hermes reads the same `ANTHROPIC_*` / `OPENAI_*` / `GEMINI_*` variables the
other WhereQ images use, so one canonical triple selects the backend:

```
WQ_API_KEY  →  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, GOOGLE_API_KEY
WQ_BASE_URL →  ANTHROPIC_BASE_URL, OPENAI_BASE_URL
WQ_MODEL    →  HERMES_MODEL, ANTHROPIC_MODEL, OPENAI_MODEL
```

Anything you pass with `docker -e` or in compose wins over the mapping. A
single-file drop-in works too:

```bash
docker compose run --rm -v ./hermes-keys.env:/config/env:ro hermes
```

### Local Ollama

Hermes reaches Ollama through `OLLAMA_HOST` (it does its own model discovery
there), not through the OpenAI-compatible path — so set it directly:

```bash
# a host-installed Ollama
OLLAMA_HOST=http://host.docker.internal:11434 docker compose run --rm hermes

# the whereq-ollama container: join its network and use its name
docker network connect whereq-ollama_default <container>
OLLAMA_HOST=http://ollama:11434 docker compose run --rm hermes
```

With `LLM_PROVIDER=ollama`, `WQ_BASE_URL` is reused as `OLLAMA_HOST` and the
`/v1` suffix is stripped.

## The workspace

`/workspace` is the working directory — the project Hermes operates on:

```
your-project/                 ← host, bind-mounted to /workspace
├── .hermes/skills/           ← project-local skills (trusted per root)
├── src/ …                    ← edited and committed by the agent
└── .git/
```

Point it at a project with `WORKSPACE` in `.env`, or override per run:

```bash
docker compose run --rm -v "$PWD":/workspace hermes
```

## Permissions

The container runs as a non-root `hermes` user (uid 1000). It starts as root,
adopts the mounted volumes, then drops privileges with `setpriv` — `tini` stays
PID 1 so the process trees Hermes spawns get reaped.

A directory is only adopted when it is **still root-owned** (a fresh named
volume, or one Docker just created). A directory that already belongs to
somebody else is left alone: chowning it would silently change ownership on
the *host* side.

If your host uid is not 1000, set it in `.env` and rebuild — the uid is a
build arg, so the volumes get the right ownership:

```bash
HERMES_UID=$(id -u) HERMES_GID=$(id -g)   # in .env
docker compose build
```

The entrypoint warns, rather than failing, when the state directory or the
workspace is not writable.

## Files

- `Dockerfile` — three stages (uv → builder → runtime), non-root, tini as PID 1
- `docker-entrypoint.sh` → `/usr/local/bin/hermes-entrypoint`
- `docker-compose.yml` — one service, two volumes, `.env` for configuration
- `.env.example` — copy to `.env` (gitignored) and edit
- `.dockerignore` — keeps the build context small

## Upgrading Hermes

1. Check the [latest release](https://github.com/NousResearch/hermes-agent/releases).
2. Update `HERMES_VERSION` **and** `HERMES_COMMIT` in `docker-compose.yml`
   (the commit goes into the install stamp, so `hermes --version` stays
   truthful) — and keep both in step with `whereq-llm-cli`, which bundles the
   same release.
3. Rebuild: `docker compose build`.

`HERMES_VERSION` is the upstream **semver release tag** (`v0.22.5`), not one of
the legacy `v2026.*` date tags.

## Notes

- **Hermes is installed from source, not a wheel.** Upstream blocks wheel and
  sdist builds outside Nix (`setup.py` raises unless `HERMES_NIX_BUILD=1`) and
  publishes no prebuilt artifacts, so the build does an editable install with
  `uv sync --frozen` against the shipped `uv.lock`. A wheel would also drop
  the bundled assets (locales, skills, optional-mcps, plugin manifests) that
  Hermes resolves from its install directory at runtime.
- **The install stamp is what makes `hermes --version` truthful.** Without
  `install-stamp.json` (written by upstream's own `scripts/write_install_stamp.py`)
  and the `docker` marker in `.install_method`, the CLI reports `vunknown` and
  the update steward cannot tell that a package manager owns the tree.
- **The checkout is kept whole** (~426 MB at `/opt/hermes`). `tests/`,
  `apps/`, `website/` and `contributors/` look prunable, but runtime modules
  reference them to detect a source checkout and resolve assets.
- **`COPY --chown`, not `chown -R`.** Handing the tree to the runtime user in
  the builder instead costs a second full copy of every file into a new layer
  — it measured 170 s of build time on this tree.
- **This image is the agent, not the toolbox.** The system packages are
  deliberately minimal; for a full shell toolbox use `whereq-llm-cli`.
