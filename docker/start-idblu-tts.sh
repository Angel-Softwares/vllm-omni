#!/usr/bin/env bash
set -euo pipefail

export VLLM_OMNI_HOST="${VLLM_OMNI_HOST:-127.0.0.1}"
export VLLM_OMNI_PORT="${VLLM_OMNI_PORT:-8091}"
export IDBLU_TTS_PORT="${IDBLU_TTS_PORT:-8080}"
export IDBLU_TTS_TASK_TYPE="${IDBLU_TTS_TASK_TYPE:-Base}"
export IDBLU_TTS_PROFILE="${IDBLU_TTS_PROFILE-safe}"
export HF_HOME="${HF_HOME:-/cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-${HF_HOME%/}/hub}"
export IDBLU_TTS_WARMUP_STATUS_FILE="${IDBLU_TTS_WARMUP_STATUS_FILE:-/tmp/idblu-tts-warmup-status.json}"

if [ -n "${TRANSFORMERS_CACHE:-}" ]; then
  echo "Ignoring deprecated TRANSFORMERS_CACHE; using HF_HOME=${HF_HOME} and HF_HUB_CACHE=${HF_HUB_CACHE}" >&2
  unset TRANSFORMERS_CACHE
fi

cd /app/vllm-omni
rm -f "${IDBLU_TTS_WARMUP_STATUS_FILE}"

./examples/online_serving/qwen3_tts/run_server.sh "${IDBLU_TTS_TASK_TYPE}" "${IDBLU_TTS_PROFILE}" &
UPSTREAM_PID=$!

uvicorn idblu_tts_wrapper.app:app --host 0.0.0.0 --port "${IDBLU_TTS_PORT}" &
WRAPPER_PID=$!

python -m idblu_tts_wrapper.pod_warmup &
WARMUP_PID=$!

shutdown() {
  if kill -0 "${WARMUP_PID}" 2>/dev/null; then
    kill "${WARMUP_PID}" 2>/dev/null || true
    wait "${WARMUP_PID}" 2>/dev/null || true
  fi
  if kill -0 "${WRAPPER_PID}" 2>/dev/null; then
    kill "${WRAPPER_PID}" 2>/dev/null || true
    wait "${WRAPPER_PID}" 2>/dev/null || true
  fi
  if kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
    kill "${UPSTREAM_PID}" 2>/dev/null || true
    wait "${UPSTREAM_PID}" 2>/dev/null || true
  fi
}

trap shutdown EXIT INT TERM

wait "${WRAPPER_PID}"
