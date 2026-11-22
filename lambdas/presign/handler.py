"""Presign Lambda (practice UI only): returns a short-lived URL so a browser can PUT the request
JSON to requests/{request_id}.json without ever holding AWS credentials (agreed step 1)."""
import json
import os
import uuid

import boto3

BUCKET = os.environ.get("BUCKET", "")
s3 = boto3.client("s3")


def handler(event, _context=None):
    request_id = (event.get("queryStringParameters") or {}).get("request_id") or uuid.uuid4().hex[:16]
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": f"requests/{request_id}.json",
                "ContentType": "application/json", "ServerSideEncryption": "aws:kms"},
        ExpiresIn=300,
    )
    return {"statusCode": 200, "headers": {"content-type": "application/json"},
            "body": json.dumps({"request_id": request_id, "upload_url": url})}
