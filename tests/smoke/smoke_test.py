"""Development smoke test against a REAL environment (acceptance criterion 3).

Usage (credentials for that account already active, e.g. `aws sso login --profile crs-nonprod`):
    python tests/smoke/smoke_test.py --env nonprod --account 123456789012
    python tests/smoke/smoke_test.py --env nonprod --account 123456789012 --ws wss://xxx.execute-api.ap-south-1.amazonaws.com/nonprod

Checks the whole agreed flow through S3 events - exactly what the UI does:
  1. valid request  -> 3 response files + output with status COMPLETED
  2. invalid request -> output with status INVALID and NO response files (step 4: no component calls)
  3. optional: WebSocket push arrives with the same request_id (needs `pip install websockets`)
Exit code 0 = all passed. Paste the printed report into docs/ENV_SETUP.md.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import boto3

SAMPLES = Path(__file__).resolve().parents[2] / "samples"
RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    RESULTS.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    return ok


def exists(s3, bucket: str, key: str) -> bool:
    resp = s3.list_objects_v2(Bucket=bucket, Prefix=key, MaxKeys=1)
    return any(o["Key"] == key for o in resp.get("Contents", []))


def wait_for(s3, bucket: str, key: str, timeout: int) -> dict | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if exists(s3, bucket, key):
            return json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        time.sleep(2)
    return None


def put_request(s3, bucket: str, sample: str, request_id: str) -> None:
    body = json.loads((SAMPLES / sample).read_text())
    body["request_id"] = request_id
    s3.put_object(Bucket=bucket, Key=f"requests/{request_id}.json", Body=json.dumps(body).encode(),
                  ContentType="application/json", ServerSideEncryption="aws:kms")


async def ws_roundtrip(ws_url: str, s3, bucket: str, request_id: str, timeout: int) -> dict | None:
    import websockets  # optional dependency

    async with websockets.connect(ws_url) as ws:
        await ws.send(json.dumps({"action": "subscribe", "request_id": request_id}))
        await asyncio.sleep(1)  # let the subscription land before the result can
        put_request(s3, bucket, "valid_request.json", request_id)
        msg = await asyncio.wait_for(ws.recv(), timeout=timeout)
        return json.loads(msg)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True, choices=["nonprod", "prod"])
    ap.add_argument("--account", required=True, help="AWS account id (bucket name suffix)")
    ap.add_argument("--region", default="ap-south-1")
    ap.add_argument("--ws", help="WebSocket URL (terraform output websocket_url)")
    ap.add_argument("--timeout", type=int, default=90)
    a = ap.parse_args()

    bucket = f"crs-{a.env}-data-{a.account}"
    s3 = boto3.client("s3", region_name=a.region)
    stamp = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    print(f"Smoke test {a.env} bucket={bucket} at {stamp}Z")

    # 1. valid request end to end
    rid = f"smoke-{stamp}"
    put_request(s3, bucket, "valid_request.json", rid)
    out = wait_for(s3, bucket, f"output/{rid}.json", a.timeout)
    check("valid request produces output", out is not None, f"output/{rid}.json")
    if out:
        check("status COMPLETED", out.get("status") == "COMPLETED", json.dumps(out)[:200])
        for script in ("provider", "cms", "payer"):
            check(f"{script} response written", exists(s3, bucket, f"responses/{script}/{rid}.json"))

    # 2. invalid request: error result, no scripts
    bad = f"smoke-bad-{stamp}"
    put_request(s3, bucket, "invalid_request.json", bad)
    out = wait_for(s3, bucket, f"output/{bad}.json", a.timeout)
    check("invalid request produces output", out is not None)
    if out:
        check("status INVALID with errors", out.get("status") == "INVALID" and bool(out.get("errors")))
        check("no script ran for invalid request", not exists(s3, bucket, f"responses/provider/{bad}.json"))

    # 3. WebSocket push
    if a.ws:
        wsid = f"smoke-ws-{stamp}"
        try:
            msg = asyncio.run(ws_roundtrip(a.ws, s3, bucket, wsid, a.timeout))
            check("WebSocket push received", bool(msg) and msg.get("request_id") == wsid)
        except Exception as exc:  # noqa: BLE001
            check("WebSocket push received", False, str(exc))

    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
