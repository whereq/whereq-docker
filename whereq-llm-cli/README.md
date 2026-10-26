# whereq-llm-cli — a portable LLM CLI toolbox

One container with Claude Code, Codex, Copilot and Hermes Agent, a full Node +
Python toolchain, and the shell utilities they reach for — so a CLI can clone
a repo, write a throwaway Python script, run it, and commit, without installing
anything at runtime.

| Component | Pinned version | Notes |
|---|---|---|
| Base | `ubuntu:26.04` | latest LTS, amd64 only |
| Claude Code | `@anthropic-ai/claude-code` 2.1.309 | Anthropic |
| OpenAI Codex | `@openai/codex` 0.163.0 | OpenAI + OpenAI-compatible gateways |
| GitHub Copilot CLI | `@github/copilot` 1.0.103 | needs a GitHub token |
| Hermes Agent | `hermes-agent` v0.22.5 | Nous Research; brings its own CPython 3.14 |
| Node.js | 24.22.1 LTS | + npm 11 |
| CPython | 3.15.1 | python-build-standalone, i.e. the same interpreter `uv` manages |
| Python libs | 70 pinned → 176 installed | numpy/pandas/scipy/sklearn/matplotlib, httpx/aiohttp, bs4/lxml, FastAPI/Flask, SQLAlchemy/psycopg, openai/anthropic, python-docx/pptx/pypdf, pytest/ruff/black/mypy |

Gemini CLI, Qwen Code, opencode, Crush, Goose, aider and aichat were dropped to
keep the image scoped to the CLIs actually in use — resurrecting one means
rebuilding it from scratch (this directory is untracked in git, so there is no
history to revert to). arm64 support was dropped at the same time; re-add
`TARGETARCH`-based arch resolution in the Dockerfile if a host needs it again.

## Published image

Public on Docker Hub, `linux/amd64` only:

```bash
docker pull whereq/llm-cli:latest      # also tagged v1.1.0
```

Digest `sha256:b1564d9180b1…` — 17 layers, **1.45 GB compressed** / 5.65 GB
uncompressed. The `v1.1.0` and `latest` tags point at the same image.

`v1.1.0` is the Hermes Agent release; `v1.0.0` is the pre-Hermes image
(4.91 GB) and stays available for anyone who wants the smaller footprint.
`INSTALL_HERMES=0` still builds that smaller image locally.

Run it:

```bash
docker run --rm -it \
  -v llm-config:/config -v "$PWD":/workspace \
  -e LLM_PROVIDER=anthropic -e WQ_API_KEY=sk-ant-… \
  whereq/llm-cli:latest claude
```

## Quick start

```bash
cp .env.example .env          # set LLM_PROVIDER + WQ_API_KEY
docker compose build
docker compose run --rm llm-cli                  # interactive shell
docker compose run --rm llm-cli claude          # Claude Code
docker compose run --rm llm-cli codex "review this repo"
docker compose run --rm llm-cli hermes          # → Hermes Agent
docker compose run --rm llm-cli llm-doctor      # what is installed, is it wired up
```

Without compose:

```bash
docker build -t whereq/llm-cli .
docker run --rm -it \
  -v llm-config:/config -v "$PWD":/workspace \
  -e LLM_PROVIDER=anthropic -e WQ_API_KEY=sk-ant-… \
  whereq/llm-cli claude
```

## Running a CLI in your project

`/workspace` is the working directory for every CLI — `WORKDIR /workspace` — and
it is a bind mount of a directory **you** choose. So the CLI starts in your
project root and writes there:

```
your-project/                 ← host, bind-mounted to /workspace
├── CLAUDE.md                 ← project memory: created/updated by /init or
│                                /memory inside `claude`, written straight
│                                through to the host
├── src/ …                    ← edited and committed by the CLI
└── .git/
```

Point it at a project in whichever way fits:

```bash
# 1. once, in .env
WORKSPACE=/home/you/code/my-project

# 2. per run, overriding the mount
docker compose run --rm -v "$PWD":/workspace llm-cli claude

# 3. from anywhere, without touching .env
docker compose -f ~/git/whereq-docker/whereq-llm-cli/docker-compose.yml \
  run --rm -v "$PWD":/workspace llm-cli codex
```

Two scopes of `CLAUDE.md`, both persistent:

| Scope | Path | Persists via |
|---|---|---|
| Project (per repo) | `/workspace/CLAUDE.md` | your host directory |
| User (all projects) | `/config/claude/CLAUDE.md` | the `llm_config` volume |

