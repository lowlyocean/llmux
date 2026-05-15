#!/bin/bash
#
# Pre-build checkpoints for all models so the first wake is a fast restore
# instead of a ~90s cold start.
#
# Usage: ./warmup.sh
#
# Run once after deploying the stack (via Portainer or docker compose).
# The script cold-starts each model, waits for it to be healthy, checkpoints
# it, then removes the container. The checkpoint persists on the shared volume
# and is restored on the next wake request.
#
# Prerequisites:
#   - CRIU installed (sudo apt install criu or PPA)
#   - NVIDIA driver >= 535
#   - docker checkpoint working (test: docker checkpoint create --help)

set -eu

HF_CACHE="${HFCACHE:-$HOME/.cache/huggingface}"
CKPT_DIR="/tmp/llmux-checkpoints"
IMAGE="vllm/vllm-openai:v0.21.0-cu129"
MODEL_PATH="${MODEL_PATH:-./models}"
MAX_WAIT=120

mkdir -p "$CKPT_DIR"

warmup_model() {
  local name="$1"
  local port="$2"
  local ckpt_name="$3"
  shift 3
  local cmd=("$@")

  echo "=== Warming up $name (port $port, checkpoint $ckpt_name) ==="

# Remove if already exists (from a previous run)
docker rm -f "$name" 2>/dev/null || true

  # Cold start
  echo "  Starting $name..."
  docker run -d --name "$name" \
    --privileged --security-opt=seccomp:unconfined \
    --runtime nvidia --gpus all \
    -p "$port:8000" \
    -v "$CKPT_DIR:/ckpt" \
    -v "$MODEL_PATH:/root/models" \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    --env HOME=/tmp \
    --ipc=host \
    "$IMAGE" \
    "${cmd[@]}"

  # Wait for health
  echo "  Waiting for $name to be healthy..."
  for i in $(seq 1 $MAX_WAIT); do
    if curl -sf "http://localhost:$port/v1/models" > /dev/null 2>&1; then
      echo "  Ready after ${i}s"
      break
    fi
    if [ "$i" -eq "$MAX_WAIT" ]; then
      echo "  ERROR: $name not ready after ${MAX_WAIT}s" >&2
      docker logs "$name" 2>&1 | tail -10
      exit 1
    fi
    sleep 1
  done

  # Checkpoint (saves GPU state to disk)
  echo "  Checkpointing $name..."
  docker checkpoint create --checkpoint-dir /ckpt "$ckpt_name" "$name"
  echo "  Checkpoint saved. Removing container..."

  # Remove the running container — only the checkpoint remains
  docker rm -f "$name"
  echo "  Done. $name is checkpointed and ready for restore."
  echo ""
}

# ── Models ───────────────────────────────────────────────────────────────

warmup_model "llmux_home_assistant" "${PORT_HA:-8001}" "home_assistant_cp" \
    --model "unsloth/Qwen3.6-35B-A3B-GGUF:UD-IQ2_XXS" \
    --language-model-only \
    --pipeline-parallel-size 2 \
    --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder --hf-config-path Qwen/Qwen3.6-35B-A3B --speculative-config '{"method":"mtp","num_speculative_tokens":2}' \
    --tokenizer Qwen/Qwen3.6-35B-A3B

warmup_model "llmux_images" "${PORT_IMAGES:-8002}" "images_cp" \
    --model "unsloth/Qwen3.6-35B-A3B-GGUF:UD-IQ2_XXS" \
    --pipeline-parallel-size 2 \
    --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder --hf-config-path Qwen/Qwen3.6-35B-A3B --speculative-config '{"method":"mtp","num_speculative_tokens":2}' \
    --tokenizer Qwen/Qwen3.6-35B-A3B

warmup_model "llmux_embeddings" "${PORT_EMBED:-8003}" "embeddings_cp" \
    --model "DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF:Q2_K" \
    --embedding \
    --pipeline-parallel-size 2

echo "All models warmed up. Deploy the stack and llmux will use checkpoints."
