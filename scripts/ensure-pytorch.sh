#!/usr/bin/env bash
set -Eeuo pipefail

TORCH_VERSION="${H3_TORCH_VERSION:-2.8.0}"
TORCHVISION_VERSION="${H3_TORCHVISION_VERSION:-0.23.0}"
TORCHAUDIO_VERSION="${H3_TORCHAUDIO_VERSION:-2.8.0}"
TORCH_INDEX_URL="${H3_TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"

if python - "$TORCH_VERSION" <<'PY'
import sys

expected = sys.argv[1]
try:
    import torch
except Exception:
    raise SystemExit(1)
if not torch.__version__.split("+")[0] == expected:
    raise SystemExit(1)
if not str(torch.version.cuda).startswith("12.8"):
    raise SystemExit(1)
print(f"[runtime] PyTorch already ready: {torch.__version__} CUDA {torch.version.cuda}")
PY
then
  exit 0
fi

echo "[runtime] installing PyTorch ${TORCH_VERSION} CUDA 12.8 after container start"
python -m pip install \
  --no-cache-dir \
  --constraint /opt/h3/config/python-constraints.txt \
  --index-url "$TORCH_INDEX_URL" \
  "torch==${TORCH_VERSION}" \
  "torchvision==${TORCHVISION_VERSION}" \
  "torchaudio==${TORCHAUDIO_VERSION}"

python - "$TORCH_VERSION" "$TORCHVISION_VERSION" "$TORCHAUDIO_VERSION" <<'PY'
import sys
import torch
import torchaudio
import torchvision

expected = [item.split("+")[0] for item in sys.argv[1:]]
actual = [
    torch.__version__.split("+")[0],
    torchvision.__version__.split("+")[0],
    torchaudio.__version__.split("+")[0],
]
assert actual == expected, (actual, expected)
assert str(torch.version.cuda).startswith("12.8"), torch.version.cuda
print(
    f"[runtime] PyTorch runtime ready: torch={torch.__version__} "
    f"torchvision={torchvision.__version__} torchaudio={torchaudio.__version__} "
    f"CUDA={torch.version.cuda}"
)
PY
