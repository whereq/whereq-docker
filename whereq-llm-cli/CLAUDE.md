# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`whereq-llm-cli` is one Docker image that bundles three agentic LLM CLIs
(Claude Code, Codex, Copilot) plus a full Node + Python toolchain, so any of
them can clone a repo, write and run a throwaway script, and commit — without
installing anything at container runtime. It is `linux/amd64` only. Gemini
CLI, Qwen Code, opencode, Crush, Goose, aider and aichat (and arm64 support)
were deliberately dropped to keep the image scoped to the three CLIs actually
in use — re-adding one means rebuilding it from scratch, because this whole
directory is still untracked in git and there is no history to revert to. It
is part of the `whereq-docker` monorepo; see the repo-root `CLAUDE.md` for
conventions shared across all images (`lib/common.sh`, `bin/whereq-db`,
Cloudflare tunnel topology, etc.) — none of that is repeated here.

There is no app code here in the usual sense: the "source" is the Dockerfile,
one entrypoint script, provider profiles, and a pinned Python requirements
file. Verification means building the image and running `llm-doctor` inside it.

## Commands

```bash
cp .env.example .env                      # set LLM_PROVIDER + WQ_API_KEY
docker compose build
docker compose run --rm llm-cli                  # interactive shell
docker compose run --rm llm-cli claude           # launch a specific CLI
docker compose run --rm llm-cli llm-doctor       # what's installed, is it wired up

# syntax-only check for the shell scripts (no shellcheck installed here)
bash -n docker-entrypoint.sh llm-doctor.sh dedupe-binaries.sh

# without compose
docker build -t whereq/llm-cli .
docker run --rm -it -v llm-config:/config -v "$PWD":/workspace \
  -e LLM_PROVIDER=anthropic -e WQ_API_KEY=sk-ant-… whereq/llm-cli claude
```

Trim the image at build time with feature-switch build args
(`INSTALL_CLAUDE_CODE`, `INSTALL_CODEX`, `INSTALL_COPILOT`, `INSTALL_MEDIA`,
`INSTALL_BUILD_TOOLS`), or match host uid/gid with `USER_UID`/`USER_GID`
(build time) or `WQ_UID`/`WQ_GID` (run time). Every CLI/toolchain version is a
separate build arg — bump one in both the Dockerfile default and
`docker-compose.yml`'s `build.args` to move it forward; they must stay in sync.

Adding a Python package permanently: append it (pinned) to
`requirements/python-base.txt` and rebuild — it installs into the single shared
CPython at `/opt/python`. One-off packages at runtime: `uv pip install …` or
`uv run --with <pkg> script.py`.

## Architecture

**Two-stage Dockerfile, assembly-only runtime.** Everything that downloads or
compiles happens in the `builder` stage; the `runtime` stage only `COPY
--from=builder`s the finished artefacts (`/opt/node`, `/opt/npm`, `/opt/python`,
`/opt/uv/uv`) plus an apt-installed shell toolbox. No npm/apt/pip cache ever
reaches the final image.

**Ownership is set in the builder, never in runtime.** The builder's last step
`chown -R "${USER_UID}:${USER_GID}" /opt` before the runtime stage's `COPY`, so
ownership metadata comes along for free. A `chown -R /opt` done *after* the
`COPY` in the runtime stage would make overlayfs copy every file into a new
layer — this was measured at +6.4 GB and must never be reintroduced.

**One `npm install` for all npm-based CLIs.** `claude-code`, `codex` and
`copilot` install in a single `npm install -g --prefix /opt/npm $pkgs` call.
Splitting them into separate `RUN` layers makes each subsequent install prune
the previous CLIs — npm treats `--prefix` as its own project and removes
anything it considers "extraneous". This constraint stays relevant even at
three packages, so don't split them when adding a fourth.

