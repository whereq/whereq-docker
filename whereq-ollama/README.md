# Ollama 1B / 3B / 7B Docker Image

Self-contained Docker image bundling the latest stable **Ollama** server
(`v0.30.7`) with three pre-pulled small models, so `docker compose up` is
all you need to have inference ready.

## What's inside

| Tier | Model         | Params | Why this one                                                                 |
| ---- | ------------- | ------ | ---------------------------------------------------------------------------- |
| 1B   | `gemma3:1b`   | ~1B    | Google's latest tiny model, fast even on CPU, great for tests and edge use. |
| 3B   | `llama3.2:3b` | 3.2B   | Meta's solid general-purpose 3B, instruction-tuned.                           |
| 7B   | `qwen3:8b`    | 8B     | The strongest "7B-tier" dense model currently available, multilingual.       |

You can swap any of them at build time, e.g.:

    docker build \
      --build-arg MODEL_1B=llama3.2:1b \
      --build-arg MODEL_3B=phi4:3.8b \
      --build-arg MODEL_7B=llama3.1:8b \
      -t whereq/ollama-1b-3b-7b:latest .

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
    docker exec -it ollama ollama run llama3.2:3b "Explain Docker layers."

## Notes

- First `docker compose up --build` downloads ~10–15 GB of model weights.
  Subsequent starts reuse the named volume `ollama_data`.
- GPU: uncomment the `deploy.resources` block in `docker-compose.yml` if you
  have the NVIDIA container toolkit installed.
- CPU-only is fully supported; expect the 8B model to be slow without a GPU.
