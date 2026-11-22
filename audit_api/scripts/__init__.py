"""Provider, CMS and Payer scripts (run in parallel) and the Composite score script.

Each script is a pure function `run(claim) -> dict` so it is easy to test. `execute()` wraps it:
runs the script and writes its own response file to responses/<script>/<request_id>.json
(agreed step 5: "each writes its own response file to S3").

The scoring logic here is SYNTHETIC - it only exists so the pipeline has something real to run.
Replace each run() with the team's actual script.
"""
from __future__ import annotations

import importlib
import time
from datetime import UTC, datetime


def execute(name: str, request: dict, store, prefixes: dict) -> dict:
    module = importlib.import_module(f"audit_api.scripts.{name}")
    started = time.perf_counter()
    result = module.run(request["claim"])
    response = {
        "request_id": request["request_id"],
        "script": name,
        "result": result,
        "duration_ms": round((time.perf_counter() - started) * 1000, 2),
        "written_at": datetime.now(UTC).isoformat(),
    }
    store.write_json(f"{prefixes['responses']}{name}/{request['request_id']}.json", response)
    return response
