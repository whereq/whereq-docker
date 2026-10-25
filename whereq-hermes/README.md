# whereq-hermes

Docker image for **Hermes Agent** by [Nous Research](https://nousresearch.com),
pinned to the latest stable release.

| Component       | Version             | Notes                                    |
| --------------- | ------------------- | ---------------------------------------- |
| Hermes Agent    | `v0.16.0` (`v2026.6.5`) | Released 2026-06-06                 |
| Python          | 3.13 (slim-bookworm) | Capped at <3.14 per project's pyproject |
| Package manager | `uv` (build) / `pip` (runtime) | Fast, reproducible installs |

## Build

    cd whereq-hermes
    docker compose build

Or directly with `docker build`:

    docker build \
      --build-arg HERMES_VERSION=v2026.6.5 \
      -t whereq/hermes-agent:latest .

## Run interactively

    # put your API keys in a .env file first (OPENAI_API_KEY, etc.)
    docker compose run --rm hermes

This drops you into the interactive `hermes` CLI.

## Run a one-shot prompt

    docker compose run --rm hermes hermes-agent "Summarize the README of this repo"

## Pointing Hermes at the local Ollama

If you have the `whereq-ollama` stack running, edit `docker-compose.yml` to
uncomment the `networks:` block and set:

    OLLAMA_HOST: http://ollama:11434

in the environment. Hermes auto-detects Ollama when that env var is set.

## Files

- `Dockerfile` — multi-stage build (uv builder → slim runtime, non-root user, tini as PID 1)
- `docker-compose.yml` — one-service compose with persistent volume + .env support
- `.dockerignore` — keeps the build context small

## Upgrading Hermes

1. Check the [latest release](https://github.com/NousResearch/hermes-agent/releases).
2. Update `HERMES_VERSION` in `docker-compose.yml` (or pass `--build-arg`).
3. Rebuild: `docker compose build --pull --no-cache`.
