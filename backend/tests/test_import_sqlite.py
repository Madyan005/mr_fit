"""v1 SQLite -> v2 import (target is SQLite here; Postgres sequence reset is PG-only)."""
from __future__ import annotations

import sqlite3

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import Log, User
from scripts.import_sqlite import import_v1

# DDL copied from the real v1 files (inspected 2026-11-20): root mrfit.db has
# session_id appended by a later ALTER; "New folder" mrfit.db has no session_id.
V1_USERS = "CREATE TABLE users (id INTEGER NOT NULL, email VARCHAR, hashed_password VARCHAR, PRIMARY KEY (id))"
V1_LOGS = """CREATE TABLE logs (id INTEGER NOT NULL, user_id INTEGER, type VARCHAR, name VARCHAR,
  sets INTEGER, reps INTEGER, weight FLOAT, calories INTEGER, volume FLOAT, raw_text VARCHAR,
  created_at DATETIME{extra}, PRIMARY KEY (id), FOREIGN KEY(user_id) REFERENCES users (id))"""


def make_v1(path, with_session_id=True):
    con = sqlite3.connect(path)
    con.execute(V1_USERS)
    con.execute(V1_LOGS.format(extra=", session_id VARCHAR" if with_session_id else ""))
    con.executemany("INSERT INTO users VALUES (?,?,?)", [
        (1, "A@Test.dev ", "hash-a"), (2, "b@test.dev", "hash-b"), (3, None, "hash-c")])
    cols = "id,user_id,type,name,sets,reps,weight,calories,volume,raw_text,created_at"
    rows = [
        (1, 1, "EXERCISE", "Squat", 1, 5, 100.0, None, 500.0, "squat", "2026-01-02 08:00:00.123456"),
        (2, 1, "NUTRITION", "Salad", None, None, None, 300, None, "salad", "2026-01-02 13:00:00"),
        (3, 2, "EXERCISE", "Bench Press", 1, 8, 60.0, None, 480.0, "bench", "2026-01-03 09:00:00"),
        (4, 3, "EXERCISE", "Orphan", 1, 1, 1.0, None, 1.0, "x", "2026-01-03 09:00:00"),
        (5, 2, "CARDIO", "Run", None, None, None, None, None, "run", "2026-01-03 10:00:00"),
    ]
    con.executemany(f"INSERT INTO logs ({cols}) VALUES ({','.join('?' * 11)})", rows)
    con.commit()
    con.close()
    return str(path)


@pytest.mark.parametrize("with_session_id", [True, False])
def test_import_counts_and_normalisation(engine, tmp_path, with_session_id):
    src = make_v1(tmp_path / "v1.db", with_session_id)
    rep = import_v1(engine, src)
    assert rep.users_imported == 2 and len(rep.users_skipped) == 1  # user 3 has no email
    assert rep.logs_imported == 3 and rep.logs_skipped == 2  # orphan + invalid type
    with Session(engine) as s:
        assert s.get(User, 1).email == "a@test.dev"  # trimmed + lower-cased
        assert s.get(User, 1).hashed_password == "hash-a"  # copied verbatim
        assert s.get(Log, 1).created_at.isoformat().startswith("2026-01-02T08:00:00.123456")


def test_import_is_idempotent(engine, tmp_path):
    src = make_v1(tmp_path / "v1.db")
    import_v1(engine, src)
    rep = import_v1(engine, src)
    assert rep.users_imported == 0 and rep.logs_imported == 0
    with Session(engine) as s:
        assert s.scalar(select(func.count()).select_from(Log)) == 3


def test_conflicting_user_is_skipped_not_overwritten(engine, tmp_path):
    with Session(engine) as s:
        s.add(User(id=50, email="b@test.dev", hashed_password="existing"))
        s.commit()
    rep = import_v1(engine, make_v1(tmp_path / "v1.db"))
    assert any("id=2" in r for r in rep.users_skipped)
    with Session(engine) as s:
        assert s.get(User, 50).hashed_password == "existing"
        assert s.get(User, 2) is None


def test_dry_run_writes_nothing(engine, tmp_path):
    rep = import_v1(engine, make_v1(tmp_path / "v1.db"), dry_run=True)
    assert rep.users_imported == 2
    with Session(engine) as s:
        assert s.scalar(select(func.count()).select_from(User)) == 0
