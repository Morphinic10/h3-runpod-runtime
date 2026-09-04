#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="${H3_LOG_DIR:-/workspace/h3logs}"
LOG_PORT="${H3_LOG_PORT:-8189}"
COMFY_PORT="${COMFYUI_PORT:-8188}"
HOLD_ON_ERROR="${H3_HOLD_ON_ERROR:-1}"
CUDA_RETRIES="${H3_CUDA_RETRIES:-12}"
CUDA_RETRY_DELAY_S="${H3_CUDA_RETRY_DELAY_S:-5}"

[[ "$LOG_PORT" =~ ^[0-9]+$ && "$COMFY_PORT" =~ ^[0-9]+$ ]] || {
  echo "ERROR: H3_LOG_PORT and COMFYUI_PORT must be integers" >&2
  exit 64
}
[[ "$LOG_PORT" != "$COMFY_PORT" ]] || {
  echo "ERROR: H3_LOG_PORT and COMFYUI_PORT must differ" >&2
  exit 64
}
[[ "$CUDA_RETRIES" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: H3_CUDA_RETRIES must be a positive integer" >&2
  exit 64
}
[[ "$CUDA_RETRY_DELAY_S" =~ ^[0-9]+$ ]] || {
  echo "ERROR: H3_CUDA_RETRY_DELAY_S must be a non-negative integer" >&2
  exit 64
}

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/launch.log"
exec > >(tee -a "$LOG_DIR/launch.log") 2>&1

PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
[[ -n "$PY_BIN" ]] || { echo "ERROR: Python interpreter not found" >&2; exit 66; }

LOG_SERVER_PID=""
STATUS_SERVER_PID=""
COMFY_PID=""

write_status() {
  local state="$1" message="$2"
  H3_STATUS_STATE="$state" H3_STATUS_MESSAGE="$message" "$PY_BIN" - "$LOG_DIR" <<'PY'
import html
import json
import os
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
state = os.environ["H3_STATUS_STATE"]
message = os.environ["H3_STATUS_MESSAGE"]
payload = {
    "state": state,
    "message": message,
    "updated_unix": int(time.time()),
}
(root / "status.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
(root / "index.html").write_text(
    "<!doctype html><meta charset='utf-8'><title>H3 runtime status</title>"
    "<style>body{font:18px system-ui;max-width:900px;margin:3rem auto;padding:0 1rem}"
    "code{background:#eee;padding:.15rem .3rem}</style>"
    f"<h1>H3 runtime: {html.escape(state)}</h1>"
    f"<p>{html.escape(message)}</p>"
    "<p><a href='/launch.log'>Open launch.log</a> · "
    "<a href='/status.json'>Open status.json</a></p>",
    encoding="utf-8",
)
PY
}

start_log_server() {
  if [[ -n "$LOG_SERVER_PID" ]] && kill -0 "$LOG_SERVER_PID" 2>/dev/null; then return; fi
  (cd "$LOG_DIR" && exec "$PY_BIN" -m http.server "$LOG_PORT" --bind 0.0.0.0) \
    >>"$LOG_DIR/httpd-8189.log" 2>&1 &
  LOG_SERVER_PID=$!
}

start_status_server() {
  if [[ -n "$STATUS_SERVER_PID" ]] && kill -0 "$STATUS_SERVER_PID" 2>/dev/null; then return; fi
  (cd "$LOG_DIR" && exec "$PY_BIN" -m http.server "$COMFY_PORT" --bind 0.0.0.0) \
    >>"$LOG_DIR/httpd-8188.log" 2>&1 &
  STATUS_SERVER_PID=$!
}

wait_for_local_http() {
  local port="$1" attempt
  for attempt in $(seq 1 30); do
    curl --fail --silent --max-time 1 "http://127.0.0.1:${port}/status.json" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "ERROR: diagnostic HTTP server on port $port did not start" >&2
  return 65
}

stop_process() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

on_signal() {
  set +e
  trap - ERR TERM INT
  stop_process "$COMFY_PID"
  stop_process "$STATUS_SERVER_PID"
  stop_process "$LOG_SERVER_PID"
  exit 143
}

fatal_hold() {
  local rc="${1:-1}" line="${2:-unknown}"
  (( rc != 0 )) || rc=70
  set +e
  trap - ERR
  echo "[launcher] FATAL: boot failed with status=$rc near line=$line"
  echo "[launcher] keeping diagnostic endpoints alive; inspect /launch.log"
  write_status "failed" "Boot failed (status $rc near line $line). Open launch.log for the CUDA, driver, download, or ComfyUI error."
  start_log_server
  start_status_server
  case "$HOLD_ON_ERROR" in
    1|true|yes)
      while :; do sleep 3600; done
      ;;
    0|false|no)
      stop_process "$STATUS_SERVER_PID"
      stop_process "$LOG_SERVER_PID"
      exit "$rc"
      ;;
    *) echo "ERROR: H3_HOLD_ON_ERROR must be 0/1/false/true/no/yes" >&2; exit 64 ;;
  esac
}

