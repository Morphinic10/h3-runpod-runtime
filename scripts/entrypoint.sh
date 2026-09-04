#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="${H3_LOG_DIR:-/workspace/h3logs}"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/launch.log") 2>&1

echo "[launcher] clean H3 runtime starting"
echo "[launcher] models=${MODEL_DIR:-/workspace/models} download=${H3_DOWNLOAD_MODELS:-1}"
echo "[launcher] inputs=${INPUT_DIR:-/workspace/ComfyUI/input} outputs=${OUTPUT_DIR:-/workspace/ComfyUI/output}"

(cd "$LOG_DIR" && python -m http.server "${H3_LOG_PORT:-8189}" --bind 0.0.0.0 >httpd.log 2>&1) &

python - <<'PY'
import torch
assert torch.cuda.is_available(), "CUDA unavailable"
x = torch.randn((128, 128), device="cuda", dtype=torch.bfloat16)
y = x @ x
torch.cuda.synchronize()
assert y.shape == x.shape
print("[launcher] CUDA OK:", torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0))
PY

case "${H3_DOWNLOAD_MODELS:-1}" in
  1|true|yes) /usr/local/bin/download-models.sh ;;
  0|false|no) echo "[launcher] model download skipped by H3_DOWNLOAD_MODELS=0" ;;
  *) echo "ERROR: H3_DOWNLOAD_MODELS must be 0/1/false/true/no/yes" >&2; exit 64 ;;
esac

mkdir -p \
  "${INPUT_DIR:-/workspace/ComfyUI/input}" \
  "${OUTPUT_DIR:-/workspace/ComfyUI/output}" \
  "${TEMP_DIR:-/workspace/ComfyUI/temp}" \
  "${USER_DIR:-/workspace/ComfyUI/user}/default/workflows"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=timestamp,name,pstate,temperature.gpu,power.draw,power.limit,clocks.gr,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total \
    --format=csv,noheader,nounits --loop="${GPU_TELEMETRY_INTERVAL_S:-10}" | sed -u 's/^/[gpu] /' &
fi

args=(
  /opt/ComfyUI/main.py
  --listen 0.0.0.0
  --port "${COMFYUI_PORT:-8188}"
  --disable-auto-launch
  --preview-method none
  --input-directory "${INPUT_DIR:-/workspace/ComfyUI/input}"
  --output-directory "${OUTPUT_DIR:-/workspace/ComfyUI/output}"
  --temp-directory "${TEMP_DIR:-/workspace/ComfyUI/temp}"
  --user-directory "${USER_DIR:-/workspace/ComfyUI/user}"
  --extra-model-paths-config "${EXTRA_MODEL_PATHS_CONFIG:-/opt/h3/config/extra_model_paths.yaml}"
)

case "${COMFYUI_DISABLE_PINNED_MEMORY:-1}" in 1|true|yes) args+=(--disable-pinned-memory);; 0|false|no) :;; *) exit 64;; esac
case "${COMFYUI_CACHE_NONE:-1}" in 1|true|yes) args+=(--cache-none);; 0|false|no) :;; *) exit 64;; esac

echo "[launcher] starting ComfyUI on port ${COMFYUI_PORT:-8188}"
exec python "${args[@]}"
