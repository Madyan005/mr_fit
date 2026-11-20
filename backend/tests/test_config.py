import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.core.config import Settings
from app.main import create_app

GOOD_SECRET = "x" * 40
DB = "sqlite://"


def make(**overrides) -> Settings:
    base = {"secret_key": GOOD_SECRET, "database_url": DB}
    base.update(overrides)
    # _env_file=None: never read the developer's real .env during tests
    return Settings(_env_file=None, **base)


def test_defaults_are_safe():
    s = make()
    assert s.ollama_model == "deepseek-r1:1.5b"
    assert s.gemini_enabled is False
    assert s.cors_origin_list == []
    assert s.ts_sensor_retention_days == 90
    assert s.ts_skeleton_retention_days == 30


def test_secret_key_required(monkeypatch):
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(ValidationError):
        Settings(_env_file=None, database_url=DB)


@pytest.mark.parametrize("bad", ["DEV_SECRET_ONLY_CHANGE_ME", "short", "changeme"])
def test_insecure_secret_rejected(bad):
    with pytest.raises(ValidationError):
        make(secret_key=bad)


@pytest.mark.parametrize("banned", ["qwen3:8b", "llama3:8b", "QWEN3:8B"])
def test_banned_models_refused(banned):
    with pytest.raises(ValidationError, match="banned"):
        make(ollama_model=banned)


def test_unlisted_model_refused():
    with pytest.raises(ValidationError, match="not allowed"):
        make(ollama_model="deepseek-r1:7b")


def test_explicit_q4_tag_allowed():
    assert make(ollama_model="deepseek-r1:1.5b-qwen-distill-q4_K_M").ollama_model.endswith("q4_K_M")


def test_cors_wildcard_refused():
    with pytest.raises(ValidationError):
        make(cors_origins="*")


def test_cors_allowlist_parsed():
    s = make(cors_origins="http://localhost:3000/, https://a.example ,")
    assert s.cors_origin_list == ["http://localhost:3000", "https://a.example"]


def test_gemini_on_requires_key():
    with pytest.raises(ValidationError):
        make(gemini_enabled=True)
    assert make(gemini_enabled=True, gemini_api_key="k").gemini_enabled


def test_health_and_cors_allowlist():
    app = create_app(make(cors_origins="http://allowed.test"))
    c = TestClient(app)
    assert c.get("/health").json()["status"] == "ok"
    ok = c.get("/health", headers={"Origin": "http://allowed.test"})
    assert ok.headers.get("access-control-allow-origin") == "http://allowed.test"
    bad = c.get("/health", headers={"Origin": "http://evil.test"})
    assert "access-control-allow-origin" not in bad.headers
