#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "contracts/runtime-contract.json"


def get_json(base: str, path: str, timeout: int = 120) -> dict:
    request = urllib.request.Request(base.rstrip("/") + path, headers={"User-Agent": "h3-runtime-preflight/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def strings(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


def resolve_workflow(contract_path: Path, configured: str) -> Path:
    candidates = [
        contract_path.parent.parent / configured,
        ROOT / configured,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"reference workflow not found: {configured}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--require-models", action="store_true")
    args = parser.parse_args()

    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    workflow_path = resolve_workflow(args.contract, contract["reference_workflow"])
    workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
    workflow_nodes = {node["class_type"] for node in workflow.values()}
    required_nodes = sorted(set(contract["required_nodes"]) | workflow_nodes)
    stats = get_json(args.url, "/system_stats", timeout=60)
    missing_nodes = []
    object_info = {}
    for node in required_nodes:
        encoded = urllib.parse.quote(node, safe="")
        payload = get_json(args.url, "/object_info/" + encoded)
        if node not in payload:
            missing_nodes.append(node)
        else:
            object_info[node] = payload[node]

    missing_models = []
    if args.require_models:
        available = set(strings(object_info))
        for model in contract["required_models"]:
            if model not in available:
                missing_models.append(model)

    available_formats = set(strings(object_info.get("VHS_VideoCombine", {})))
    missing_video_format = None
    if contract["required_video_format"] not in available_formats:
        missing_video_format = contract["required_video_format"]

    result = {
        "ok": not missing_nodes and not missing_models and not missing_video_format,
        "devices": stats.get("devices", []),
        "checked_nodes": len(required_nodes),
        "missing_nodes": missing_nodes,
        "missing_models": missing_models,
        "missing_video_format": missing_video_format,
        "runtime_status": contract["runtime_status"],
        "turbo8_recipe": contract["turbo8_recipe"],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
