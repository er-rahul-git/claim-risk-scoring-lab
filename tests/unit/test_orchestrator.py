import asyncio

from audit_api import scripts
from audit_api.orchestrator import process, validation_errors


def run(coro):
    return asyncio.run(coro)


def test_valid_request_end_to_end(cfg, store, valid_request):
    store.write_json("requests/demo-001.json", valid_request)
    out = run(process("demo-001", "requests/demo-001.json", store, cfg))
    assert out["status"] == "COMPLETED"
    assert out["risk_label"] in {"HIGH", "MEDIUM", "LOW"}
    for name in ("provider", "cms", "payer"):          # step 5: each script wrote its own file
        assert store.exists(f"responses/{name}/demo-001.json")
    assert store.read_json("output/demo-001.json")["composite_score"] == out["composite_score"]


def test_invalid_request_writes_error_and_runs_no_scripts(cfg, store, invalid_request):
    store.write_json("requests/demo-bad-001.json", invalid_request)
    out = run(process("demo-bad-001", "requests/demo-bad-001.json", store, cfg))
    assert out["status"] == "INVALID" and out["errors"]
    assert not store.exists("responses/provider/demo-bad-001.json")   # step 4: no component calls


def test_script_failure_becomes_error_result(cfg, store, valid_request, monkeypatch):
    store.write_json("requests/demo-001.json", valid_request)

    def boom(name, *a, **k):
        if name == "payer":
            raise RuntimeError("payer source down")
        return original(name, *a, **k)

    original = scripts.execute
    monkeypatch.setattr("audit_api.orchestrator.execute", boom)
    out = run(process("demo-001", "requests/demo-001.json", store, cfg))
    assert out["status"] == "ERROR" and "payer" in out["errors"][0]
    assert store.exists("errors/demo-001.json")


def test_schema_messages_are_readable(invalid_request):
    errors = validation_errors(invalid_request)
    assert any(e.startswith("claim/provider_npi") for e in errors)