Writes need the container user to own the project. The entrypoint adopts
`/workspace` only when it is still root-owned (a fresh named volume, or one
Docker just created) — it never chowns a host directory that already belongs
to you. (`/config`, the container's own state, is adopted recursively, but
only for files still owned by root.)
When your project belongs to a different uid the container prints exactly how to
fix it, either per run:

```bash
docker compose run --rm -e WQ_UID="$(id -u)" -e WQ_GID="$(id -g)" llm-cli claude
```

or permanently, with `--build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)"`.

`git config --global` also persists now (`GIT_CONFIG_GLOBAL=/config/gitconfig`),
so the identity you set once — plus the `safe.directory` entry the entrypoint
adds — survives container restarts. Mount read-only (`:ro`) if you only want the
CLI to read the code.

## State: two mounts, nothing else

| Path | What lives there |
|---|---|
| `/config` | every credential, session, history and per-CLI config file |
| `/workspace` | your code (the default working directory) |

`/config` is arranged so one volume persists everything:

```
/config/env                     ← optional single file you mount with your keys
/config/providers/<name>.env    ← optional per-backend overrides
/config/claude  codex  copilot
/config/hermes                  ← ALL of Hermes' state (see below)
/config/.config  .local/share  .local/state  .local/bin  .cache   ← XDG dirs
```

The per-CLI dotdirs (`~/.claude`, `~/.codex`, …) are symlinks into `/config`,
and `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `HERMES_HOME` point at the same
places, so Claude Code, Codex and Hermes stay in the mounted volume however
they look up their config. The XDG vars are redirected too, for anything that
only honours those.

Mount only what you need to share:

```bash
-v ./llm-keys.env:/config/env:ro                     # all keys in one file
-v ./deepseek.env:/config/providers/deepseek.env:ro  # one backend override
-v ./agent-memory:/config/claude:/config/claude      # just Claude's history
```

## Hermes Agent

Hermes (Nous Research) ships with the image and gets its own CPython 3.14 at
`/opt/python314` — upstream caps it at `<3.15` because 3.14 is the newest
CPython its Rust-backed dependencies ship wheels for. The shared `python3`
stays 3.15; only Hermes uses 3.14.

```bash
docker compose run --rm llm-cli hermes                       # interactive
docker compose run --rm llm-cli hermes-agent "summarise this repo"  # batch
docker compose run --rm llm-cli hermes-acp                    # editor adapter
```

### Where Hermes keeps its state

Everything lives under **`HERMES_HOME=/config/hermes`**, so it is all in the
mounted volume and survives a container recreate:

```
/config/hermes/
├── config.yaml          ← profile configuration
├── .env                 ← profile secrets
├── state.db             ← session/memory database
├── memories/            ← MEMORY.md, USER.md — the agent's long-term memory
├── skills/              ← skills for the default profile
├── sessions/  logs/  cron/  cache/  hooks/
├── active_profile       ← which profile is selected
└── profiles/<name>/     ← one directory per named profile, same layout
```

A **profile** is a full parallel identity — its own config, `.env`, memories,
skills, sessions and workspace:

```bash
docker compose run --rm llm-cli hermes profile create work
docker compose run --rm llm-cli hermes profile list
docker compose run --rm llm-cli hermes -p work          # use it
docker compose run --rm llm-cli work                     # or the wrapper
```

Creating a profile also drops a launcher shim into `~/.local/bin`. The whole
`~/.local` tree is symlinked to `/config/.local` and `/config/.local/bin` is on
`PATH`, so those wrappers persist and are directly runnable.

### Skills

Skills are plain directories with a `SKILL.md`. They are read from three
places, in precedence order:

1. the active profile's `skills/` (where the agent writes new ones)
2. `skills.external_dirs` in `config.yaml` — extra read-only directories,
   `~`/`${VAR}`-expanded and resolved relative to `HERMES_HOME`
3. project-local skills under `<workspace>/.hermes/skills/`

Project-local skills need the project **trusted** first — a repo's skills are
a code-execution surface, so upstream requires an explicit opt-in per root:

```bash
docker compose run --rm llm-cli hermes skills trust /workspace
# → Trusted: /workspace
#   1 project skill(s) will load in sessions started inside this repo
```

The trust lands in `config.yaml` (`skills.trusted_project_dirs`) and persists
in the mounted volume. `hermes skills list` shows only *installed* skills;
project skills are reported by the trust command and load into sessions.

```bash
# point at a shared team skills directory
docker compose run --rm llm-cli hermes config set skills.external_dirs '["/config/hermes/shared-skills"]'
docker compose run --rm llm-cli hermes skills list
docker compose run --rm llm-cli hermes skills search "deploy"
```

### Backends

Hermes reads the same `ANTHROPIC_*` / `OPENAI_*` / `GEMINI_*` variables the
other CLIs use, so `LLM_PROVIDER` selects the backend for it too. Two extras
are mapped for Hermes: `WQ_MODEL` becomes `HERMES_MODEL`, and for the `ollama`
provider `OLLAMA_HOST` is set (with the `/v1` suffix stripped) so Hermes does
its own model discovery against the local Ollama.

```bash
LLM_PROVIDER=ollama docker compose run --rm llm-cli hermes
```

## Switching backends

Set `LLM_PROVIDER` to a profile name. Profiles live in the image
(`/etc/llm/providers/`) and are shadowed by anything you put in
`/config/providers/`:

| `LLM_PROVIDER` | Endpoint | Notes |
|---|---|---|
| `anthropic` | `https://api.anthropic.com` | default |
| `openai` | `https://api.openai.com/v1` | |
| `gemini` | `https://generativelanguage.googleapis.com` | |
| `deepseek` | `https://api.deepseek.com` | plus an Anthropic-compatible path for Claude Code |
| `minimax` | `https://api.minimax.io/v1` | plus an Anthropic-compatible path |
| `openrouter` | `https://openrouter.ai/api/v1` | one key, every model |
| `ollama` | `http://host.docker.internal:11434/v1` | local inference; needs `extra_hosts` (compose sets it) |
| `custom` | yours | copy `providers/custom.env` to `/config/providers/` |