**`dedupe-binaries.sh`** runs once, right after that npm install. Claude
Code's postinstall script copies its own native binary into the package's
`bin/` — a second 280 MB copy of the same file. The script content-hashes
every file over 10 MB under `/opt/npm/lib/node_modules`, and replaces exact
duplicates with relative symlinks. If a newly added CLI exhibits the same
postinstall-copy behavior, add a `dedupe "<path>"` line for it.

**Config lives in exactly one mounted volume, `/config`.** Every CLI's dotdir
(`~/.claude`, `~/.codex`, …) is a symlink into `/config/<name>`, XDG vars
(`XDG_CONFIG_HOME`, etc.) and CLI-specific vars (`CLAUDE_CONFIG_DIR`,
`CODEX_HOME`) are redirected there too, and `GIT_CONFIG_GLOBAL=/config/gitconfig`
persists git identity. `/workspace` is the only other mount — the bind-mounted
project the CLI operates on. Nothing else should become stateful; if a new CLI
needs a config path, symlink it into `/config/<name>` in the Dockerfile rather
than leaving it under the ephemeral container filesystem.

**Entrypoint has three strict phases, in order** (`docker-entrypoint.sh`):
1. **Drop privileges.** Runs as root only to `chown` bind mounts that are still
   root-owned (never a directory already owned by someone else — that would
   silently change ownership on the host side) then `exec setpriv --reuid …`
   into the `llm` user. This must happen *before* step 2 — dropping privileges
   re-execs the script, so loading config first would print every log line
   twice.
2. **Fan out credentials.** Loads `/config/env`, then the provider profile
   (`/config/providers/<name>.env` shadows `/etc/llm/providers/<name>.env`),
   then maps one canonical triple — `WQ_API_KEY` / `WQ_BASE_URL` / `WQ_MODEL` —
   onto every CLI's own env var names (`ANTHROPIC_*`, `OPENAI_*`, `GEMINI_*`/
   `GOOGLE_*`). Anything already set by `-e`/compose wins over the mapping.
   DeepSeek and MiniMax speak Anthropic's protocol on a *different* path than
   their OpenAI-compatible one, so their profiles also set
   `WQ_ANTHROPIC_BASE_URL`, which only affects `ANTHROPIC_BASE_URL`.
3. **Exec.** Warns (doesn't fail) if `/workspace` isn't writable or no API key
   was found, adds `safe.directory '*'` for git, then `exec "$@"` (default
   `/bin/bash`).

**Provider profiles (`providers/*.env`)** are plain shell env files named by
`LLM_PROVIDER` value (`anthropic`, `openai`, `gemini`, `deepseek`, `minimax`,
`openrouter`, `ollama`, `custom`). Adding a backend means adding one file here
(following the existing pattern of `WQ_BASE_URL` + comments) — no entrypoint
change needed unless the backend needs a new fan-out mapping.

**`llm-doctor.sh`** is a read-only, offline-safe diagnostic (`llm-doctor` on
`PATH`) — reports toolchain/CLI versions, installed Python package groups,
mount status, and whether a provider/API key is configured. It never prints
secret values, only presence. Extend the `groups` dict in its embedded Python
block when adding a Python package worth surfacing, and the `for cli in …`
list when adding a new CLI.

## Non-obvious constraints

- `ubuntu:26.04` ships a stock `ubuntu` user at uid/gid 1000; the runtime stage
  deletes it first so the default `USER_UID`/`USER_GID=1000` is free.
- The builder's `ENV PATH=/opt/node/bin:...` is required explicitly — the
  runtime stage's `PATH` does not apply inside the builder, so `npm` would
  otherwise not be found there.
- `fd`/`bat` are `fdfind`/`batcat` on Debian/Ubuntu; symlinked to the expected
  names in the runtime stage.
- Node and uv downloads are checksum-verified against the publisher's own
  checksum file; everything else comes over authenticated HTTPS only.
- `amd64` only — no `TARGETARCH` resolution. The PROD "mini server" host
  (see the repo-root CLAUDE.md's Cloudflare section) is arm64, so this image
  currently cannot run there; re-add arch handling before deploying it to PROD.