trap 'fatal_hold "$?" "$LINENO"' ERR
trap on_signal TERM INT

write_status "starting" "Container is alive. Preparing the CUDA and driver preflight."
start_log_server
start_status_server
wait_for_local_http "$LOG_PORT"
wait_for_local_http "$COMFY_PORT"

echo "[launcher] clean H3 runtime starting"
echo "[launcher] diagnostic URLs: :${COMFY_PORT}/ and :${LOG_PORT}/launch.log"
echo "[launcher] models=${MODEL_DIR:-/workspace/models} download=${H3_DOWNLOAD_MODELS:-1}"
echo "[launcher] inputs=${INPUT_DIR:-/workspace/ComfyUI/input} outputs=${OUTPUT_DIR:-/workspace/ComfyUI/output}"
echo "[launcher] kernel=$(uname -srmo)"
echo "[launcher] NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-unset}"
echo "[launcher] CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
echo "[launcher] NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-unset}"
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "[launcher] cgroup memory.max=$(</sys/fs/cgroup/memory.max)"
fi
echo "[launcher] NVIDIA device files:"
ls -la /dev/nvidia* 2>&1 || true
echo "[launcher] nvidia-smi:"
nvidia-smi 2>&1 || true

cuda_ok=0
for attempt in $(seq 1 "$CUDA_RETRIES"); do
  echo "[launcher] CUDA preflight attempt ${attempt}/${CUDA_RETRIES}"
  set +e
  "$PY_BIN" - <<'PY'
import ctypes
import torch

count = ctypes.c_int(-1)
libcuda = ctypes.CDLL("libcuda.so.1")
init_rc = int(libcuda.cuInit(0))
count_rc = int(libcuda.cuDeviceGetCount(ctypes.byref(count))) if init_rc == 0 else -1
print(f"[launcher] libcuda: cuInit={init_rc} cuDeviceGetCount={count_rc} devices={count.value}", flush=True)
print(f"[launcher] torch={torch.__version__} compiled_cuda={torch.version.cuda}", flush=True)
print(f"[launcher] torch.cuda.is_available={torch.cuda.is_available()} count={torch.cuda.device_count()}", flush=True)
if init_rc != 0 or count_rc != 0 or count.value < 1 or not torch.cuda.is_available():
    raise SystemExit(1)
x = torch.randn((128, 128), device="cuda", dtype=torch.bfloat16)
y = x @ x
torch.cuda.synchronize()
assert y.shape == x.shape
print(f"[launcher] CUDA OK: {torch.cuda.get_device_name(0)}", flush=True)
PY
  cuda_rc=$?
  set -e
  if (( cuda_rc == 0 )); then
    cuda_ok=1
    break
  fi
  (( attempt == CUDA_RETRIES )) || sleep "$CUDA_RETRY_DELAY_S"
done
(( cuda_ok == 1 )) || { echo "ERROR: CUDA preflight exhausted all retries" >&2; false; }

write_status "downloading_models" "CUDA is healthy. Downloading and checksum-verifying the model manifest."
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
  --port "$COMFY_PORT"
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

write_status "starting_comfyui" "Models are ready. Releasing port 8188 to ComfyUI."
stop_process "$STATUS_SERVER_PID"
STATUS_SERVER_PID=""
echo "[launcher] starting ComfyUI on port $COMFY_PORT"
set +e
"$PY_BIN" "${args[@]}" &
COMFY_PID=$!
wait "$COMFY_PID"
comfy_rc=$?
COMFY_PID=""
set -e
echo "ERROR: ComfyUI exited unexpectedly with status=$comfy_rc" >&2
fatal_hold "$comfy_rc" "$LINENO"
