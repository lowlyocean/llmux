# Portainer stack with vLLM services

llmux as a single-entry-point proxy that routes requests to a fleet of
vLLM containers, each serving a single model with all available GPUs.
Mirrors the llama.cpp `presets.ini` configuration with three models:

| Service         | Priority | Model                              | GPU role          |
|----------------|----------|------------------------------------|-------------------|
| `home_assistant`| high     | Qwen3.6-35B-A3B (Chat)             | Main chat model   |
| `images`       | medium   | Qwen3.6-35B-A3B + mmproj (Vision)  | Multimodal        |
| `embeddings`   | low      | Qwen3-VL-Embedding-2B              | Embedding index   |

All three models use all available GPUs. llmux ensures the highest-priority model
is always running when a request comes in for a lower-priority model —
it wakes the sleeping service before routing.

## Prerequisites

- Docker (or Podman) with NVIDIA runtime support
- NVIDIA driver >= 535 with CUDA 12.8 (vLLM v0.8.3 image)
- One GPU with sufficient VRAM for the largest model (~35B + mmproj)
- Models downloaded and mounted via bind mounts

## Deploy

### Portainer

1. **Stacks → from repository**
2. **Git URL**: `https://github.com/your-org/llmux`
3. **Git path**: `examples/portainer-vllm`
4. **Container**: `llmux:latest` (or your image)
5. Portainer creates the `llmux`, `home_assistant`, `images`, and
   `embeddings` services and starts them.

### Local (from Dockerfile)

```sh
docker compose -f docker-compose.yml up -d
```

### Build llmux image locally

llmux is built from the same Cargo workspace root using the Dockerfile:

```sh
docker build -t llmux:latest .
docker compose -f examples/portainer-vllm/docker-compose.yml up -d
```

## Configuration

### docker-compose.yml

Defines the four services:

- **llmux** — the proxy on port 3000. Reads `config.yaml` at startup.
  Waits for all three vLLM services to be healthy before becoming healthy itself.
- **home_assistant**, **images**, **embeddings** — vLLM containers running
  their respective models using all available GPUs on the host.

### config.yaml

```yaml
models:
  home_assistant:
    port: 8001
    wake: curl -sf http://localhost:8001/health
    sleep: curl -sf http://localhost:8001/health
    alive: curl -sf http://localhost:8001/health
    priority: high

  images:
    port: 8002
    wake: curl -sf http://localhost:8002/health
    sleep: curl -sf http://localhost:8002/health
    alive: curl -sf http://localhost:8002/health
    priority: medium

  embeddings:
    port: 8003
    wake: curl -sf http://localhost:8003/health
    sleep: curl -sf http://localhost:8003/health
    alive: curl -sf http://localhost:8003/health
    priority: low

port: 3000
```

No wake/sleep scripts needed — vLLM stays running 24/7. llmux uses the
`alive` health check to detect which model is available and routes
accordingly. Priority ensures the highest-priority model stays running
whenever a lower-priority model has pending requests.

## Usage

```sh
# Chat with the main model (home_assistant, low priority)
curl http://localhost:3000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"home_assistant","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'

# Vision request (images, medium priority)
curl http://localhost:3000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"images","messages":[{"role":"user","content":[{"type":"text","text":"What is in this image?"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}]}],"max_tokens":100}'

# Embedding request (embeddings, low priority)
curl http://localhost:3000/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"embeddings","input":["Hello world"]}'
```

## GPU sharing

All three vLLM services run on the same GPU. vLLM handles internal
scheduling via:

- `--flash-attention` — flash attention for faster inference
- `--enable-chunked-prefill` — chunked prefill to reduce latency
- Priority in llmux ensures the highest-priority model's context is
  kept warm while lower-priority models share the remaining capacity.

## Monitoring

```sh
# List all available models (shows priority in response)
curl http://localhost:3000/v1/models | jq .data[]

# Check GPU memory
nvidia-smi

# Check health of each service
curl http://localhost:8001/v1/models && echo OK || echo FAIL
curl http://localhost:8002/v1/models && echo OK || echo FAIL
curl http://localhost:8003/v1/models && echo OK || echo FAIL
```

## Cleanup

```sh
docker compose -f docker-compose.yml down
# Remove volumes (model caches)
docker volume prune -f
```
