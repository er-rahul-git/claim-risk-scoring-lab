import importlib.util
import json
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

LAMBDAS = Path(__file__).resolve().parents[2] / "lambdas"


def load(name):
    spec = importlib.util.spec_from_file_location(f"{name}_handler", LAMBDAS / name / "handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def s3_event(bucket, key):
    return {"Records": [{"s3": {"bucket": {"name": bucket}, "object": {"key": key}}}]}


class FakeResp:
    def __init__(self, status):
        self.status = status
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False


def test_trigger_posts_path_not_payload(monkeypatch):
    trigger = load("trigger")
    seen = {}

    def fake_urlopen(req, timeout):
        seen.update(json.loads(req.data))
        return FakeResp(202)

    monkeypatch.setattr(trigger.urllib.request, "urlopen", fake_urlopen)
    out = trigger.handler(s3_event("crs-data", "requests/demo%2D001.json"))
    assert out == {"sent": ["demo-001"]}
    assert seen == {"request_id": "demo-001", "s3_path": "s3://crs-data/requests/demo-001.json"}


def test_trigger_raises_so_lambda_retries(monkeypatch):
    trigger = load("trigger")
    monkeypatch.setattr(trigger.urllib.request, "urlopen", lambda req, timeout: FakeResp(500))
    with pytest.raises(RuntimeError):
        trigger.handler(s3_event("crs-data", "requests/demo-001.json"))


@mock_aws
def test_subscribe_then_notify(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-south-1")
    s3 = boto3.client("s3", region_name="ap-south-1")
    s3.create_bucket(Bucket="crs-data", CreateBucketConfiguration={"LocationConstraint": "ap-south-1"})
    s3.put_object(Bucket="crs-data", Key="output/demo-001.json", Body=b'{"status":"COMPLETED"}')
    boto3.client("dynamodb", region_name="ap-south-1").create_table(
        TableName="crs-ws-connections", BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "request_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "request_id", "AttributeType": "S"}])

    ws = load("ws")
    sub = {"requestContext": {"routeKey": "subscribe", "connectionId": "conn-1"},
           "body": json.dumps({"action": "subscribe", "request_id": "demo-001"})}
    assert ws.handler(sub)["statusCode"] == 200

    notifier = load("notifier")
    posted = {}

    class FakeWS:
        class exceptions:
            class GoneException(Exception):
                pass
        def post_to_connection(self, ConnectionId, Data):
            posted[ConnectionId] = json.loads(Data)

    out = notifier.handler(s3_event("crs-data", "output/demo-001.json"), ws_client=FakeWS())
    assert out == {"pushed": ["demo-001"]}
    assert posted["conn-1"]["status"] == "COMPLETED"


@mock_aws
def test_presign_returns_scoped_url(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-south-1")
    monkeypatch.setenv("BUCKET", "crs-data")
    presign = load("presign")
    out = presign.handler({"queryStringParameters": {"request_id": "ui-003"}})
    body = json.loads(out["body"])
    assert out["statusCode"] == 200
    assert "requests/ui-003.json" in body["upload_url"]
    assert body["headers"]["x-amz-server-side-encryption"] == "aws:kms"
    assert presign.handler({"queryStringParameters": {"request_id": "../etc"}})["statusCode"] == 400
