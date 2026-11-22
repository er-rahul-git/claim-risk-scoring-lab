import json

from fastapi.testclient import TestClient


def make_client(tmp_path, monkeypatch, calls):
    monkeypatch.setenv("LOCAL_BUCKET_DIR", str(tmp_path / "bucket"))
    import importlib

    import local_stack.app as ls
    ls = importlib.reload(ls)
    monkeypatch.setattr(ls.TRIGGER, "handler", lambda event: calls.append(event) or {"sent": ["x"]})
    return ls, TestClient(ls.app)


def test_presign_put_fires_s3_event(tmp_path, monkeypatch):
    calls = []
    ls, client = make_client(tmp_path, monkeypatch, calls)
    with client:
        pre = client.get("/presign", params={"request_id": "ui-001"}).json()
        assert pre["upload_url"].endswith("/s3/requests/ui-001.json")
        r = client.put("/s3/requests/ui-001.json", content=b'{"a":1}', headers=pre["headers"])
        assert r.status_code == 200
        assert (tmp_path / "bucket/requests/ui-001.json").read_text() == '{"a":1}'
    assert calls and calls[0]["Records"][0]["s3"]["object"]["key"] == "requests/ui-001.json"


def test_upload_outside_requests_is_refused(tmp_path, monkeypatch):
    _, client = make_client(tmp_path, monkeypatch, [])
    with client:
        assert client.put("/s3/output/ui-001.json", content=b"{}").status_code == 403
        assert client.get("/presign", params={"request_id": "../x"}).status_code == 400


def test_websocket_receives_result_on_output_event(tmp_path, monkeypatch):
    ls, client = make_client(tmp_path, monkeypatch, [])
    with client, client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"action": "subscribe", "request_id": "ui-002"}))
        assert json.loads(ws.receive_text())["type"] == "subscribed"
        out = tmp_path / "bucket/output/ui-002.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"request_id": "ui-002", "status": "COMPLETED"}))
        msg = json.loads(ws.receive_text())   # pushed by the output watcher (S3 event stand-in)
        assert msg == {"request_id": "ui-002", "status": "COMPLETED"}
