#!/bin/bash
# Launch vLLM-Omni server for Qwen3-TTS models
#
# Usage:
#   ./run_server.sh                           # Default: CustomVoice model
#   ./run_server.sh CustomVoice               # CustomVoice model
#   ./run_server.sh VoiceDesign               # VoiceDesign model
#   ./run_server.sh Base                      # Base (voice clone) model
#   ./run_server.sh Base safe                 # Conservative safe profile
#   ./run_server.sh Base latency              # Safe profile with async_chunk + async_scheduling
#   ./run_server.sh Base default              # Bundled default config

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../../use_venv_cuda.sh"

TASK_TYPE="${1:-CustomVoice}"
PROFILE="${2:-}"

case "$TASK_TYPE" in
    CustomVoice)
        MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
        ;;
    VoiceDesign)
        MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
        ;;
    Base)
        MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
        ;;
    *)
        echo "Unknown task type: $TASK_TYPE"
        echo "Supported: CustomVoice, VoiceDesign, Base"
        exit 1
        ;;
esac

echo "Starting Qwen3-TTS server with model: $MODEL"

if [ -n "${QWEN3_TTS_DEPLOY_CONFIG:-}" ]; then
    DEPLOY_CONFIG="${QWEN3_TTS_DEPLOY_CONFIG}"
    PROFILE_LABEL="explicit-deploy-config"
else
    case "$PROFILE" in
        "")
            DEPLOY_CONFIG="vllm_omni/deploy/qwen3_tts.yaml"
            PROFILE_LABEL="custom/default"
            ;;
        safe)
            DEPLOY_CONFIG="vllm_omni/deploy/qwen3_tts_safe.yaml"
            PROFILE_LABEL="safe"
            ;;
        latency|async)
            DEPLOY_CONFIG="vllm_omni/deploy/qwen3_tts_safe_async.yaml"
            PROFILE_LABEL="latency"
            ;;
        default|fast)
            DEPLOY_CONFIG="vllm_omni/deploy/qwen3_tts.yaml"
            PROFILE_LABEL="default"
            ;;
        *)
            echo "Unknown profile: $PROFILE"
            echo "Supported profiles: safe, latency, default"
            exit 1
            ;;
    esac
fi

preflight_speech_tokenizer() {
    python - "$MODEL" <<'PY'
import os
import sys
from transformers.utils.hub import cached_file

model = sys.argv[1]
errors = []

def resolve(filename: str) -> str | None:
    try:
        return cached_file(model, filename)
    except Exception:
        return None

cfg_path = resolve("speech_tokenizer/config.json")
prep_path = resolve("speech_tokenizer/preprocessor_config.json")
speech_dir = os.path.dirname(cfg_path) if cfg_path else None

if not cfg_path or not os.path.isfile(cfg_path):
    errors.append("missing speech_tokenizer/config.json")
if not prep_path or not os.path.isfile(prep_path):
    errors.append("missing speech_tokenizer/preprocessor_config.json")

if speech_dir is None:
    errors.append("could not resolve local speech_tokenizer directory")
else:
    has_weights = any(
        os.path.isfile(os.path.join(speech_dir, name))
        for name in ("model.safetensors", "pytorch_model.bin")
    )
    if not has_weights:
        errors.append(
            f"missing speech_tokenizer weights in {speech_dir} "
            "(expected model.safetensors or pytorch_model.bin)"
        )

if errors:
    sys.stderr.write(f"speech_tokenizer preflight failed for {model}\n")
    for error in errors:
        sys.stderr.write(f" - {error}\n")
    sys.exit(1)

print(f"speech_tokenizer preflight OK: {speech_dir}")
PY
}

export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"
HOST="${VLLM_OMNI_HOST:-0.0.0.0}"
PORT="${VLLM_OMNI_PORT:-8091}"
echo "Using deploy config: $DEPLOY_CONFIG"
echo "Using launch profile: $PROFILE_LABEL"
echo "Using worker multiprocessing method: $VLLM_WORKER_MULTIPROC_METHOD"
echo "Binding vllm-omni to ${HOST}:${PORT}"

GPU_MEMORY_ARGS=()
if [ -n "${VLLM_GLOBAL_GPU_MEMORY_UTILIZATION:-}" ]; then
    GPU_MEMORY_ARGS+=(--gpu-memory-utilization "$VLLM_GLOBAL_GPU_MEMORY_UTILIZATION")
    echo "Using global GPU memory utilization override: $VLLM_GLOBAL_GPU_MEMORY_UTILIZATION"
else
    echo "Using GPU memory utilization from deploy config"
fi

TTS_INSTRUCTIONS_ARGS=()
if [ -n "${IDBLU_TTS_MAX_INSTRUCTIONS_LENGTH:-}" ]; then
    TTS_INSTRUCTIONS_ARGS+=(--tts-max-instructions-length "$IDBLU_TTS_MAX_INSTRUCTIONS_LENGTH")
    echo "Using TTS max instructions length override: $IDBLU_TTS_MAX_INSTRUCTIONS_LENGTH"
else
    echo "Using TTS max instructions length from deploy config/default"
fi

preflight_speech_tokenizer

vllm-omni serve "$MODEL" \
    --deploy-config "$DEPLOY_CONFIG" \
    --host "$HOST" \
    --port "$PORT" \
    "${GPU_MEMORY_ARGS[@]}" \
    "${TTS_INSTRUCTIONS_ARGS[@]}" \
    --trust-remote-code \
    --omni
