"""TimescaleDB: generic sensor_timeseries + skeleton_frames hypertables, compression and
retention policies (values from TS_* env vars; re-synced on every container start by
`python -m app.db.timescale`).

Revision ID: 0003_timescale
Revises: 0002_v2_core
Create Date: 2026-11-20
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

from app.core.config import get_db_settings
from app.db import timescale

revision = "0003_timescale"
down_revision = "0002_v2_core"
branch_labels = None
depends_on = None

TZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    if op.get_context().dialect.name != "postgresql":
        raise RuntimeError("MR-Fit migrations target PostgreSQL/TimescaleDB")

    op.create_table(
        "sensor_timeseries",
        sa.Column("time", TZ, nullable=False),
        sa.Column("set_id", sa.Uuid(), nullable=False),
        sa.Column("source", sa.String(64), nullable=False),
        sa.Column("channel", sa.String(64), nullable=False),
        sa.Column("value", sa.Float(), nullable=False),
        sa.Column("meta", JSONB()),
        # Hypertable rule: PK/UNIQUE must include the partition column `time`.
        sa.PrimaryKeyConstraint("set_id", "source", "channel", "time", name="pk_sensor_timeseries"),
        sa.ForeignKeyConstraint(["set_id"], ["biomechanical_sets.set_id"], ondelete="CASCADE",
                                name="fk_sensor_timeseries_set_id_biomechanical_sets"),
        if_not_exists=True,
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_sensor_timeseries_set_id_channel_time "
        "ON sensor_timeseries (set_id, channel, time DESC)"
    )

    op.create_table(
        "skeleton_frames",
        sa.Column("time", TZ, nullable=False),
        sa.Column("set_id", sa.Uuid(), nullable=False),
        sa.Column("rep_index", sa.Integer()),
        sa.Column("keypoints", JSONB(), nullable=False),
        sa.PrimaryKeyConstraint("set_id", "time", name="pk_skeleton_frames"),
        sa.ForeignKeyConstraint(["set_id"], ["biomechanical_sets.set_id"], ondelete="CASCADE",
                                name="fk_skeleton_frames_set_id_biomechanical_sets"),
        if_not_exists=True,
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_skeleton_frames_set_id_time "
        "ON skeleton_frames (set_id, time DESC)"
    )

    s = get_db_settings()
    for stmt in timescale.hypertable_sql() + timescale.policy_sql(
        s.ts_compress_after_days, s.ts_sensor_retention_days, s.ts_skeleton_retention_days
    ):
        op.execute(stmt)


def downgrade() -> None:
    op.drop_table("skeleton_frames", if_exists=True)
    op.drop_table("sensor_timeseries", if_exists=True)
    # The extension is left installed (other databases objects may use it).
