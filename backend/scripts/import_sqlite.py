"""OPTIONAL one-shot import of v1 SQLite data (users + logs) into the v2 database.

Never runs automatically (docs/DECISIONS.md D-016). Run after `alembic upgrade head`:

    cd backend
    DATABASE_URL=postgresql+psycopg://... python -m scripts.import_sqlite --sqlite ../mrfit.db --dry-run
    DATABASE_URL=postgresql+psycopg://... python -m scripts.import_sqlite --sqlite ../mrfit.db

Rules
- IDs are preserved, so logs.user_id references stay valid.
- A user is skipped (with its logs) if its id OR email already exists in the target
  with different data; nothing in the target is overwritten.
- v1 timestamps are naive UTC (datetime.utcnow) and are stored as UTC timestamptz.
- Works with v1 files that predate `logs.session_id` (the "New folder" copy).
- Password hashes are copied as-is: v1 and v2 use the same bcrypt(sha256(pw)) scheme.
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

from sqlalchemy import Engine, func, select, text

from app.models import Log, User

LOG_COLUMNS = ("id", "user_id", "session_id", "type", "name", "sets", "reps", "weight",
               "calories", "volume", "raw_text", "created_at")


@dataclass
class Report:
    users_imported: int = 0
    users_skipped: list[str] = field(default_factory=list)
    logs_imported: int = 0
    logs_skipped: int = 0

    def __str__(self) -> str:
        lines = [
            f"users imported: {self.users_imported}",
            f"users skipped : {len(self.users_skipped)}",
            *[f"  - {r}" for r in self.users_skipped],
            f"logs imported : {self.logs_imported}",
            f"logs skipped  : {self.logs_skipped}",
        ]
        return "\n".join(lines)


def _parse_ts(raw: str | None) -> datetime:
    if not raw:
        return datetime.now(timezone.utc)
    dt = datetime.fromisoformat(raw)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def read_v1(path: str) -> tuple[list[dict], list[dict]]:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)  # read-only
    con.row_factory = sqlite3.Row
    try:
        users = [dict(r) for r in con.execute("SELECT id, email, hashed_password FROM users")]
        cols = {r["name"] for r in con.execute("PRAGMA table_info(logs)")}
        select_cols = ", ".join(c if c in cols else f"NULL AS {c}" for c in LOG_COLUMNS)
        logs = [dict(r) for r in con.execute(f"SELECT {select_cols} FROM logs ORDER BY id")]
    finally:
        con.close()
    return users, logs


def import_v1(engine: Engine, sqlite_path: str, dry_run: bool = False) -> Report:
    users, logs = read_v1(sqlite_path)
    rep = Report()
    with engine.connect() as conn:  # one transaction; committed or rolled back below
        accepted: set[int] = set()
        for u in users:
            email = (u["email"] or "").strip().lower()
            if not email or not u["hashed_password"]:
                rep.users_skipped.append(f"id={u['id']}: missing email/password")
                continue
            by_id = conn.execute(select(User.email).where(User.id == u["id"])).first()
            by_email = conn.execute(select(User.id).where(User.email == email)).first()
            if by_id is not None or by_email is not None:
                same = by_id is not None and by_id[0] == email and by_email and by_email[0] == u["id"]
                if same:
                    accepted.add(u["id"])  # already imported earlier: idempotent re-run
                else:
                    rep.users_skipped.append(f"id={u['id']}: id or email already used in target")
                continue
            conn.execute(User.__table__.insert().values(
                id=u["id"], email=email, hashed_password=u["hashed_password"]))
            accepted.add(u["id"])
            rep.users_imported += 1

        existing_log_ids = set(conn.execute(select(Log.id)).scalars())
        for lg in logs:
            if lg["user_id"] not in accepted or lg["id"] in existing_log_ids:
                rep.logs_skipped += 1
                continue
            if lg["type"] not in ("EXERCISE", "NUTRITION") or not lg["name"]:
                rep.logs_skipped += 1
                continue
            row = {**lg, "created_at": _parse_ts(lg["created_at"])}
            conn.execute(Log.__table__.insert().values(**row))
            rep.logs_imported += 1

        if engine.dialect.name == "postgresql":
            # Explicit ids were inserted: move SERIAL sequences past them.
            for table in ("users", "logs"):
                conn.execute(text(
                    f"SELECT setval(pg_get_serial_sequence('{table}', 'id'), "
                    f"GREATEST((SELECT COALESCE(MAX(id), 0) FROM {table}), 1))"
                ))

        if dry_run:
            conn.rollback()
        else:
            conn.commit()
    return rep


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--sqlite", required=True, help="path to the v1 mrfit.db")
    p.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    args = p.parse_args(argv)

    from app.db.session import get_engine

    engine = get_engine()
    with engine.connect() as c:
        target_users = c.execute(select(func.count()).select_from(User)).scalar_one()
    print(f"target: {engine.dialect.name}, existing users: {target_users}")
    rep = import_v1(engine, args.sqlite, dry_run=args.dry_run)
    print(("DRY RUN - nothing written\n" if args.dry_run else "") + str(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