You never have to know each CLI's variable names. The entrypoint maps one
canonical triple onto all of them:

```
WQ_API_KEY  →  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, GOOGLE_API_KEY
WQ_BASE_URL →  ANTHROPIC_BASE_URL, OPENAI_BASE_URL, GOOGLE_GEMINI_BASE_URL
WQ_MODEL    →  ANTHROPIC_MODEL, OPENAI_MODEL, GEMINI_MODEL
```

so the same `-e WQ_API_KEY=… -e WQ_BASE_URL=…` configures Claude Code and Codex
simultaneously. Anything you pass with `docker -e` or in compose wins over the
mapping.

Two backends speak Anthropic's protocol on a *different* path than their
OpenAI-compatible one (DeepSeek, MiniMax) — those profiles set
`WQ_ANTHROPIC_BASE_URL` too, which is what Claude Code needs.

Copilot is the exception: it authenticates with a GitHub account, so pass
`GITHUB_TOKEN` (or run `copilot` once and complete the device login — the
credentials land in `/config/copilot`).

### Local Ollama

```bash
# host-installed Ollama
LLM_PROVIDER=ollama docker compose run --rm llm-cli codex

# the whereq-ollama container: attach to its network and use its name
docker network connect whereq-ollama_default llm-cli
# then WQ_BASE_URL=http://ollama:11434/v1 in /config/providers/ollama.env
```

## Size

Dropping Gemini CLI, Qwen Code, opencode, Crush, Goose, aider and aichat (and
their second Python interpreter and `/opt/bin` binaries) cut the image
substantially below the old 7.2 GB uncompressed / 1.8 GB compressed. Rebuild
and check `docker images` for the current number — the remaining weight is:

| Part | What it is |
|---|---|
| `/opt/hermes` | Hermes Agent source checkout + its venv (~420 MB) |
| `/opt/npm` | Claude Code, Codex, Copilot and their native binaries |
| `/opt/python` | CPython 3.15 + the 176-package stack |
| `/opt/python314` | CPython 3.14, for Hermes only (111 MB) |
| `/usr` | apt toolbox, gcc, ffmpeg, ImageMagick |
| `/opt/node` | Node 24 LTS |

The image is **5.65 GB** with Hermes, 4.91 GB without.

Trim it further with build args — measured savings:

```bash
--build-arg INSTALL_HERMES=0         # −740 MB (drops Hermes Agent and its CPython 3.14)
--build-arg INSTALL_BUILD_TOOLS=0   # −380 MB (drops gcc; pip installs of sdists stop working)
--build-arg INSTALL_MEDIA=0         # −200 MB (drops ffmpeg + ImageMagick)
--build-arg INSTALL_CODEX=0         # −410 MB
```

Two things keep it smaller than the sum of its parts: the toolchains are
handed to the runtime user **in the builder** (a `chown -R` in the runtime
stage would copy every file up into a second layer — that alone was 6.4 GB),
and `dedupe-binaries.sh` replaces the duplicate copy Claude Code's postinstall
makes of its own native binary.

## Customising the image

Every version is a build arg; every component has an `INSTALL_*` switch.

