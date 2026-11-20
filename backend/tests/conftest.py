from __future__ import annotations

import pytest
from sqlalchemy.orm import Session

import app.models  # noqa: F401
from app.db.base import Base
from app.db.session import make_engine


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
