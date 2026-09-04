# Community 4090 recovery, 2026-09-05 (Asia/Bangkok)

## Confirmed failure, before PyTorch or ComfyUI

Host `e7rl9wp4hqiw`, Taiwan, RTX 4090, NVIDIA open driver 580.178.04:

- `nvidia-smi` can list the assigned GPU.
- Opening `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` returns `EIO`.
- `cuInit(0)` returns 999. Removing `NVIDIA_VISIBLE_DEVICES=void` does not fix it.
- `CUDA_DISABLE_UNIFIED_MEMORY=1` does not fix it either.
- Trace confirms the host-mounted `libcuda.so.580.178.04` matches the kernel
  module version; this is not a mismatched PyTorch wheel.
- Tested different assigned GPU minors 0, 4 and 5 on this host.

Raw evidence: `tw-driver-diagnostic.log`, `tw-cuda.strace`, and
`tw-disable-unified-memory.log`. No model or campaign assets were downloaded.

NVIDIA's open driver checks global UVM state when opening this device:
https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-uvm/uvm.c
This supports a host-driver failure diagnosis. We did not attempt to reload
kernel modules or change the shared host. Rebuilding the container cannot
guarantee repair of a host UVM device returning I/O errors.

## Separate scheduling/startup limitations

- Existing Canada Pod `h27c534kjmab47` could not resume: no free GPU on its host.
- CUDA 12.8/12.9-only Community 4090 scheduling returned no instances.
- Canada and the other tested non-TW/US/FR country pools returned no instances
  with 48 GB RAM, 8 vCPU and CUDA 12.8+ requirements.
- US also returned no instances during this session.
- France host `q4fgkucunrho` accepted creation but did not start its container
  during the observed interval, with both the existing GHCR slim image and a
  small Docker Hub Python image. No CUDA conclusion can be drawn for France.

## Runtime defects repaired independently

- Bash ERR trap interrupted the very first CUDA failure, bypassing retries.
- Model download child failures could be lost by bare `wait`, falsely reporting
  all models ready.
- Cold boot reinstalled PyTorch, potentially replacing constrained packages.
- ComfyUI was blocked behind the entire 45.8 GB model download.
- Previous CI only tested the failure/status page, not a real ComfyUI server.
- API preflight could report success without requiring a CUDA device.

The new image bakes the pinned PyTorch runtime, starts the UI while models
download, and CI starts actual ComfyUI on CPU and checks required nodes. CPU CI
does not establish GPU or H3 rendering readiness.
