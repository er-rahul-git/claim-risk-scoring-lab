"""Trigger Lambda (agreed steps 2-3): S3 event on requests/*.json -> POST {request_id, s3_path} to the API.

Passes the S3 PATH, never the payload (no size limits, light call). Raising an exception makes
Lambda retry (2x, set in Terraform) and then send the event to the dead-letter queue.
"""
import json
import os
import urllib.parse
import urllib.request

API_URL = os.environ.get("API_URL", "http://localhost:8080/audit")
TIMEOUT = float(os.environ.get("API_TIMEOUT_SECONDS", "10"))


def _log(**fields):
    print(json.dumps({"step": "trigger", **fields}))


def handler(event, _context=None):
    sent = []
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])  # S3 URL-encodes keys in events
        request_id = key.rsplit("/", 1)[-1].removesuffix(".json")
        body = json.dumps({"request_id": request_id, "s3_path": f"s3://{bucket}/{key}"}).encode()
        req = urllib.request.Request(API_URL, data=body, method="POST",
                                     headers={"content-type": "application/json", "x-request-id": request_id})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            status = resp.status
        if status not in (200, 202):
            _log(request_id=request_id, status="error", http_status=status)
            raise RuntimeError(f"API returned {status} for {request_id}")
        _log(request_id=request_id, status="ok", http_status=status)
        sent.append(request_id)
    return {"sent": sent}
