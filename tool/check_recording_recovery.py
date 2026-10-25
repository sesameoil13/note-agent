"""Kill a real Flutter host process; verify recording recovery at NoteWorkspace.

The microphone is a controlled OS boundary, not a real device/mic acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--flutter', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--phase', choices=['finished', 'active'], default='finished')
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
env = {**os.environ, 'T09_RECOVERY_ROOT': str(root), 'T09_RECOVERY_PHASE': args.phase}
worker = ['test', '--no-pub', 'test/support/recording_recovery_worker.dart', '--reporter', 'expanded']
with (root / 'killed-process.log').open('w') as log:
    child = subprocess.Popen([args.flutter, *worker], env=env, stdout=log,
                             stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 45
    while not (root / 'ready').exists() and time.monotonic() < deadline and child.poll() is None:
        time.sleep(.05)
    if not (root / 'ready').exists():
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        raise RuntimeError('No committed barrier; inspect killed-process.log')
    os.killpg(child.pid, signal.SIGKILL)
    child.wait(timeout=5)
with (root / 'recovery.log').open('w') as log:
    result = subprocess.run([args.flutter, *worker], env={**env, 'T09_RECOVERY_VERIFY': '1'},
                            stdout=log, stderr=subprocess.STDOUT, timeout=45)
if result.returncode:
    raise RuntimeError('Recovery failed; inspect recovery.log')
print((root / 'evidence.json').read_text())
