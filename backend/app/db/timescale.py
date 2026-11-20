"""TimescaleDB DDL for the two hypertables, kept in one place.

* `hypertable_sql()`  - convert tables to hypertables (run once, by migration 0003).
* `policy_sql(s)`     - (re)apply compression + retention policies from settings.
                        Idempotent; the container entrypoint runs it on every start
                        so changing TS_* env vars takes effect after a restart:
                            python -m app.db.timescale

API compatibility (ASSUMPTION, not yet run against the pinned 2.31 image):
TimescaleDB 2.18 renamed compression to "columnstore" (`enable_columnstore`,
`add_columnstore_policy`) and kept the old names as deprecated aliases. Each
statement below tries the new API first and falls back to the legacy one inside a
PL/pgSQL EXCEPTION block, so it works on either side of the rename.
"""
from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import Connection, text

CHUNK_INTERVAL = "1 day"


@dataclass(frozen=True)
class HypertableSpec:
    table: str
    segmentby: str
    orderby: str = "time DESC"


SENSOR = HypertableSpec("sensor_timeseries", segmentby="set_id, channel")
SKELETON = HypertableSpec("skeleton_frames", segmentby="set_id")
HYPERTABLES = (SENSOR, SKELETON)


def _do(body: str) -> str:
    # No trailing ';' - Alembic adds the terminator in offline (--sql) output.
    return f"DO $mrfit$\nBEGIN\n{body}\nEND\n$mrfit$"


def hypertable_sql() -> list[str]:
    stmts = ["CREATE EXTENSION IF NOT EXISTS timescaledb"]
    for h in HYPERTABLES:
        stmts.append(
            _do(
                f"""  BEGIN
    PERFORM create_hypertable('{h.table}', by_range('time', INTERVAL '{CHUNK_INTERVAL}'),
                              if_not_exists => TRUE);
  EXCEPTION WHEN undefined_function THEN
    PERFORM create_hypertable('{h.table}', 'time',
                              chunk_time_interval => INTERVAL '{CHUNK_INTERVAL}',
                              if_not_exists => TRUE);
  END;"""
            )
        )
        # Compression settings can only be set while no chunk is compressed; skip if already on.
        stmts.append(
            _do(
                f"""  IF EXISTS (SELECT 1 FROM timescaledb_information.hypertables
             WHERE hypertable_name = '{h.table}' AND compression_enabled) THEN
    RETURN;
  END IF;
  BEGIN
    ALTER TABLE {h.table} SET (timescaledb.enable_columnstore = true,
                               timescaledb.segmentby = '{h.segmentby}',
                               timescaledb.orderby = '{h.orderby}');
  EXCEPTION WHEN OTHERS THEN
    ALTER TABLE {h.table} SET (timescaledb.compress,
                               timescaledb.compress_segmentby = '{h.segmentby}',
                               timescaledb.compress_orderby = '{h.orderby}');
  END;"""
            )
        )
    return stmts


def _days(n: int) -> str:
    if not isinstance(n, int) or n < 1:  # values are interpolated into SQL
        raise ValueError(f"invalid day count: {n!r}")
    return f"INTERVAL '{n} days'"


def policy_sql(compress_after_days: int, sensor_retention_days: int, skeleton_retention_days: int) -> list[str]:
    retention = {SENSOR.table: sensor_retention_days, SKELETON.table: skeleton_retention_days}
    stmts: list[str] = []
    for h in HYPERTABLES:
        stmts.append(
            _do(
                f"""  BEGIN
    PERFORM remove_columnstore_policy('{h.table}', if_exists => TRUE);
    PERFORM add_columnstore_policy('{h.table}', after => {_days(compress_after_days)});
  EXCEPTION WHEN undefined_function THEN
    PERFORM remove_compression_policy('{h.table}', if_exists => TRUE);
    PERFORM add_compression_policy('{h.table}', compress_after => {_days(compress_after_days)});
  END;"""
            )
        )
        stmts.append(f"SELECT remove_retention_policy('{h.table}', if_exists => TRUE)")
        stmts.append(
            f"SELECT add_retention_policy('{h.table}', drop_after => {_days(retention[h.table])})"
        )
    return stmts


def apply(conn: Connection, statements: list[str]) -> None:
    for s in statements:
        conn.execute(text(s))


def sync_policies() -> None:
    """CLI entry: re-apply policies from current env (container start)."""
    from app.core.config import get_db_settings
    from app.db.session import get_engine

    s = get_db_settings()
    engine = get_engine()
    if engine.dialect.name != "postgresql":
        print("[timescale] not PostgreSQL - skipping policy sync")
        return
    with engine.begin() as conn:
        apply(
            conn,
            policy_sql(s.ts_compress_after_days, s.ts_sensor_retention_days, s.ts_skeleton_retention_days),
        )
    print(
        f"[timescale] policies synced: compress after {s.ts_compress_after_days}d, "
        f"retention sensor={s.ts_sensor_retention_days}d skeleton={s.ts_skeleton_retention_days}d"
    )


if __name__ == "__main__":
    sync_policies()
