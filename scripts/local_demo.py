"""Run the agreed flow on your laptop, no AWS needed.

Start the API first:   make run        (APP_ENV=local, a folder .localbucket/ plays the S3 bucket)
Then in another shell: make demo

What it does (mirrors AWS exactly):
  1. "UI" writes the request JSON to requests/<id>.json            (agreed step 1)
  2. builds the S3 event AWS would send and calls the REAL trigger  (steps 2-3)
     Lambda handler, which POSTs the S3 path to the API
  3. waits for output/<id>.json and prints it                       (steps 4-7)
"""
import argparse
import importlib.util
import json
import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUCKET_DIR = ROOT / ".localbucket"


def load_trigger():
    spec = importlib.util.spec_from_file_location("trigger", ROOT / "lambdas/trigger/handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", default="valid_request.json", help="file in samples/")
    ap.add_argument("--api", default="http://localhost:8080/audit")
    args = ap.parse_args()

    request = json.loads((ROOT / "samples" / args.sample).read_text())
    rid = request["request_id"]
    for p in (BUCKET_DIR / "output" / f"{rid}.json",):
        p.unlink(missing_ok=True)                       # allow re-running the same demo id
    for d in ("provider", "cms", "payer"):
        (BUCKET_DIR / "responses" / d / f"{rid}.json").unlink(missing_ok=True)

    req_path = BUCKET_DIR / "requests" / f"{rid}.json"
    req_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "samples" / args.sample, req_path)
    print(f"1. UI wrote        requests/{rid}.json")

    os.environ["API_URL"] = args.api
    trigger = load_trigger()
    event = {"Records": [{"s3": {"bucket": {"name": "local-bucket"}, "object": {"key": f"requests/{rid}.json"}}}]}
    print(f"2-3. trigger Lambda -> {trigger.handler(event)}")

    out = BUCKET_DIR / "output" / f"{rid}.json"
    for _ in range(50):
        if out.exists():
            break
        time.sleep(0.1)
    else:
        sys.exit("no output after 5 s - is `make run` running?")
    files = sorted(str(p.relative_to(BUCKET_DIR)) for p in BUCKET_DIR.rglob(f"{rid}.json"))
    print("4-7. files written:", *files, sep="\n     ")
    print("result:", json.dumps(json.loads(out.read_text()), indent=2))


if __name__ == "__main__":
    main()
