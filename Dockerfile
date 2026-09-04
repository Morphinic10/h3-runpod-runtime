ARG BASE_IMAGE=python:3.11-slim-bookworm@sha256:b1add8a6f2aca6bcfcf0b9c9b522352f7ce0d62a3d556a2f2f32511aa0cca250

FROM ${BASE_IMAGE} AS builder

ARG COMFYUI_COMMIT=12d5279438bfefc058a269eae805ceab6047777f
ARG KJ_NODES_COMMIT=3f20054214fec9f9234fd3841ae6f1e4287948f6
ARG VIDEO_HELPER_SUITE_COMMIT=4ee72c065db22c9d96c2427954dc69e7b908444b
ARG PDD_NODE_COMMIT=83353308bc14dc49b2d82e263a1cafb94169b849

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && python -m venv /opt/venv \
    && /opt/venv/bin/python -m pip install --upgrade pip setuptools wheel

ENV PATH=/opt/venv/bin:$PATH

COPY config/python-constraints.txt /opt/h3/config/python-constraints.txt

# Install the ComfyUI dependency graph without baking the 4+ GiB CUDA/PyTorch
# runtime into the image. Tiny metadata-only placeholders satisfy dependency
# resolution in this builder stage; the real pinned cu128 wheels are installed
# visibly and retryably after the Pod container is already serving boot logs.
RUN python - <<'PY'
from pathlib import Path
from sysconfig import get_paths

site = Path(get_paths()["purelib"])
for name, version in (
    ("torch", "2.8.0"),
    ("torchvision", "0.23.0"),
    ("torchaudio", "2.8.0"),
):
    dist = site / f"{name}-{version}.dist-info"
    dist.mkdir(parents=True, exist_ok=True)
    (dist / "METADATA").write_text(
        f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
        encoding="utf-8",
    )
    (dist / "INSTALLER").write_text("h3-runtime-placeholder\n", encoding="utf-8")
    (dist / "RECORD").write_text("", encoding="utf-8")
PY

RUN git clone --filter=blob:none --no-checkout https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI \
    && git -C /opt/ComfyUI fetch --depth 1 origin "$COMFYUI_COMMIT" \
    && git -C /opt/ComfyUI checkout --detach "$COMFYUI_COMMIT" \
    && test "$(git -C /opt/ComfyUI rev-parse HEAD)" = "$COMFYUI_COMMIT" \
    && python -m pip install \
         --constraint /opt/h3/config/python-constraints.txt \
         --requirement /opt/ComfyUI/requirements.txt \
    && rm -rf /opt/ComfyUI/.git

RUN git clone --filter=blob:none --no-checkout https://github.com/kijai/ComfyUI-KJNodes.git /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes fetch --depth 1 origin "$KJ_NODES_COMMIT" \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes checkout --detach "$KJ_NODES_COMMIT" \
    && test "$(git -C /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes rev-parse HEAD)" = "$KJ_NODES_COMMIT" \
    && python -m pip install \
         --constraint /opt/h3/config/python-constraints.txt \
         --requirement /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes/requirements.txt \
    && rm -rf /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes/.git

RUN git clone --filter=blob:none --no-checkout https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite fetch --depth 1 origin "$VIDEO_HELPER_SUITE_COMMIT" \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite checkout --detach "$VIDEO_HELPER_SUITE_COMMIT" \
    && test "$(git -C /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite rev-parse HEAD)" = "$VIDEO_HELPER_SUITE_COMMIT" \
    && grep -Ev '^(opencv-python)([<>=!~ ].*)?$' /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt > /tmp/vhs-requirements.txt \
    && python -m pip install \
         --constraint /opt/h3/config/python-constraints.txt \
         --requirement /tmp/vhs-requirements.txt \
    && rm -rf /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/.git /tmp/vhs-requirements.txt

