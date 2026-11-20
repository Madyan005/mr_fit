"""Migration checks.

Offline tests (always run): Alembic renders the full PostgreSQL DDL with no server
(`upgrade --sql`), and we check it against the ORM metadata.

Online test (opt-in): set MRFIT_TEST_PG_URL to a throwaway TimescaleDB database, e.g.
    docker compose up -d timescaledb
    MRFIT_TEST_PG_URL=postgresql+psycopg://mrfit:<pw>@127.0.0.1:5432/mrfit_test pytest -k online
"""
from __future__ import annotations

import io
import os
import re
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory

import app.models  # noqa: F401
from app.core.config import get_db_settings
from app.db.base import Base
from app.db.session import get_engine, get_sessionmaker

BACKEND = Path(__file__).resolve().parents[1]
FAKE_PG = "postgresql+psycopg://u:p@localhost:5432/none"  # never connected in offline mode
HYPERTABLES = ("sensor_timeseries", "skeleton_frames")


def _cfg(buf: io.StringIO | None = None) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"), output_buffer=buf)
    cfg.set_main_option("script_location", str(BACKEND / "alembic"))
    return cfg


def _use_db(monkeypatch, url: str, **env) -> None:
    monkeypatch.setenv("DATABASE_URL", url)
    for k, v in env.items():
        monkeypatch.setenv(k, str(v))
    for f in (get_db_settings, get_engine, get_sessionmaker):
        f.cache_clear()


@pytest.fixture()
def offline_sql(monkeypatch) -> str:
    _use_db(monkeypatch, FAKE_PG, TS_SENSOR_RETENTION_DAYS=45, TS_SKELETON_RETENTION_DAYS=12,
            TS_COMPRESS_AFTER_DAYS=3)
    buf = io.StringIO()
    command.upgrade(_cfg(buf), "head", sql=True)
    yield buf.getvalue()
    for f in (get_db_settings, get_engine, get_sessionmaker):
        f.cache_clear()


def test_single_linear_head():
    script = ScriptDirectory.from_config(_cfg())
    assert script.get_heads() == ["0003_timescale"]
    chain = [r.revision for r in script.walk_revisions()]
    assert chain == ["0003_timescale", "0002_v2_core", "0001_v1_baseline"]


def _table_text(sql: str, table: str) -> str:
    """All DDL text that defines/changes `table` (CREATE TABLE block + ALTER TABLE stmts)."""
    parts = re.findall(rf"CREATE TABLE IF NOT EXISTS {table} \((.*?)\n\);", sql, flags=re.S)
    parts += re.findall(rf"ALTER TABLE {table}\b(.*?);", sql, flags=re.S)
    return "\n".join(parts)


def test_every_orm_table_and_column_is_migrated(offline_sql):
    for name, table in Base.metadata.tables.items():
        assert f"CREATE TABLE IF NOT EXISTS {name} (" in offline_sql, name
        body = _table_text(offline_sql, name)
        for col in table.columns:
            assert re.search(rf"\b{col.name}\b", body), f"{name}.{col.name} missing from migrations"


def test_every_orm_index_is_migrated(offline_sql):
    for table in Base.metadata.tables.values():
        for ix in table.indexes:
            assert re.search(rf"INDEX (IF NOT EXISTS )?{ix.name}\b", offline_sql), ix.name


def test_hypertable_keys_include_time():
    for name in HYPERTABLES:
        t = Base.metadata.tables[name]
        assert "time" in t.primary_key.columns.keys()
        for ix in t.indexes:
            if ix.unique:
                assert "time" in [c.name for c in ix.columns], ix.name


def test_timescale_ddl_uses_config(offline_sql):
    assert "CREATE EXTENSION IF NOT EXISTS timescaledb" in offline_sql
    for t in HYPERTABLES:
        assert f"create_hypertable('{t}'" in offline_sql
        assert f"add_retention_policy('{t}', drop_after => INTERVAL" in offline_sql
    assert "timescaledb.segmentby = 'set_id, channel'" in offline_sql
    assert "timescaledb.compress_segmentby = 'set_id, channel'" in offline_sql
    assert "add_retention_policy('sensor_timeseries', drop_after => INTERVAL '45 days')" in offline_sql
    assert "add_retention_policy('skeleton_frames', drop_after => INTERVAL '12 days')" in offline_sql
    assert "INTERVAL '3 days'" in offline_sql  # compress after


def test_v1_timestamps_converted_as_utc(offline_sql):
    assert "USING created_at AT TIME ZONE 'UTC'" in offline_sql


def test_non_postgres_refused(monkeypatch, tmp_path):
    _use_db(monkeypatch, f"sqlite:///{tmp_path / 'x.db'}")
    with pytest.raises(RuntimeError, match="PostgreSQL"):
        command.upgrade(_cfg(io.StringIO()), "head", sql=True)


@pytest.mark.skipif(not os.getenv("MRFIT_TEST_PG_URL"), reason="needs MRFIT_TEST_PG_URL (TimescaleDB)")
def test_online_upgrade_is_idempotent_and_matches_orm(monkeypatch):
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext
    from sqlalchemy import text

    _use_db(monkeypatch, os.environ["MRFIT_TEST_PG_URL"])
    cfg = _cfg()
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0001_v1_baseline")
    command.upgrade(cfg, "head")  # re-run over existing v1 tables

    eng = get_engine()
    with eng.connect() as conn:
        hts = set(conn.execute(text(
            "SELECT hypertable_name FROM timescaledb_information.hypertables")).scalars())
        assert set(HYPERTABLES) <= hts
        comp = set(conn.execute(text(
            "SELECT hypertable_name FROM timescaledb_information.hypertables "
            "WHERE compression_enabled")).scalars())
        assert set(HYPERTABLES) <= comp
        diff = compare_metadata(MigrationContext.configure(conn), Base.metadata)
    assert diff == [], diff