```bash
docker build -t whereq/llm-cli \
  --build-arg CLAUDE_CODE_VERSION=2.1.310 \
  --build-arg PYTHON_VERSION=3.14.9 \
  --build-arg PYTHON_EXTRAS="datasets jupyterlab" \
  --build-arg INSTALL_MEDIA=0 \
  --build-arg INSTALL_BUILD_TOOLS=0 \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  .
```

- `PYTHON_EXTRAS` — extra pip packages appended to the pre-installed stack.
- `INSTALL_MEDIA=0` — drop ffmpeg + imagemagick (a few hundred MB).
- `INSTALL_BUILD_TOOLS=0` — drop gcc/make; `pip install` then only works for
  packages with wheels.
- `USER_UID` / `USER_GID` — match your host user so bind-mounted files are
  writable. `WQ_UID` / `WQ_GID` do the same thing at runtime.
- `PYTHON_VERSION` — moving to a brand-new CPython may mean some packages have
  no wheel yet and fall back to an sdist (the builder has a compiler, so it
  still builds).

Adding a new Python package permanently: add it to
`requirements/python-base.txt` (pinned) and rebuild.

### User and privileges

The image runs as a non-root `llm` user (uid 1000). Started as root, the
entrypoint chowns the mounted volumes and drops privileges via `setpriv`;
otherwise it warns when the uid does not match the image user. `tini` is PID 1,
so the process trees these CLIs spawn get reaped.

## What's inside

- **Shells/tooling** — bash, git (+ git-lfs), curl, wget, jq, rg, fd, fzf, bat,
  tree, less, nano, vim-tiny, tmux, htop, lsof, iputils, dnsutils, netcat,
  socat, rsync, unzip/zip/xz/zstd, iproute2, procps.
- **Build** — build-essential, pkg-config, libyaml/libffi/libssl headers.
- **Media** — ffmpeg, ImageMagick.
- **Node** — `/opt/node/bin` (node, npm, npx).
- **Python** — `/opt/python/bin` (python3, python, pip) plus `uv` for
  `uv pip install` / `uv run --with <pkg>` one-off scripts.

`git config --global --add safe.directory '*'` is set on start, so repositories
mounted from another uid are usable.

## Notes

- **Node LTS, not Current.** Claude Code needs ≥22 and every package here is
  tested against LTS; move to Node 26 with `NODE_VERSION=26.12.1` if you want
  it.
- **Why CPython comes from `python-build-standalone`** rather than apt or
  deadsnakes: it is the newest stable CPython available and it is the same
  interpreter `uv` manages, so `uv run` and `python3` agree. The distro's
  `python3` is untouched.
- **npm CLIs install in one `npm install`.** Splitting them across layers makes
  each install prune the previous ones, because npm treats `--prefix` as its
  project and removes "extraneous" packages.
- **litellm is not in the base stack.** It pins `openai<3` and
  `huggingface-hub<2`, which would force the LLM SDKs a major version back.
  Add it explicitly if you want its unified interface:
  `--build-arg PYTHON_EXTRAS=litellm`.
- **Hermes is installed from source, not a wheel.** Upstream blocks wheel and
  sdist builds outside Nix (`setup.py` raises unless `HERMES_NIX_BUILD=1`) and
  publishes no prebuilt artifacts, so the build does an editable install with
  `uv sync --frozen` against the shipped `uv.lock`. A wheel would also drop
  the bundled assets (locales, skills, optional-mcps, plugin manifests) that
  Hermes resolves from its install directory.
- **`/opt` is owned by the runtime user**, so `pip install …`, `uv pip install
  --system …` and `npm i -g` all work inside a running container. Those changes
  die with the container — rebuild to make them permanent.
- **Checksums.** Node and uv downloads are verified against the publisher's
  checksum file; the rest come over authenticated HTTPS.
- **Architecture.** `linux/amd64` only. arm64 support was dropped along with the
  other CLIs — re-add `TARGETARCH`-based arch resolution in the Dockerfile if an
  arm64 host ever needs it. (The PROD mini-server host is amd64, so this image
  runs there as it stands.)

## Files

- `Dockerfile` — builder/runtime stages
- `docker-entrypoint.sh` → `/usr/local/bin/llm-entrypoint`
- `llm-doctor.sh` → `/usr/local/bin/llm-doctor`
- `dedupe-binaries.sh` — replaces the CLIs' duplicated native binaries with symlinks
- `requirements/python-base.txt` — pinned Python stack (the shared CPython)
- `providers/*.env` — backend profiles (`LLM_PROVIDER=<basename>`)
- `docker-compose.yml`, `.env.example`