RUN git clone --filter=blob:none --no-checkout https://github.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc.git /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc fetch --depth 1 origin "$PDD_NODE_COMMIT" \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc checkout --detach "$PDD_NODE_COMMIT" \
    && test "$(git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc rev-parse HEAD)" = "$PDD_NODE_COMMIT" \
    && rm -rf /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc/.git \
    && python -m pip check \
    && rm -rf \
         /opt/venv/lib/python3.11/site-packages/torch-2.8.0.dist-info \
         /opt/venv/lib/python3.11/site-packages/torchvision-0.23.0.dist-info \
         /opt/venv/lib/python3.11/site-packages/torchaudio-2.8.0.dist-info

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="H3 RunPod Runtime" \
      org.opencontainers.image.description="Slim model-free MiniMax H3 runtime with observable cu128 bootstrap" \
      org.opencontainers.image.source="https://github.com/morphinic10/h3-runpod-runtime" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    COMFY_HOME=/opt/ComfyUI \
    MODEL_DIR=/workspace/models \
    MODEL_MANIFEST=/opt/h3/config/models.tsv \
    MODEL_RESERVE_BYTES=10000000000 \
    MODEL_DOWNLOAD_CONCURRENCY=4 \
    H3_DOWNLOAD_MODELS=1 \
    H3_TORCH_VERSION=2.8.0 \
    H3_TORCHVISION_VERSION=0.23.0 \
    H3_TORCHAUDIO_VERSION=2.8.0 \
    H3_TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128 \
    INPUT_DIR=/workspace/ComfyUI/input \
    OUTPUT_DIR=/workspace/ComfyUI/output \
    TEMP_DIR=/workspace/ComfyUI/temp \
    USER_DIR=/workspace/ComfyUI/user \
    EXTRA_MODEL_PATHS_CONFIG=/opt/h3/config/extra_model_paths.yaml \
    COMFYUI_PORT=8188 \
    H3_LOG_PORT=8189 \
    COMFYUI_DISABLE_PINNED_MEMORY=1 \
    COMFYUI_CACHE_NONE=1 \
    GPU_TELEMETRY_INTERVAL_S=10 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates curl ffmpeg libgl1 libglib2.0-0 procps tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/ComfyUI /opt/ComfyUI
COPY --from=builder /opt/h3/config/python-constraints.txt /opt/h3/config/python-constraints.txt

COPY config/models.tsv /opt/h3/config/models.tsv
COPY config/extra_model_paths.yaml /opt/h3/config/extra_model_paths.yaml
COPY config/h265-mp4-16in.json /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/video_formats/h265-mp4-16in.json
COPY contracts/runtime-contract.json /opt/h3/contracts/runtime-contract.json
COPY workflows/current-turbo8.api.json /opt/h3/workflows/current-turbo8.api.json
COPY scripts/download-models.sh scripts/ensure-pytorch.sh scripts/entrypoint.sh /usr/local/bin/
COPY scripts/preflight.py /opt/h3/tools/preflight.py

RUN chmod 0755 /usr/local/bin/download-models.sh /usr/local/bin/ensure-pytorch.sh /usr/local/bin/entrypoint.sh \
    && bash -n /usr/local/bin/download-models.sh \
    && bash -n /usr/local/bin/ensure-pytorch.sh \
    && bash -n /usr/local/bin/entrypoint.sh \
    && python -m compileall -q /opt/h3/tools /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes/nodes/minimax_nodes.py /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc \
    && python -c 'import importlib.util; assert importlib.util.find_spec("comfy_kitchen") is not None; assert importlib.util.find_spec("torch") is None' \
    && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265 \
    && ffmpeg -hide_banner -loglevel error -f lavfi -i color=size=64x64:rate=1 -frames:v 1 -pix_fmt yuv420p10le -c:v libx265 -x265-params log-level=error /tmp/h3-main10.mp4 \
    && test "$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 /tmp/h3-main10.mp4)" = "yuv420p10le" \
    && rm -f /tmp/h3-main10.mp4 \
    && mkdir -p /workspace/ComfyUI/input /workspace/ComfyUI/output /workspace/ComfyUI/temp /workspace/ComfyUI/user/default/workflows

EXPOSE 8188 8189

HEALTHCHECK --interval=30s --timeout=10s --start-period=60m --retries=3 \
  CMD curl --fail --silent "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
