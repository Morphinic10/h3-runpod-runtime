#!/usr/bin/env bash
# One-shot, read-only GPU diagnostics. No model/PyTorch downloads.
set -uo pipefail
log_dir="${H3_LOG_DIR:-/workspace/h3logs}"
mkdir -p "$log_dir"
exec > >(tee "$log_dir/diagnostic.log") 2>&1
python -m http.server 8189 --bind 0.0.0.0 --directory "$log_dir" > "$log_dir/http.log" 2>&1 &
date -Is
uname -a
id
ls -la /dev/nvidia* /dev/dri 2>&1 || true
cat /proc/driver/nvidia/version 2>/dev/null || true
cat /proc/driver/nvidia/gpus/*/information 2>/dev/null || true
printenv LD_LIBRARY_PATH CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES || true
ldconfig -p | grep -E 'libcuda|libnvidia' || true
cat /proc/self/cgroup
cat /sys/fs/cgroup/devices/devices.list 2>/dev/null || true
nvidia-smi
cat > "$log_dir/probe.py" <<'PY'
import ctypes
import json
import os
from pathlib import Path

for path in Path('/dev').glob('nvidia*'):
    if path.is_dir():
        continue
    try:
        fd = os.open(path, os.O_RDWR)
        os.close(fd)
        print('DEVICE_OPEN_OK', path, flush=True)
    except OSError as error:
        print('DEVICE_OPEN_FAIL', path, str(error), flush=True)
lib = ctypes.CDLL('libcuda.so.1')
version = ctypes.c_int()
lib.cuDriverGetVersion(ctypes.byref(version))
result = lib.cuInit(0)
print('CUDA_DRIVER', version.value, 'cuInit', result, flush=True)
for line in Path('/proc/self/maps').read_text().splitlines():
    if 'libcuda' in line or 'libnvidia' in line:
        print(line)
Path(__file__).with_suffix('.json').write_text(json.dumps({'cuInit': result, 'driver': version.value}))
PY
echo '=== Original environment ==='
python "$log_dir/probe.py"
echo '=== No NVIDIA_VISIBLE_DEVICES sentinel ==='
env -u NVIDIA_VISIBLE_DEVICES python "$log_dir/probe.py"
echo '=== Traced CUDA initialization ==='
if ! command -v strace >/dev/null; then
    apt-get update -qq && apt-get install -y --no-install-recommends strace > "$log_dir/strace-install.log" 2>&1
fi
env -u NVIDIA_VISIBLE_DEVICES strace -f -s 200 -o "$log_dir/cuda.strace" python "$log_dir/probe.py"
echo '=== Failing driver calls ==='
grep -E 'nvidia|EPERM|EACCES|ENODEV|EINVAL|ioctl' "$log_dir/cuda.strace" | tail -100
echo DIAGNOSTIC_COMPLETE
sleep infinity
