"""Local stand-in for the AWS managed pieces, so the UI can run the full flow on a laptop.

Each route below replaces exactly one AWS component and keeps its contract:

  AWS component                        local stand-in (this file)
  -----------------------------------  -------------------------------------------------------
  presign Lambda (Function URL)        GET  /presign?request_id=...   -> {upload_url, headers}
  S3 PUT to a presigned URL            PUT  /s3/{key}                 -> writes to .localbucket/
  S3 event on requests/*.json          after the PUT: calls the REAL lambdas/trigger/handler.py
  S3 event on output/*.json            a watcher notices new output files
  notifier Lambda + DynamoDB map       in-memory {request_id: websocket}, push on output event
  API Gateway WebSocket ($connect,     WS   /ws  {"action": "subscribe", "request_id": ...}
    subscribe route, ws Lambda)
  UI hosting (S3/CloudFront)           GET  /  serves ui/

The Risk Scoring API itself is NOT emulated: it runs as the real app on :8080 (`make run`).
Run both with `make dev`.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).resolve().parents[1]
BUCKET_DIR = Path(os.getenv("LOCAL_BUCKET_DIR", ROOT / ".localbucket"))
BUCKET_NAME = "local-bucket"
PUBLIC_URL = os.getenv("LOCAL_STACK_URL", "http://localhost:8000")
API_URL = os.getenv("API_URL", "http://localhost:8080/audit")
KEY_RE = re.compile(r"^requests/[A-Za-z0-9_-]{3,64}\.json$")

SUBSCRIPTIONS: dict[str, WebSocket] = {}   # stands in for the DynamoDB connections table


def _log(**fields):
    print(json.dumps({"component": "local_stack", **fields}), flush=True)


def _load_trigger():
    spec = importlib.util.spec_from_file_location("trigger_handler", ROOT / "lambdas/trigger/handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.API_URL = API_URL
    return mod


TRIGGER = _load_trigger()


def s3_event(key: str) -> dict:
    """The event shape S3 sends to Lambda (only the fields the handlers read)."""
    return {"Records": [{"eventSource": "aws:s3", "eventName": "ObjectCreated:Put",
                         "s3": {"bucket": {"name": BUCKET_NAME}, "object": {"key": key}}}]}


async def fire_trigger(key: str) -> None:
    """S3 -> trigger Lambda (async invoke, 2 retries like the real event invoke config)."""
    for attempt in range(3):
        try:
            result = await asyncio.to_thread(TRIGGER.handler, s3_event(key))
            _log(step="s3_event_requests", key=key, result=result)
            return
        except Exception as exc:  # noqa: BLE001
            _log(step="s3_event_requests", key=key, status="retry", attempt=attempt + 1, error=str(exc))
            await asyncio.sleep(1)
    dlq = BUCKET_DIR / "_dlq"
    dlq.mkdir(parents=True, exist_ok=True)
    (dlq / Path(key).name).write_text(json.dumps(s3_event(key)))
    _log(step="dlq", key=key, status="sent_to_dlq")


async def notify(key: str) -> None:
    """S3 event on output/ -> notifier: look up the subscriber and push the result."""
    request_id = Path(key).stem
    ws = SUBSCRIPTIONS.pop(request_id, None)
    if ws is None:
        _log(step="notify", request_id=request_id, status="no_subscriber")
        return
    try:
        await ws.send_text((BUCKET_DIR / key).read_text())
        _log(step="notify", request_id=request_id, status="pushed")
    except Exception as exc:  # noqa: BLE001  (connection gone)
        _log(step="notify", request_id=request_id, status="connection_gone", error=str(exc))


async def watch_output(poll_seconds: float = 0.3) -> None:
    """Emulates the S3 ObjectCreated event on output/*.json."""
    out = BUCKET_DIR / "output"
    seen = {p.name for p in out.glob("*.json")} if out.exists() else set()
    while True:
        if out.exists():
            for p in sorted(out.glob("*.json")):
                if p.name not in seen:
                    seen.add(p.name)
                    await asyncio.sleep(0.05)   # let the writer finish
                    await notify(f"output/{p.name}")
        await asyncio.sleep(poll_seconds)


@asynccontextmanager
async def lifespan(app: FastAPI):
    BUCKET_DIR.mkdir(parents=True, exist_ok=True)
    task = asyncio.create_task(watch_output())
    _log(step="startup", bucket_dir=str(BUCKET_DIR), api_url=API_URL)
    yield
    task.cancel()


app = FastAPI(title="Local AWS stand-in", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "PUT"], allow_headers=["*"])


@app.get("/presign")
def presign(request_id: str):
    """Same response shape as lambdas/presign/handler.py."""
    key = f"requests/{request_id}.json"
    if not KEY_RE.match(key):
        raise HTTPException(400, "request_id must be 3-64 letters, digits, - or _")
    return {"request_id": request_id, "upload_url": f"{PUBLIC_URL}/s3/{key}",
            "headers": {"content-type": "application/json"}}


@app.put("/s3/{key:path}")
async def put_object(key: str, request: Request):
    if not KEY_RE.match(key):
        raise HTTPException(403, "the presigned URL only allows requests/<id>.json")  # like a scoped presign
    body = await request.body()
    path = BUCKET_DIR / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    _log(step="s3_put", key=key, bytes=len(body))
    asyncio.create_task(fire_trigger(key))   # S3 event is asynchronous: the PUT returns at once
    return JSONResponse(status_code=200, content={})


@app.websocket("/ws")
async def websocket(ws: WebSocket):
    await ws.accept()                                       # $connect
    try:
        while True:
            msg = json.loads(await ws.receive_text())
            if msg.get("action") == "subscribe" and msg.get("request_id"):   # subscribe route
                SUBSCRIPTIONS[msg["request_id"]] = ws
                _log(step="subscribe", request_id=msg["request_id"])
                await ws.send_text(json.dumps({"type": "subscribed", "request_id": msg["request_id"]}))
    except WebSocketDisconnect:                             # $disconnect
        for rid in [r for r, w in SUBSCRIPTIONS.items() if w is ws]:
            SUBSCRIPTIONS.pop(rid, None)


@app.get("/config.js")
def ui_config():
    """Local UI config. In AWS the same file is written with the real URLs (terraform outputs)."""
    ws_url = PUBLIC_URL.replace("http", "ws", 1) + "/ws"
    cfg = {"PRESIGN_URL": PUBLIC_URL + "/presign", "WS_URL": ws_url, "ENV": "local"}
    return Response(f"window.APP_CONFIG = {json.dumps(cfg)};", media_type="application/javascript")


@app.get("/")
def index():
    return FileResponse(ROOT / "ui" / "index.html")


app.mount("/ui", StaticFiles(directory=ROOT / "ui"), name="ui")
