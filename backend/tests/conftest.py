from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

import app.models  # noqa: F401
from app.core.config import Settings
from app.db.base import Base
from app.db.session import make_engine
from app.main import create_app
from app.services.coach.llm import FakeLLMClient

FIXTURES = Path(__file__).resolve().parents[2] / "contracts" / "fixtures"


def fixture_payload(name: str) -> dict:
    return json.loads((FIXTURES / f"set_summary_{name}.json").read_text(encoding="utf-8"))


@pytest.fixture()
def engine(tmp_path):
    """Fresh SQLite DB per test (FKs enabled). Postgres-only DDL is not exercised here."""
    eng = make_engine(f"sqlite:///{tmp_path / 'test.db'}")
    Base.metadata.create_all(eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def db(engine):
    with Session(engine) as s:
        yield s


def make_settings(**kw) -> Settings:
    base = dict(secret_key="s" * 40, database_url="sqlite://", llm_backend="fake",
                ai_cooldown_seconds=0)
    base.update(kw)
    return Settings(_env_file=None, **base)


@pytest.fixture()
def fake_llm():
    return FakeLLMClient()


@pytest.fixture()
def app_factory(engine):
    def build(llm=None, text_parser=None, **settings_kw):
        return create_app(make_settings(**settings_kw),
                          session_factory=sessionmaker(bind=engine, autoflush=False, expire_on_commit=False),
                          llm=llm or FakeLLMClient(), text_parser=text_parser)
    return build


@pytest.fixture()
def client(app_factory, fake_llm):
    with TestClient(app_factory(llm=fake_llm)) as c:
        yield c


def signup(client: TestClient, email: str = "athlete@test.dev", password: str = "secret123") -> dict:
    r = client.post("/auth/signup", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.fixture()
def user_headers(client):
    return auth_headers(signup(client))
