#!/usr/bin/env python3
"""Exercise paid-state safeguards without contacting RunPod."""
import argparse
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import runpod


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / 'state.json'
        self.args = argparse.Namespace(image='test:image', country=None, smoke=True,
                                       min_download_mbps=500, dry_run=False,
                                       boot_minutes=1, boot_budget=0.20)
        self.calls = []

    def api(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        if method == 'GET' and path == '/pods':
            return []
        if method == 'POST' and path == '/pods':
            return {'id': 'test-pod', 'costPerHr': 0.34}
        if method == 'GET' and path == '/pods/test-pod':
            return {'id': 'test-pod', 'desiredStatus': 'EXITED'}
        return {}

    def run_failure(self, response):
        with patch.object(runpod, 'STATE', self.state), \
             patch.object(runpod, 'balance', return_value=10), \
             patch.object(runpod, 'request', side_effect=self.api), \
             patch.object(runpod, 'remote_json', side_effect=response), \
             patch.object(runpod.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaises(RuntimeError):
                runpod.up(self.args)
        self.assertEqual(sum(method == 'POST' and path.endswith('/stop')
                             for method, path, _ in self.calls), 1)
        self.assertEqual(json.loads(self.state.read_text())['status'], 'stopped_after_failed_boot')

    def test_boot_failure_stops_exact_created_pod(self):
        self.run_failure([{'state': 'failed'}])

    def test_cpu_endpoint_is_not_gpu_success(self):
        self.run_failure([{'state': 'models_skipped'}, {'devices': [{'type': 'cpu'}]}])

    def test_model_failure_stops_pod(self):
        self.run_failure([{'state': 'model_download_failed'}])

    def test_no_second_pod_when_existing_one_is_running(self):
        with patch.object(runpod, 'request', return_value=[{'id': 'existing', 'desiredStatus': 'RUNNING'}]) as api:
            with self.assertRaises(RuntimeError):
                runpod.up(self.args)
            api.assert_called_once_with('GET', '/pods')

    def test_payload_uses_community_and_no_persistent_storage(self):
        data = runpod.payload(self.args)
        self.assertEqual(data['cloudType'], 'COMMUNITY')
        self.assertEqual(data['volumeInGb'], 0)
        self.assertNotIn('networkVolumeId', data)
        self.assertNotIn('containerRegistryAuthId', data)
        self.assertNotIn('RUNPOD_API_KEY', data['env'])


if __name__ == '__main__':
    unittest.main()
