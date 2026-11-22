"""Start the whole local stack with one command: `make dev`, then open http://localhost:8000

  :8080  Risk Scoring API (the real app, APP_ENV=local -> .localbucket/ plays S3)
  :8000  local_stack: UI, presign, S3 PUT + events, WebSocket (stand-ins for AWS)
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
env = {**os.environ, "APP_ENV": "local", "PYTHONPATH": str(ROOT)}
procs = [
    subprocess.Popen([sys.executable, "-m", "uvicorn", "audit_api.app:app", "--port", "8080"], cwd=ROOT, env=env),
    subprocess.Popen([sys.executable, "-m", "uvicorn", "local_stack.app:app", "--port", "8000"], cwd=ROOT, env=env),
]
time.sleep(2)
print("\n  UI:  http://localhost:8000\n  API: http://localhost:8080/health\n  Ctrl+C to stop\n", flush=True)


def stop(*_):
    for p in procs:
        p.send_signal(signal.SIGINT)
    for p in procs:
        p.wait(timeout=10)
    sys.exit(0)


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
while all(p.poll() is None for p in procs):
    time.sleep(0.5)
stop()
