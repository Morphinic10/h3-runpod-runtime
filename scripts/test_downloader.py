#!/usr/bin/env python3
"""Regression for a failed final download child being mistaken for readiness."""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == 'linux', 'downloader targets Linux containers')
class DownloaderTests(unittest.TestCase):
    def test_last_child_failure_cannot_report_ready(self):
        script = Path(__file__).with_name('download-models.sh')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            # No network, model bytes or real waiting in this failure test.
            (bin_dir / 'curl').write_text('#!/bin/sh\nexit 22\n')
            (bin_dir / 'sleep').write_text('#!/bin/sh\nexit 0\n')
            for path in bin_dir.iterdir():
                path.chmod(0o755)
            executable = root / 'download-models.sh'
            shutil.copyfile(script, executable)
            executable.chmod(0o755)
            manifest = root / 'models.tsv'
            sha = hashlib.sha256(b'abc').hexdigest()
            manifest.write_text(f'test/model.safetensors\t3\t{sha}\thttps://invalid.test/model\n')
            env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                       MODEL_MANIFEST=str(manifest), MODEL_DIR=str(root / 'models'),
                       MODEL_RESERVE_BYTES='0', MODEL_DOWNLOAD_CONCURRENCY='4')
            result = subprocess.run([str(executable)], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 22, result.stdout + result.stderr)
            self.assertNotIn('all selected models are ready', result.stdout)


if __name__ == '__main__':
    unittest.main()
