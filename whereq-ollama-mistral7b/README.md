# Ollama 1B / 3B / Mistral-7B Docker Image

Self-contained Docker image bundling the latest stable **Ollama** server
(`v0.30.7`) with three pre-pulled models — all **non-Chinese** — so
`docker compose up` is all you need to have inference ready.

## What's inside

| Tier | Model         | Params | Why this one                                                                             |
| ---- | ------------- | ------ | ---------------------------------------------------------------------------------------- |
| 1B   | `gemma3:1b`   | ~1B    | Google's latest tiny model, fast even on CPU, great for tests and edge use.              |
| 3B   | `llama3.2:3b` | 3.2B   | Meta's solid general-purpose 3B, instruction-tuned.                                       |
| 7B   | `mistral:7b`  | 7.2B   | Mistral AI (France) — the lightest well-supported **non-Chinese** 7B; ~4.4 GB at Q4_K_M. |

The 7B tier is the point of this image: Qwen / DeepSeek / Yi / GLM are
Chinese-origin; Llama is 8B; Gemma's tiers are 2B/9B. Mistral 7B is the only
modern, genuinely 7B, non-Chinese dense model, and at Ollama's default
`Q4_K_M` quant it is the most lightweight of the bunch.

Swap any tier at build time if you want different tags:

    docker build \
      --build-arg MODEL_1B=llama3.2:1b \
      --build-arg MODEL_3B=phi4:3.8b \
      --build-arg MODEL_7B=mistral:7b-instruct \
      -t whereq/ollama-1b-3b-mistral7b:latest .

## Quick start

    docker compose up -d --build
    docker compose logs -f ollama     # wait for "Listening on ..."

    # Quick sanity check
    curl http://localhost:11434/api/tags

    # Chat with the 1B model
    curl http://localhost:11434/api/chat -d '{
      "model": "gemma3:1b",
      "messages": [{"role":"user","content":"Say hi in one sentence."}],
      "stream": false
    }'

    # Or use the CLI
    docker exec -it ollama-mistral7b ollama run mistral:7b "Explain Docker layers."

## Notes

- First `docker compose up --build` downloads ~7 GB of model weights.
  Subsequent starts reuse the named volume `ollama_mistral7b_data`.
- GPU: uncomment the `deploy.resources` block in `docker-compose.yml` if you
  have the NVIDIA container toolkit installed.
- CPU-only is fully supported; a 7B model runs comfortably on CPU, just slower.
