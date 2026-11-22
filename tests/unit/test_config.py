import pytest

from audit_api.config import deep_merge, load_config


def test_env_file_wins_and_siblings_kept(monkeypatch):
    local = load_config("local")
    assert local["storage"]["backend"] == "local"                 # from environments/local.yaml
    assert local["storage"]["prefixes"]["output"] == "output/"    # inherited from base
    monkeypatch.setenv("APP__storage__bucket", "b")
    assert load_config("prod")["scripts"]["timeout_seconds"] == 60   # prod overrides base 30
    assert load_config("prod")["scripts"]["registry"] == ["provider", "cms", "payer"]


def test_s3_backend_requires_bucket(monkeypatch):
    monkeypatch.delenv("APP__storage__bucket", raising=False)
    with pytest.raises(ValueError, match="storage.bucket"):
        load_config("nonprod")


def test_env_var_override(monkeypatch):
    monkeypatch.setenv("APP__storage__bucket", "crs-data-nonprod-123")
    monkeypatch.setenv("APP__scripts__timeout_seconds", "5")
    cfg = load_config("nonprod")
    assert cfg["storage"]["bucket"] == "crs-data-nonprod-123"
    assert cfg["scripts"]["timeout_seconds"] == 5


def test_arize_space_must_exist(monkeypatch):
    monkeypatch.setenv("APP__observability__arize__enabled", "true")
    monkeypatch.setenv("APP__observability__arize__space", "Nope")
    with pytest.raises(ValueError, match="arize"):
        load_config("local")


def test_deep_merge_does_not_mutate():
    base = {"a": {"b": 1}}
    assert deep_merge(base, {"a": {"c": 2}}) == {"a": {"b": 1, "c": 2}}
    assert base == {"a": {"b": 1}}
