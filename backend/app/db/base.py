"""Declarative base + portable column types.

Production is PostgreSQL + TimescaleDB. Unit tests run on SQLite, so
Postgres-only types get a SQLite variant here (JSONB -> JSON). Timescale DDL
(hypertables, compression, retention) lives only in Alembic / app.db.timescale.
"""
from __future__ import annotations

from sqlalchemy import JSON, DateTime, MetaData
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase

# Deterministic constraint names -> stable, reviewable migrations.
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

JSONB_T = JSON().with_variant(JSONB(), "postgresql")
TZDateTime = DateTime(timezone=True)


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
