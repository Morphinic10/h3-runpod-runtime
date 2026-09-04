#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 scripts/runpod.py up
python3 - <<'PY'
import json
import webbrowser
from pathlib import Path

pod_id = json.loads(Path('.runpod/state.json').read_text())['id']
webbrowser.open(f'https://{pod_id}-8188.proxy.runpod.net')
PY
