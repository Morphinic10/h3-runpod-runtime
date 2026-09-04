# H3 RunPod Runtime

Clean, model-free `linux/amd64` runtime for the current MiniMax H3 workflows.
It is intentionally independent from campaign repositories and old RunPod
controllers.

## Included in the image

- Python 3.11 and pinned PyTorch 2.8.0 / CUDA 12.8, installed at image build
  time so a normal start does not reinstall PyTorch.
- ComfyUI 0.34.0 at a pinned commit.
- `ComfyUI-MiniMax-H3-PDD-Acc` at a pinned commit.
- KJNodes with `MiniMaxLowVRAMAttention` and `MiniMaxChunkFeedForward`.
- VideoHelperSuite with `video/h265-mp4-16in` for real `yuv420p10le` output.
- ComfyKitchen from the pinned ComfyUI dependency set.
- A checksum-pinned model downloader and a live node/model preflight tool.

## Not included in the image

- Model weights.
- Network-volume state.
- API keys or registry credentials.
- Campaign prompts, workflows, references, or outputs.

At first boot, the launcher checks direct CUDA driver access and runs a real
PyTorch GPU matrix multiplication, then starts ComfyUI while downloading the
current FL2VA/PDD8/Turbo8 stack to ephemeral `/workspace/models`:

- FL2VA INT8 ConvRot base.
- Qwen3-VL MiniMax H3 text encoder.
- MiniMax H3 video and audio VAEs.
- Official FL2VA PDD Acc 8-step weight.
- LightX2V Ref2V Turbo 8-step v1.0 768p ComfyUI BF16 LoRA.

PDD8 and Turbo8 are separate acceleration paths. The runtime supports both;
each workflow decides which one to connect. The current Turbo8 research recipe
is `h3-fl2va-refnode-ref2v-turbo8-v1-768-euler-simple-kitchen-home@0.1.0`
and remains experimental. Its exact API graph is pinned at
[`workflows/current-turbo8.api.json`](workflows/current-turbo8.api.json); replace
the three `PROJECT_PICTURE_*.png` inputs, `PROJECT_PROMPT`, and output prefix
before submitting it.

## Runtime defaults

### One-command Community 4090 launcher

On this Mac, double-click `Open-ComfyUI-4090.command`. It opens the browser after
the selected image passes the GPU/node/model checks. Double-click
`Stop-ComfyUI-4090.command` when finished. The published image digest is stored
in `config/published-image.json` after CI validation; GPU validation is recorded
separately and must not be inferred from CPU tests.

```bash
python3 scripts/runpod.py up
python3 scripts/runpod.py status
python3 scripts/runpod.py stop
```

An explicit `--image ghcr.io/morphinic10/h3-runpod-runtime@sha256:...` overrides
the published digest for a controlled test.

The launcher uses the existing local Lab key on this workstation. Elsewhere,
set `RUNPOD_API_KEY` or `RUNPOD_ENV_FILE`; credentials are never sent to the Pod.
It checks balance and existing Pods, creates **Community RTX 4090 only**, uses
150 GB ephemeral container disk and zero volumes, and waits for GPU/node/model
readiness. A failed boot, missing GPU, interrupted wait or exceeded boot budget
stops the exact created Pod automatically. The default boot limit is 15 minutes
and $0.20 (conservative estimate); a successfully ready Pod stays running until
you use `stop`. These are boot limits, not a spending cap for later generation.

Use `--smoke` to skip models and check only CUDA, nodes and the output format.
Use `--country CA` to request a specific country. The default download-speed
floor is 500 Mbps for the 45.8 GB cold model download; it can be changed with
`--min-download-mbps`. No available matching host is reported without silently
switching to Secure Cloud or creating persistent storage.

### Container defaults

- Container disk: 150 GB minimum.
- Model directory: `/workspace/models`.
- ComfyUI: port `8188`.
- Boot/model log: port `8189`, path `/launch.log`.
- During boot, port `8188` serves a small status page until ComfyUI takes over.
- Model downloads do not block the UI. Check `:8189/status.json` for
  `models_ready`, then refresh the ComfyUI model lists before generation.
- No network volume.
- No global Sage attention flag; attention is selected in the graph.
- Pinned memory disabled and ComfyUI cache disabled for predictable RAM use.

Set `H3_DOWNLOAD_MODELS=0` for a node-only/CUDA smoke boot. The default is `1`.

The direct CUDA-driver preflight retries for one minute by default and records
the host driver, NVIDIA device files, and `libcuda` initialization before the
PyTorch payload is downloaded. It then runs a real PyTorch CUDA matrix test.
If CUDA, runtime installation, or ComfyUI startup fails, the container stays
alive and serves the failure at both `:8188/` and `:8189/launch.log` instead of
crash-looping. Set `H3_HOLD_ON_ERROR=0` only in automated tests where a failed
container must exit.

Model download failures are reported as `model_download_failed`; they never
claim readiness, and the UI remains available for diagnosis. Failed GPU Pods
still cost money until stopped: the operator must stop a failed paid test.

`NVIDIA_VISIBLE_DEVICES=void` alone is not evidence that CUDA is broken.
RunPod can mount devices separately from NVIDIA Container Toolkit. The direct
CUDA probe and PyTorch matrix test determine actual GPU health.

For diagnostic use only, `--build-arg BAKE_PYTORCH=0` retains the former slim
image behavior. Production builds bake the runtime, never the models.
`H3_DEVICE=cpu` is an explicit CI mode; it does not validate GPU readiness.

After ComfyUI is ready, validate the live runtime from any machine with:

```bash
python3 scripts/preflight.py --url https://POD_ID-8188.proxy.runpod.net --require-models
```

The preflight checks every node used by the pinned Turbo8 graph, the requested
PDD and KJNodes nodes, all six model filenames, and the
`video/h265-mp4-16in` format exposed by VideoHelperSuite. It requires a CUDA
device unless `--allow-cpu` is explicitly used for a CI-only node check.

## Publishing

GitHub Actions builds only `linux/amd64` and publishes immutable SHA tags plus
`latest` to `ghcr.io/morphinic10/h3-runpod-runtime`. Keep the package public so
workers can pull it anonymously. Never add weights or secrets to this repo.
