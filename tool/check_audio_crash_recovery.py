"""Kill the real test process at durable boundaries; verify only public workspace behavior."""
import argparse
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time
import wave

parser=argparse.ArgumentParser()
parser.add_argument('--flutter',required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
worker=['test','test/support/audio_queue_crash_worker.dart','--reporter','expanded','--no-pub']
summary=[]
for phase in ['rename','transcribe','organize','publish']:
    root=(args.output/phase).resolve()
    root.mkdir(parents=True,exist_ok=True)
    if (root/'ready').exists(): raise RuntimeError(f'Use a fresh output directory: {root}')
    with wave.open(str(root/'original.wav'),'wb') as f:
        f.setparams((1,2,8000,0,'NONE','not compressed'))
        f.writeframes(b''.join(struct.pack('<h',2048 if n%16<8 else -2048) for n in range(8000)))
    env={**os.environ,'T11_CRASH_ROOT':str(root),'T11_CRASH_PHASE':phase}
    with (root/'crashed-process.log').open('w') as log:
        child=subprocess.Popen([args.flutter,*worker],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        deadline=time.monotonic()+45
        while not (root/'ready').exists() and time.monotonic()<deadline and child.poll() is None:
            time.sleep(.05)
        if not (root/'ready').exists():
            os.killpg(child.pid,signal.SIGKILL) if child.poll() is None else None
            raise RuntimeError(f'No committed barrier in {phase}; inspect {root}')
        os.killpg(child.pid,signal.SIGKILL)
        child.wait(timeout=5)
    with (root/'recovery.log').open('w') as log:
        recovered=subprocess.run([args.flutter,*worker],env={**env,'T11_CRASH_VERIFY':'1'},stdout=log,stderr=subprocess.STDOUT,timeout=45)
    if recovered.returncode: raise RuntimeError(f'Recovery failed in {phase}; inspect {root}')
    result=json.loads((root/'evidence.json').read_text())
    result['termination']='SIGKILL (no close)'
    summary.append(result)
    print(json.dumps(result,ensure_ascii=False),flush=True)
(args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
