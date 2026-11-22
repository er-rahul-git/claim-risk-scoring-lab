"""WebSocket routes: $connect, $disconnect, subscribe.

The UI connects, then sends {"action": "subscribe", "request_id": "..."}; we store
request_id -> connection_id (expires after 1 hour) so the notifier knows where to push.
"""
import json
import os
import time

import boto3

TABLE = os.environ.get("CONNECTIONS_TABLE", "crs-ws-connections")
ddb = boto3.resource("dynamodb")


def handler(event, _context=None):
    ctx = event["requestContext"]
    route, conn = ctx["routeKey"], ctx["connectionId"]
    if route == "subscribe":
        body = json.loads(event.get("body") or "{}")
        request_id = body.get("request_id", "")
        if not request_id:
            return {"statusCode": 400, "body": "request_id required"}
        ddb.Table(TABLE).put_item(Item={"request_id": request_id, "connection_id": conn,
                                        "expires_at": int(time.time()) + 3600})
        print(json.dumps({"step": "subscribe", "request_id": request_id}))
    return {"statusCode": 200, "body": "ok"}
