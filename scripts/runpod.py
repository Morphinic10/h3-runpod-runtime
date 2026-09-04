#!/usr/bin/env python3
"""One-command Community 4090 boot with a bounded wait and automatic failure stop."""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.runpod' / 'state.json'
DEFAULT_ENV = Path.home() / 'Desktop/H3_Workflow_Lab/.secrets/runpod.env'


def key() -> str:
    token = os.environ.get('RUNPOD_API_KEY')
    if token:
        return token
    env_path = Path(os.environ.get('RUNPOD_ENV_FILE', str(DEFAULT_ENV)))
    if env_path.is_file():
        for line in env_path.read_text().splitlines():
            name, sep, value = line.strip().partition('=')
            if sep and name == 'RUNPOD_API_KEY':
                return value.strip().strip('\"\'')
    raise RuntimeError('Set RUNPOD_API_KEY or RUNPOD_ENV_FILE; no key is stored in this repo.')


def request(method: str, path: str, payload=None):
    req = urllib.request.Request(
        'https://rest.runpod.io/v1' + path,
        method=method,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer ' + key(), 'Content-Type': 'application/json', 'User-Agent': 'h3-runpod/1.0'},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        # Do not print the response object or request headers, which contain credentials.
        body = error.read().decode('utf-8', 'replace')
        raise RuntimeError(f'RunPod {method} {path}: {error.code} {body[:600]}') from None


def remote_json(url: str):
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.load(response)


def balance() -> float:
    req = urllib.request.Request(
        'https://api.runpod.io/graphql?' + urllib.parse.urlencode({'api_key': key()}),
        data=json.dumps({'query': 'query { myself { clientBalance } }'}).encode(),
        headers={'Content-Type': 'application/json', 'User-Agent': 'h3-runpod/1.0'},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        data = json.load(response)
    if data.get('errors'):
        raise RuntimeError('Could not verify account balance; no Pod will be created.')
    return float(data['data']['myself']['clientBalance'])


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2) + '\n')


def stop(pod_id: str):
    request('POST', f'/pods/{pod_id}/stop')
    pod = request('GET', f'/pods/{pod_id}')
    if pod.get('desiredStatus') != 'EXITED':
        raise RuntimeError(f'Stop not confirmed for {pod_id}: {pod.get("desiredStatus")}')
    print(f'STOPPED {pod_id}; no GPU kept running.', flush=True)


def payload(args):
    result = {
        'name': 'h3-comfy-4090-community',
        'cloudType': 'COMMUNITY', 'computeType': 'GPU',
        'gpuTypeIds': ['NVIDIA GeForce RTX 4090'], 'gpuCount': 1,
        'imageName': args.image, 'allowedCudaVersions': ['13.0', '12.9', '12.8'],
        'containerDiskInGb': 150, 'volumeInGb': 0,
        'minRAMPerGPU': 48, 'minVCPUPerGPU': 8,
        'minDownloadMbps': args.min_download_mbps,
        'ports': ['8188/http', '8189/http'], 'interruptible': False,
        'dockerEntrypoint': [], 'dockerStartCmd': [],
        'env': {'H3_DOWNLOAD_MODELS': '0' if args.smoke else '1', 'H3_CUDA_RETRIES': '3'},
    }
    if args.country:
        result['countryCodes'] = args.country
    return result


