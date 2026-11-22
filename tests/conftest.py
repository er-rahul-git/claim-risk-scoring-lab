import json
import os
from pathlib import Path

import pytest

os.environ.setdefault("APP_ENV", "local")
SAMPLES = Path(__file__).resolve().parents[1] / "samples"


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("APP__storage__local_root", str(tmp_path / "bucket"))
    from audit_api.config import get_config, load_config
    get_config.cache_clear()
    return load_config()


@pytest.fixture
def store(cfg):
    from audit_api.storage import build_store
    return build_store(cfg)


@pytest.fixture
def valid_request():
    return json.loads((SAMPLES / "valid_request.json").read_text())


@pytest.fixture
def invalid_request():
    return json.loads((SAMPLES / "invalid_request.json").read_text())
