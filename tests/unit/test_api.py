from fastapi.testclient import TestClient


def make_client():
    from audit_api.app import app
    return TestClient(app)


def test_accepts_with_202_then_result_lands(cfg, store, valid_request):
    store.write_json("requests/demo-001.json", valid_request)
    with make_client() as client:
        assert client.get("/health").json()["status"] == "ok"
        r = client.post("/audit", json={"request_id": "demo-001", "s3_path": "s3://local-bucket/requests/demo-001.json"})
        assert r.status_code == 202
        # TestClient runs background tasks before returning, so the result is already written
        assert store.read_json("output/demo-001.json")["status"] == "COMPLETED"
        again = client.post("/audit", json={"request_id": "demo-001", "s3_path": "s3://local-bucket/requests/demo-001.json"})
        assert again.status_code == 200 and again.json()["status"] == "already_processed"


def test_rejects_paths_outside_requests(cfg):
    with make_client() as client:
        r = client.post("/audit", json={"request_id": "x01", "s3_path": "s3://local-bucket/output/x01.json"})
        assert r.status_code == 400
        r = client.post("/audit", json={"request_id": "x01", "s3_path": "s3://other-bucket/requests/x01.json"})
        assert r.status_code == 400