def up(args):
    from preflight import get_json, resolve_workflow, strings

    if args.dry_run:
        print(json.dumps(payload(args), indent=2))
        return
    active = [p for p in request('GET', '/pods') if p.get('desiredStatus') not in ('EXITED', 'TERMINATED')]
    if active:
        raise RuntimeError('An existing Pod is active; inspect it first: ' + ', '.join(p['id'] for p in active))
    available_balance = balance()
    print(f'Balance before boot: ${available_balance:.2f}', flush=True)
    if available_balance < args.boot_budget:
        raise RuntimeError('Balance is below the boot budget; no Pod will be created.')
    if not args.image:
        raise RuntimeError('Pass --image with the published, tested image digest.')
    contract_path = ROOT / 'contracts/runtime-contract.json'
    contract = json.loads(contract_path.read_text())
    workflow = json.loads(resolve_workflow(contract_path, contract['reference_workflow']).read_text())
    required_nodes = set(contract['required_nodes']) | {n['class_type'] for n in workflow.values()}
    pod = request('POST', '/pods', payload(args))
    pid = pod['id']
    state = {k: pod.get(k) for k in ('id', 'name', 'machineId', 'costPerHr')}
    state.update(created_unix=time.time(), image=args.image, status='booting')
    base = f'https://{pid}-8188.proxy.runpod.net'
    log_base = f'https://{pid}-8189.proxy.runpod.net'
    print(f'Created {pid}: {base}\nLogs: {log_base}/launch.log', flush=True)
    ready = False
    deadline = time.monotonic() + args.boot_minutes * 60
    # Conservative GPU+container-disk estimate. Boot stops before this budget,
    # even if billing has not yet appeared in the account balance.
    started = time.monotonic()
    last_state = None
    try:
        save(state)
        hourly = float(pod.get('costPerHr') or 0.34) + 150 * 0.10 / 720
        while time.monotonic() < deadline:
            estimate = (time.monotonic() - started) * hourly / 3600
            if estimate >= args.boot_budget:
                raise RuntimeError(f'Boot budget reached (${args.boot_budget:.2f}).')
            try:
                boot = remote_json(log_base + '/status.json')
                phase = boot.get('state')
                if phase != last_state:
                    print(f'Boot: {phase} — {boot.get("message", "")}', flush=True)
                    last_state = phase
                if phase in ('failed', 'model_download_failed'):
                    raise RuntimeError(f'Boot failed: {phase}. {log_base}/launch.log')
                stats = remote_json(base + '/system_stats')
                if not any(d.get('type') == 'cuda' for d in stats.get('devices', [])):
                    raise RuntimeError('ComfyUI did not report a CUDA device.')
                if args.smoke or phase == 'models_ready':
                    info = get_json(base, '/object_info', timeout=20)
                    missing = sorted(required_nodes - info.keys())
                    available = set(strings(info))
                    if missing:
                        raise RuntimeError(f'Missing nodes: {missing}')
                    if contract['required_video_format'] not in available:
                        raise RuntimeError('Missing true 10-bit VideoHelperSuite format.')
                    if not args.smoke:
                        absent = set(contract['required_models']) - available
                        if absent:
                            raise RuntimeError(f'Missing models after download: {sorted(absent)}')
                    state['status'] = 'ready_without_models' if args.smoke else 'ready'
                    save(state)
                    ready = True
                    print(f'READY {base}\nStop when finished: python3 scripts/runpod.py stop', flush=True)
                    return
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                pass  # Proxy endpoints normally return 404 while the image is pulling.
            time.sleep(15)
        raise RuntimeError(f'Boot exceeded {args.boot_minutes} minutes; no ready Pod was left running.')
    finally:
        if not ready:
            try:
                with urllib.request.urlopen(log_base + '/launch.log', timeout=10) as response:
                    STATE.with_name(f'{pid}-launch.log').write_bytes(response.read())
            except Exception:
                pass
            stop(pid)
            state['status'] = 'stopped_after_failed_boot'
            save(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['up', 'status', 'stop'])
    published = ROOT / 'config/published-image.json'
    image = json.loads(published.read_text())['image'] if published.is_file() else None
    parser.add_argument('--image', default=os.environ.get('H3_RUNPOD_IMAGE', image))
    parser.add_argument('--country', action='append')
    parser.add_argument('--min-download-mbps', type=int, default=500)
    parser.add_argument('--boot-minutes', type=float, default=15)
    parser.add_argument('--boot-budget', type=float, default=0.20)
    parser.add_argument('--smoke', action='store_true', help='Skip models; verify CUDA and nodes only')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.boot_minutes <= 0 or args.boot_budget <= 0:
        parser.error('Boot time and budget must be positive.')
    if args.action == 'up':
        up(args)
        return
    if not STATE.exists():
        raise RuntimeError('No Pod was created by this launcher.')
    state = json.loads(STATE.read_text())
    if args.action == 'stop':
        stop(state['id'])
        state['status'] = 'stopped'
        save(state)
    else:
        pod = request('GET', '/pods/' + state['id'])
        print(json.dumps({k: pod.get(k) for k in ('id', 'name', 'machineId', 'desiredStatus', 'costPerHr')}, indent=2))


if __name__ == '__main__':
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, KeyboardInterrupt) as error:
        print(f'ERROR: {error or "Interrupted"}', file=sys.stderr)
        raise SystemExit(1)
