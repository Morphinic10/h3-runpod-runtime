# H3 RunPod Runtime

Clean, model-free `linux/amd64` runtime for the current MiniMax H3 workflows.
It is intentionally independent from campaign repositories and old RunPod
controllers.

## Included in the image

- PyTorch 2.8.0 / CUDA 12.8 / cuDNN 9 runtime.
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

At first boot, the default manifest downloads the current FL2VA/PDD8/Turbo8
stack to ephemeral `/workspace/models`:

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

- Container disk: 150 GB minimum.
- Model directory: `/workspace/models`.
- ComfyUI: port `8188`.
- Boot/model log: port `8189`, path `/launch.log`.
- During boot, port `8188` serves a small status page until ComfyUI takes over.
- No network volume.
- No global Sage attention flag; attention is selected in the graph.
- Pinned memory disabled and ComfyUI cache disabled for predictable RAM use.

Set `H3_DOWNLOAD_MODELS=0` for a node-only/CUDA smoke boot. The default is `1`.

The CUDA preflight retries for one minute by default and records the host
driver, NVIDIA device files, direct `libcuda` initialization, and PyTorch CUDA
state. If CUDA, a model download, or ComfyUI startup fails, the container stays
alive and serves the failure at both `:8188/` and `:8189/launch.log` instead of
crash-looping. Set `H3_HOLD_ON_ERROR=0` only in automated tests where a failed
container must exit.

On GPU Pods, the launcher also clears RunPod's `NVIDIA_VISIBLE_DEVICES=void`
or `none` sentinel when NVIDIA device nodes are already mounted. It leaves
normal UUID/index/all values untouched and never sets `CUDA_VISIBLE_DEVICES`.

After ComfyUI is ready, validate the live runtime from any machine with:

```bash
python3 scripts/preflight.py --url https://POD_ID-8188.proxy.runpod.net --require-models
```

The preflight checks every node used by the pinned Turbo8 graph, the requested
PDD and KJNodes nodes, all six model filenames, and the
`video/h265-mp4-16in` format exposed by VideoHelperSuite.

## Publishing

GitHub Actions builds only `linux/amd64` and publishes immutable SHA tags plus
`latest` to `ghcr.io/morphinic10/h3-runpod-runtime`. Keep the package public so
workers can pull it anonymously. Never add weights or secrets to this repo.
