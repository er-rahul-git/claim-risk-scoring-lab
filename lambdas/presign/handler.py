"""Presign Lambda (agreed step 1, behind a Lambda Function URL).

GET ?request_id=<id>  ->  {"request_id", "upload_url", "headers"}
The browser then PUTs the request JSON to upload_url with exactly those headers. It never holds
AWS credentials, and the URL only allows one object: requests/<id>.json, for 5 minutes.
"""
import json
import os
import re
import uuid

import boto3

BUCKET = os.environ.get("BUCKET", "")
ID_RE = re.compile(r"^[A-Za-z0-9_-]{3,64}$")
s3 = boto3.client("s3", config=boto3.session.Config(signature_version="s3v4"))


def handler(event, _context=None):
    request_id = (event.get("queryStringParameters") or {}).get("request_id") or uuid.uuid4().hex[:16]
    if not ID_RE.match(request_id):
        return {"statusCode": 400, "body": json.dumps({"error": "request_id must be 3-64 letters, digits, - or _"})}
    headers = {"content-type": "application/json", "x-amz-server-side-encryption": "aws:kms"}
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": f"requests/{request_id}.json",
                "ContentType": headers["content-type"], "ServerSideEncryption": "aws:kms"},
        ExpiresIn=300,
    )
    return {"statusCode": 200, "headers": {"content-type": "application/json"},
            "body": json.dumps({"request_id": request_id, "upload_url": url, "headers": headers})}
