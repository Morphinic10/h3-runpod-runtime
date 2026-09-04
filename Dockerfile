ARG BASE_IMAGE=pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime@sha256:417bd75df6365104c283ea4c1651fb3530d9eb5a4c2fafa51943cff2a94e6385
FROM ${BASE_IMAGE}

ARG COMFYUI_COMMIT=12d5279438bfefc058a269eae805ceab6047777f
ARG KJ_NODES_COMMIT=3f20054214fec9f9234fd3841ae6f1e4287948f6
ARG VIDEO_HELPER_SUITE_COMMIT=4ee72c065db22c9d96c2427954dc69e7b908444b
ARG PDD_NODE_COMMIT=83353308bc14dc49b2d82e263a1cafb94169b849

LABEL org.opencontainers.image.title="H3 RunPod Runtime" \
      org.opencontainers.image.description="Model-free MiniMax H3 runtime with PDD, KJNodes, VideoHelperSuite and true HEVC Main10 output" \
      org.opencontainers.image.source="https://github.com/morphinic10/h3-runpod-runtime" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    COMFY_HOME=/opt/ComfyUI \
    MODEL_DIR=/workspace/models \
    MODEL_MANIFEST=/opt/h3/config/models.tsv \
    MODEL_RESERVE_BYTES=10000000000 \
    MODEL_DOWNLOAD_CONCURRENCY=4 \
    H3_DOWNLOAD_MODELS=1 \
    INPUT_DIR=/workspace/ComfyUI/input \
    OUTPUT_DIR=/workspace/ComfyUI/output \
    TEMP_DIR=/workspace/ComfyUI/temp \
    USER_DIR=/workspace/ComfyUI/user \
    EXTRA_MODEL_PATHS_CONFIG=/opt/h3/config/extra_model_paths.yaml \
    COMFYUI_PORT=8188 \
    H3_LOG_PORT=8189 \
    COMFYUI_DISABLE_PINNED_MEMORY=1 \
    COMFYUI_CACHE_NONE=1 \
    GPU_TELEMETRY_INTERVAL_S=10

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         build-essential ca-certificates curl ffmpeg git libgl1 libglib2.0-0 procps tini \
    && rm -rf /var/lib/apt/lists/*

COPY config/python-constraints.txt /opt/h3/config/python-constraints.txt

RUN git clone --filter=blob:none --no-checkout https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI \
    && git -C /opt/ComfyUI fetch --depth 1 origin "$COMFYUI_COMMIT" \
    && git -C /opt/ComfyUI checkout --detach "$COMFYUI_COMMIT" \
    && test "$(git -C /opt/ComfyUI rev-parse HEAD)" = "$COMFYUI_COMMIT" \
    && grep -Ev '^(torch|torchvision|torchaudio)([<>=!~ ].*)?$' /opt/ComfyUI/requirements.txt > /tmp/comfy-requirements.txt \
    && python -m pip install \
         --constraint /opt/h3/config/python-constraints.txt \
         --requirement /tmp/comfy-requirements.txt \
    && rm -rf /opt/ComfyUI/.git /tmp/comfy-requirements.txt

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
    && python -m pip install \
         --constraint /opt/h3/config/python-constraints.txt \
         --requirement /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt \
    && rm -rf /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/.git

RUN git clone --filter=blob:none --no-checkout https://github.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc.git /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc fetch --depth 1 origin "$PDD_NODE_COMMIT" \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc checkout --detach "$PDD_NODE_COMMIT" \
    && test "$(git -C /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc rev-parse HEAD)" = "$PDD_NODE_COMMIT" \
    && rm -rf /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc/.git

COPY config/models.tsv /opt/h3/config/models.tsv
COPY config/extra_model_paths.yaml /opt/h3/config/extra_model_paths.yaml
COPY config/h265-mp4-16in.json /opt/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/video_formats/h265-mp4-16in.json
COPY contracts/runtime-contract.json /opt/h3/contracts/runtime-contract.json
COPY workflows/current-turbo8.api.json /opt/h3/workflows/current-turbo8.api.json
COPY scripts/download-models.sh scripts/entrypoint.sh /usr/local/bin/
COPY scripts/preflight.py /opt/h3/tools/preflight.py

RUN chmod 0755 /usr/local/bin/download-models.sh /usr/local/bin/entrypoint.sh \
    && bash -n /usr/local/bin/download-models.sh \
    && bash -n /usr/local/bin/entrypoint.sh \
    && python -m compileall -q /opt/h3/tools /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes/nodes/minimax_nodes.py /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc \
    && python -c 'import importlib.util, torch; assert torch.__version__.startswith("2.8.0"); assert str(torch.version.cuda).startswith("12.8"); assert importlib.util.find_spec("comfy_kitchen") is not None' \
    && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265 \
    && ffmpeg -hide_banner -loglevel error -f lavfi -i color=size=64x64:rate=1 -frames:v 1 -pix_fmt yuv420p10le -c:v libx265 -x265-params log-level=error /tmp/h3-main10.mp4 \
    && test "$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 /tmp/h3-main10.mp4)" = "yuv420p10le" \
    && rm -f /tmp/h3-main10.mp4 \
    && mkdir -p /workspace/ComfyUI/input /workspace/ComfyUI/output /workspace/ComfyUI/temp /workspace/ComfyUI/user/default/workflows

EXPOSE 8188 8189

HEALTHCHECK --interval=30s --timeout=10s --start-period=45m --retries=3 \
  CMD curl --fail --silent "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
