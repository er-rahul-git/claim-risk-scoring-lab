"""Layered config: base_config.yaml <- environments/<APP_ENV>.yaml <- APP__* env vars."""
from __future__ import annotations

import copy
import os
from functools import lru_cache
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = Path(os.getenv("APP_CONFIG_DIR", ROOT / "configs"))
ENV_PREFIX = "APP__"


def deep_merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def _env_overrides() -> dict:
    result: dict = {}
    for key, raw in os.environ.items():
        if not key.startswith(ENV_PREFIX):
            continue
        path = key[len(ENV_PREFIX):].lower().split("__")
        node = result
        for part in path[:-1]:
            node = node.setdefault(part, {})
        node[path[-1]] = yaml.safe_load(raw)  # "false" -> False, "30" -> 30
    return result


def _validate(cfg: dict) -> None:
    arize = cfg["observability"]["arize"]
    names = {s["name"] for s in cfg.get("arize_spaces", [])}
    if arize.get("enabled") and arize.get("space") not in names:
        raise ValueError(f"observability.arize.space '{arize.get('space')}' not in arize_spaces")
    if cfg["storage"]["backend"] == "s3" and not cfg["storage"]["bucket"]:
        raise ValueError("storage.bucket must be set (APP__storage__bucket) when backend is s3")
    weights = cfg["composite"]["weights"]
    if set(weights) != set(cfg["scripts"]["registry"]):
        raise ValueError("composite.weights must have one weight per script in scripts.registry")


def load_config(env: str | None = None) -> dict:
    env = env or os.getenv("APP_ENV", "local")
    base = yaml.safe_load((CONFIG_DIR / "base_config.yaml").read_text())
    env_file = CONFIG_DIR / "environments" / f"{env}.yaml"
    if not env_file.exists():
        raise FileNotFoundError(f"No environment config: {env_file}")
    cfg = deep_merge(base, yaml.safe_load(env_file.read_text()) or {})
    cfg = deep_merge(cfg, _env_overrides())
    _validate(cfg)
    return cfg


@lru_cache(maxsize=1)
def get_config() -> dict:
    return load_config()
