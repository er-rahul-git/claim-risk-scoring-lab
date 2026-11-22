"""Structured JSON logging (request_id on every line) + optional Arize logging.

Arize is off unless observability.arize.enabled is true. Logging to Arize must NEVER fail an audit.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time

_logger = logging.getLogger("audit_api")
if not _logger.handlers:
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(h)
    _logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))
    _logger.propagate = False


def log_event(step: str, request_id: str, status: str = "ok", **fields) -> None:
    _logger.info(json.dumps({"ts": round(time.time(), 3), "step": step, "request_id": request_id,
                             "status": status, **fields}, default=str))


class ArizeLogger:
    def __init__(self, cfg: dict):
        a = cfg["observability"]["arize"]
        self.enabled = bool(a.get("enabled"))
        self.cfg = cfg
        self._client = None
        if self.enabled:
            self._init_client(a["space"])

    def _init_client(self, space_name: str) -> None:
        try:
            import boto3
            from arize import ArizeClient  # pip install arize (SDK v8)

            secret_name = next(s["secret"] for s in self.cfg["arize_spaces"] if s["name"] == space_name)
            secret = json.loads(boto3.client("secretsmanager").get_secret_value(SecretId=secret_name)["SecretString"])
            self._space_id = secret["space_id"]
            self._client = ArizeClient(api_key=secret["api_key"])
        except Exception as exc:  # noqa: BLE001 - monitoring must not break startup
            log_event("arize_init", "-", status="warning", error=str(exc))
            self.enabled = False

    def log_prediction(self, request_id: str, result: dict, features: dict) -> None:
        if not self.enabled or self._client is None:
            return
        try:
            from arize.ml.types import Environments, ModelTypes

            # Check argument names against the current Arize SDK v8 docs before relying on this.
            self._client.ml.log_stream(
                space_id=self._space_id,
                model_name=self.cfg["model"]["arize_model_name"],
                model_type=ModelTypes.SCORE_CATEGORICAL,
                environment=Environments.PRODUCTION,
                model_version=os.getenv("GIT_SHA", "dev"),
                prediction_id=request_id,
                prediction_label=(result["risk_label"], result["composite_score"]),
                features=features,
                tags={"env": self.cfg["environment"]},
            )
        except Exception as exc:  # noqa: BLE001
            log_event("arize_log", request_id, status="warning", error=str(exc))
