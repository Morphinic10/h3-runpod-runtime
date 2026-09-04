#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "config/models.tsv"
CONTRACT = ROOT / "contracts/runtime-contract.json"
REQUIRED = {
    "Dockerfile",
    ".dockerignore",
    ".gitignore",
    "README.md",
    "config/models.tsv",
    "config/extra_model_paths.yaml",
    "config/h265-mp4-16in.json",
    "contracts/runtime-contract.json",
    "workflows/current-turbo8.api.json",
    "scripts/download-models.sh",
    "scripts/entrypoint.sh",
    "scripts/preflight.py",
    ".github/workflows/build-image.yml",
}


def validate_manifest() -> tuple[int, set[str]]:
    total = 0
    names: set[str] = set()
    for number, line in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        assert len(fields) == 4, f"manifest line {number}: expected four TSV fields"
        relative_path, size, sha256, url = fields
        assert relative_path not in names, f"duplicate path: {relative_path}"
        assert not relative_path.startswith("/") and ".." not in Path(relative_path).parts
        assert size.isdigit() and int(size) > 0
        assert re.fullmatch(r"[0-9a-f]{64}", sha256)
        assert url.startswith("https://huggingface.co/")
        assert "/resolve/main/" not in url, f"URL is not revision-pinned: {url}"
        names.add(relative_path)
        total += int(size)
    assert len(names) == 6
    assert total + 10_000_000_000 < 150_000_000_000
    return total, {Path(name).name for name in names}


def main() -> None:
    present = {str(path.relative_to(ROOT)) for path in ROOT.rglob("*") if path.is_file()}
    missing = sorted(REQUIRED - present)
    assert not missing, f"missing required files: {missing}"

    for relative in ("config/h265-mp4-16in.json", "contracts/runtime-contract.json"):
        json.loads((ROOT / relative).read_text(encoding="utf-8"))
    subprocess.run(["bash", "-n", str(ROOT / "scripts/download-models.sh")], check=True)
    subprocess.run(["bash", "-n", str(ROOT / "scripts/entrypoint.sh")], check=True)

    payload_bytes, model_names = validate_manifest()
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    workflow_path = ROOT / contract["reference_workflow"]
    workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
    workflow_nodes = {node["class_type"] for node in workflow.values()}
    assert set(contract["required_models"]) == model_names
    assert workflow_nodes <= set(contract["required_nodes"])
    assert contract["required_video_format"] == "video/h265-mp4-16in"
    assert contract["turbo8_recipe"]["steps"] == 8
    assert contract["turbo8_recipe"]["lora"].endswith("8step_v1.0_768p_comfyui_bf16.safetensors")
    assert workflow["124"]["inputs"]["steps"] == 8
    assert workflow["123"]["inputs"]["sampler_name"] == "euler"
    assert workflow["124"]["inputs"]["scheduler"] == "simple"
    assert workflow["900"]["inputs"]["attention"] == "comfy kitchen attention"
    assert workflow["92"]["inputs"]["format"] == contract["required_video_format"]
    assert workflow["92"]["inputs"]["pix_fmt"] == "yuv420p10le"

    oversized = [str(path.relative_to(ROOT)) for path in ROOT.rglob("*") if path.is_file() and path.stat().st_size > 5_000_000]
    assert not oversized, f"large files do not belong in the runtime repo: {oversized}"
    forbidden_suffixes = {".safetensors", ".ckpt", ".pt", ".pth", ".mp4", ".mov"}
    forbidden = [str(path.relative_to(ROOT)) for path in ROOT.rglob("*") if path.is_file() and path.suffix.lower() in forbidden_suffixes]
    assert not forbidden, f"weight/media files found: {forbidden}"

    digest = hashlib.sha256(MANIFEST.read_bytes()).hexdigest()
    print(json.dumps({"ok": True, "model_count": len(model_names), "model_payload_bytes": payload_bytes, "manifest_sha256": digest}, indent=2))


if __name__ == "__main__":
    main()
