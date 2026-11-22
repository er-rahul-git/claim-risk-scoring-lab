"""Risk Scoring API (runs on EC2 in Docker).

POST /audit  {request_id, s3_path}  -> 202 immediately, processing continues in the background
GET  /health                        -> liveness for the ALB and Docker HEALTHCHECK
"""
from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .config import get_config
from .monitoring import ArizeLogger, log_event
from .orchestrator import output_key, process
from .storage import build_store, parse_s3_path

STATE: dict = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    cfg = get_config()
    STATE.update(cfg=cfg, store=build_store(cfg), arize=ArizeLogger(cfg))
    log_event("startup", "-", env=cfg["environment"], git_sha=os.getenv("GIT_SHA", "dev"))
    yield


app = FastAPI(title="Risk Scoring API", lifespan=lifespan)


class AuditCall(BaseModel):
    request_id: str = Field(pattern=r"^[A-Za-z0-9_-]{3,64}$")
    s3_path: str


@app.get("/health")
def health():
    return {"status": "ok", "env": STATE["cfg"]["environment"], "git_sha": os.getenv("GIT_SHA", "dev")}


@app.post("/audit", status_code=202)
async def audit(call: AuditCall, background: BackgroundTasks):
    cfg, store = STATE["cfg"], STATE["store"]
    try:
        bucket, key = parse_s3_path(call.s3_path)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    if bucket != store.bucket:
        raise HTTPException(400, f"unexpected bucket {bucket}")
    if not key.startswith(cfg["storage"]["prefixes"]["requests"]):
        raise HTTPException(400, "path must be under requests/")

    # Idempotency: S3 delivers events at least once. A finished request is never reprocessed.
    if store.exists(output_key(cfg, call.request_id)):
        log_event("duplicate", call.request_id)
        return JSONResponse({"request_id": call.request_id, "status": "already_processed"}, status_code=200)

    log_event("accepted", call.request_id, key=key)
    background.add_task(process, call.request_id, key, store, cfg, STATE["arize"])
    return {"request_id": call.request_id, "status": "accepted"}
