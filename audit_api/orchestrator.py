"""The agreed flow, steps 4-7, inside the API.

4. read the request from S3 and validate it against the schema; invalid -> error result to output/, stop
5. run Provider, CMS and Payer in parallel; each writes its own response file
6. wait for all three, build the composite request, run Composite
7. validate the final response and write output/{request_id}.json (S3 event then pushes it to the UI)
"""
from __future__ import annotations

import asyncio
import json
import os
from datetime import UTC, datetime
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

from .monitoring import ArizeLogger, log_event
from .scripts import composite, execute

SCHEMA_DIR = Path(__file__).parent / "schema"
REQUEST_VALIDATOR = Draft202012Validator(json.loads((SCHEMA_DIR / "request.schema.json").read_text()),
                                         format_checker=FormatChecker())
OUTPUT_VALIDATOR = Draft202012Validator(json.loads((SCHEMA_DIR / "output.schema.json").read_text()))


def _now() -> str:
    return datetime.now(UTC).isoformat()


def validation_errors(payload: dict) -> list[str]:
    return sorted(f"{'/'.join(map(str, e.path)) or '(root)'}: {e.message}"
                  for e in REQUEST_VALIDATOR.iter_errors(payload))


def output_key(cfg: dict, request_id: str) -> str:
    return f"{cfg['storage']['prefixes']['output']}{request_id}.json"


def _finish(store, cfg: dict, request_id: str, body: dict) -> dict:
    body = {"request_id": request_id, "completed_at": _now(),
            "model_version": os.getenv("GIT_SHA", "dev"), **body}
    problems = [e.message for e in OUTPUT_VALIDATOR.iter_errors(body)]
    if problems:  # never write a result the UI cannot parse
        body = {"request_id": request_id, "completed_at": _now(), "status": "ERROR",
                "errors": [f"output schema: {p}" for p in problems]}
    store.write_json(output_key(cfg, request_id), body)
    if body["status"] == "ERROR":
        store.write_json(f"{cfg['storage']['prefixes']['errors']}{request_id}.json", body)
    log_event("output_written", request_id, status=body["status"].lower())
    return body


async def process(request_id: str, key: str, store, cfg: dict, arize: ArizeLogger | None = None) -> dict:
    prefixes = cfg["storage"]["prefixes"]

    # Step 4: read + validate
    try:
        request = store.read_json(key)
    except Exception as exc:  # noqa: BLE001
        return _finish(store, cfg, request_id, {"status": "ERROR", "errors": [f"cannot read {key}: {exc}"]})
    errors = validation_errors(request)
    if not errors and request["request_id"] != request_id:
        errors = [f"request_id in file ({request['request_id']}) does not match file name ({request_id})"]
    if errors:
        log_event("validate", request_id, status="invalid", errors=errors)
        return _finish(store, cfg, request_id, {"status": "INVALID", "errors": errors})
    log_event("validate", request_id)

    # Step 5: parallel scripts, each writes its own response file
    names = cfg["scripts"]["registry"]
    try:
        results = await asyncio.wait_for(
            asyncio.gather(*(asyncio.to_thread(execute, n, request, store, prefixes) for n in names),
                           return_exceptions=True),
            timeout=cfg["scripts"]["timeout_seconds"],
        )
    except TimeoutError:
        return _finish(store, cfg, request_id, {"status": "ERROR", "errors": ["scripts timed out"]})
    failed = [f"{n}: {r}" for n, r in zip(names, results, strict=True) if isinstance(r, Exception)]
    if failed:
        log_event("scripts", request_id, status="error", errors=failed)
        return _finish(store, cfg, request_id, {"status": "ERROR", "errors": failed})
    for r in results:
        log_event(f"script.{r['script']}", request_id, duration_ms=r["duration_ms"])

    # Step 6: consolidate + Composite
    composite_request = {"request_id": request_id, **{r["script"]: r["result"] for r in results}}
    c = cfg["composite"]
    score = composite.run(composite_request, c["weights"], c["thresholds"])

    # Step 7: schema-checked final response to output/
    body = _finish(store, cfg, request_id, {"status": "COMPLETED", **score})
    if arize and body["status"] == "COMPLETED":
        features = {**composite_request["provider"], **composite_request["cms"], **composite_request["payer"]}
        features = {k: v for k, v in features.items() if isinstance(v, (int, float))}
        arize.log_prediction(request_id, body, features)
    return body
