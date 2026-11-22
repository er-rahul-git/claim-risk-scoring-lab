"""Storage abstraction: the same code talks to S3 in AWS and to a folder on a laptop.

Keys look like S3 keys ("requests/abc.json"). Paths look like "s3://bucket/requests/abc.json".
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Protocol


def parse_s3_path(path: str) -> tuple[str, str]:
    if not path.startswith("s3://"):
        raise ValueError(f"not an s3 path: {path}")
    bucket, _, key = path[5:].partition("/")
    if not bucket or not key:
        raise ValueError(f"s3 path needs bucket and key: {path}")
    return bucket, key


class Store(Protocol):
    bucket: str

    def read_json(self, key: str) -> dict: ...
    def write_json(self, key: str, obj: dict) -> None: ...
    def exists(self, key: str) -> bool: ...


class S3Store:
    def __init__(self, bucket: str, client=None):
        import boto3

        self.bucket = bucket
        self.s3 = client or boto3.client("s3")

    def read_json(self, key: str) -> dict:
        body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        return json.loads(body)

    def write_json(self, key: str, obj: dict) -> None:
        # Bucket default encryption (SSE-KMS) applies; the bucket policy denies unencrypted puts.
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=json.dumps(obj).encode(),
                           ContentType="application/json", ServerSideEncryption="aws:kms")

    def exists(self, key: str) -> bool:
        resp = self.s3.list_objects_v2(Bucket=self.bucket, Prefix=key, MaxKeys=1)
        return any(o["Key"] == key for o in resp.get("Contents", []))


class LocalStore:
    """A folder that behaves like a bucket. Used for local runs and unit tests."""

    def __init__(self, root: str | Path, bucket: str = "local-bucket"):
        self.root = Path(root)
        self.bucket = bucket

    def _p(self, key: str) -> Path:
        return self.root / key

    def read_json(self, key: str) -> dict:
        return json.loads(self._p(key).read_text())

    def write_json(self, key: str, obj: dict) -> None:
        p = self._p(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj, indent=2))

    def exists(self, key: str) -> bool:
        return self._p(key).exists()


def build_store(cfg: dict) -> Store:
    s = cfg["storage"]
    if s["backend"] == "local":
        return LocalStore(s["local_root"], s.get("bucket") or "local-bucket")
    return S3Store(s["bucket"])
