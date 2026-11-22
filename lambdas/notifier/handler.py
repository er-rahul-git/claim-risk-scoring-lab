"""Notifier Lambda (agreed step 7): S3 event on output/*.json -> push result to the UI's WebSocket.

Looks up which WebSocket connection subscribed to this request_id (DynamoDB) and posts the result.
"""
import json
import os
import urllib.parse

import boto3

TABLE = os.environ.get("CONNECTIONS_TABLE", "crs-ws-connections")
WS_ENDPOINT = os.environ.get("WS_ENDPOINT", "")  # https://{api-id}.execute-api.{region}.amazonaws.com/{stage}

s3 = boto3.client("s3")
ddb = boto3.resource("dynamodb")


def _log(**fields):
    print(json.dumps({"step": "notify", **fields}))


def handler(event, _context=None, ws_client=None):
    ws = ws_client or boto3.client("apigatewaymanagementapi", endpoint_url=WS_ENDPOINT)
    table = ddb.Table(TABLE)
    pushed = []
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
        request_id = key.rsplit("/", 1)[-1].removesuffix(".json")
        item = table.get_item(Key={"request_id": request_id}).get("Item")
        if not item:
            _log(request_id=request_id, status="no_subscriber")  # UI not connected: result stays in S3
            continue
        result = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        try:
            ws.post_to_connection(ConnectionId=item["connection_id"], Data=result)
            pushed.append(request_id)
            _log(request_id=request_id, status="ok")
        except ws.exceptions.GoneException:
            _log(request_id=request_id, status="connection_gone")
        table.delete_item(Key={"request_id": request_id})
    return {"pushed": pushed}
