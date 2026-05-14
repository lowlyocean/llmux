# Portainer + vLLM + CRIU Checkpoint/Restore

llmux routes requests to a single active vLLM model at a time, using Docker
CRIU checkpoint/restore to switch between models without cold starts.

## How it works

| State | What happens | GPU memory |
|-------|-------------|------------|
| Active | One model runs, serving requests | ~20 GB |
| Checkpointed | Container stopped, state saved to disk | 0 GB (freed) |

When llmux switches away from a model, it runs `docker checkpoint create`,
which uses CRIU to freeze the process, dump its memory + GPU state to disk,
and stop the container. GPU memory is immediately freed for other models.

On the next request for that model, llmux runs `docker start --checkpoint`,
which restores the process from the saved state — ~10-15s vs ~60-100s cold
start.

## Prerequisites

- **Docker** with CRIU support (systemd or docker-ce with criu)
- **CRIU** installed: `sudo apt install criu` (or build from https://criu.org)
- **NVIDIA driver** >= 535 (with `cuda-checkpoint` in driver package)
- **GPU** with compute capability >= 3.5
- **Docker Compose** v2

Verify CRIU works:
```sh
sudo criu check
sudo docker checkpoint create --help
```

## Usage

### 1. Configure ports

Copy `.env.example` to `.env` and edit values:
```sh
cp .env.example .env
```

Default ports:
- `LLMMUX_PORT=11434` — llmux proxy
- `PORT_HA=8001` — home_assistant
- `PORT_IMAGES=8002` — images
- `PORT_EMBED=8003` — embeddings

### 2. Deploy the stack

Via Portainer:
- Stack → Deploy from repository
- Repository: `https://github.com/your-org/llmux`
- Git folder: `.`
- Template: `docker-compose.yml`

Or locally:
```sh
docker compose -f docker-compose.yml up -d
```

### 3. Pre-build checkpoints (one-time)

```sh
chmod +x ./examples/portainer-vllm/warmup.sh
./examples/portainer-vllm/warmup.sh
```

This cold-starts each model, waits for health, checkpoints it, then removes
the container. All 3 checkpoints persist on the shared volume. After this,
the first wake for any model is a fast restore instead of a cold start.

### 4. Run llmux (local dev)

```sh
cargo run --release -- -c ./examples/portainer-vllm/config.yaml -p ${LLMMUX_PORT:-11434}
```

### 5. Send requests

```sh
# First request for home_assistant — cold start or restore (~10-90s depending)
curl "http://localhost:${LLMMUX_PORT:-11434}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"home_assistant","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}'

# Switch to images — checkpoints home_assistant, restores images
curl "http://localhost:${LLMMUX_PORT:-11434}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"images","messages":[{"role":"user","content":"Describe this image"}],"max_tokens":20}'
```

### 6. Check checkpoints

```sh
ls -lh /tmp/llmux-checkpoints/
```

## Architecture

```
llmux (proxy, port 11434)
  │
  ├── → home_assistant :8001  (high prio)  ← vLLM: Qwen3.6-35B
  ├── → images :8002          (medium prio) ← vLLM: Qwen3.6-35B
  └── → embeddings :8003      (low prio)    ← vLLM: Qwen3-VL-Embedding
```

Only **one model is active at a time**. Others are checkpointed and stopped,
freeing all GPU memory. Priorities determine which model wins switch conflicts
(home_assistant resists preemption, embeddings gets preempted first).

## Wake/Sleep Hooks

Each model in `config.yaml` has:

- **wake**: Try `docker start --checkpoint` → fall back to `docker run`
- **sleep**: `docker checkpoint create` + `docker stop`
- **alive**: `curl` the v1/models endpoint

## Cleanup

Restore containers to default state:
```sh
docker compose -f docker-compose.yml down -v
rm -rf /tmp/llmux-checkpoints/*
```

## Why CRIU instead of just docker stop/start?

| Aspect | Cold start | Checkpoint restore |
|--------|-----------|-------------------|
| Time | 60-100s | 10-15s |
| GPU init | Full re-init | Resume from state |
| KV cache | Recomputed | Preserved |
| User experience | Visible delay | Transparent |

CRIU captures the vLLM process tree, CUDA contexts, memory, and file state
into a snapshot on disk. `docker start --checkpoint` injects that state back
into a fresh container process — no model reload needed.

## Troubleshooting

**Checkpoint fails with "criu failed"**
```sh
# Ensure seccomp is disabled (already configured in docker-compose.yml)
docker inspect <container> | grep Seccomp
# Check CRIU
sudo criu check
# Check CUDA checkpoint support
nvidia-smi
which cuda-checkpoint
```

**Restore times out**
- Ensure GPU driver matches the CUDA version in the vLLM image
- Check GPU memory isn't consumed by other processes

**Container not starting after restore**
```sh
# Clear checkpoints and re-warmup
rm -rf /tmp/llmux-checkpoints/*
chmod +x ./examples/portainer-vllm/warmup.sh
./examples/portainer-vllm/warmup.sh
```
