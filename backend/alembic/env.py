"""Alembic environment. DB URL comes from DATABASE_URL (app.core.config.DatabaseSettings),
never from alembic.ini, so no credentials live in the repo."""
from __future__ import annotations

from alembic import context

import app.models  # noqa: F401  (populate metadata)
from app.core.config import get_db_settings
from app.db.base import Base
from app.db.session import make_engine

config = context.config
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=get_db_settings().database_url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = make_engine(get_db_settings().database_url)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
