"""v1 baseline: `users` and `logs` exactly as v1's Base.metadata.create_all() made them
(archive/legacy_v1/models.py). IF NOT EXISTS, so an existing v1 PostgreSQL database
(v1 honoured DATABASE_URL) is adopted instead of failing.

Revision ID: 0001_v1_baseline
Revises:
Create Date: 2026-11-20
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0001_v1_baseline"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("email", sa.String()),
        sa.Column("hashed_password", sa.String()),
        if_not_exists=True,
    )
    op.create_index("ix_users_id", "users", ["id"], if_not_exists=True)
    op.create_index("ix_users_email", "users", ["email"], unique=True, if_not_exists=True)

    op.create_table(
        "logs",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id")),
        sa.Column("session_id", sa.String(), nullable=True),
        sa.Column("type", sa.String()),
        sa.Column("name", sa.String()),
        sa.Column("sets", sa.Integer(), nullable=True),
        sa.Column("reps", sa.Integer(), nullable=True),
        sa.Column("weight", sa.Float(), nullable=True),
        sa.Column("calories", sa.Integer(), nullable=True),
        sa.Column("volume", sa.Float(), nullable=True),
        sa.Column("raw_text", sa.String()),
        sa.Column("created_at", sa.DateTime()),  # v1: naive UTC (datetime.utcnow)
        if_not_exists=True,
    )
    op.create_index("ix_logs_id", "logs", ["id"], if_not_exists=True)
    op.create_index("ix_logs_session_id", "logs", ["session_id"], if_not_exists=True)


def downgrade() -> None:
    op.drop_table("logs", if_exists=True)
    op.drop_table("users", if_exists=True)
