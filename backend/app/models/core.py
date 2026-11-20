"""v1 tables (users, logs) carried forward + auth/library additions."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Uuid,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TZDateTime
from app.models.constants import LOG_TYPES, sql_in


class User(Base):
    """v1 `users`. `id` stays INTEGER (other tables reference it as athlete_id/user_id)."""

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String, nullable=False)
    hashed_password: Mapped[str] = mapped_column(String, nullable=False)  # bcrypt(sha256(pw))
    created_at: Mapped[datetime | None] = mapped_column(TZDateTime, server_default=func.now())

    __table_args__ = (Index("ix_users_email", "email", unique=True),)


class Log(Base):
    """v1 `logs`: one row per set (EXERCISE) or per food item (NUTRITION)."""

    __tablename__ = "logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    session_id: Mapped[str | None] = mapped_column(String)
    type: Mapped[str] = mapped_column(String, nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    sets: Mapped[int | None] = mapped_column(Integer)
    reps: Mapped[int | None] = mapped_column(Integer)
    weight: Mapped[float | None] = mapped_column(Float)
    calories: Mapped[int | None] = mapped_column(Integer)
    volume: Mapped[float | None] = mapped_column(Float)
    raw_text: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint(sql_in("type", LOG_TYPES), name="type"),
        Index("ix_logs_session_id", "session_id"),
        Index("ix_logs_user_id_created_at", "user_id", "created_at"),
    )


class RefreshToken(Base):
    """Rotating refresh tokens. Only a SHA-256 hash is stored. Reuse of a rotated
    token revokes the whole family (token-theft detection)."""

    __tablename__ = "refresh_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    family_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )
    revoked_at: Mapped[datetime | None] = mapped_column(TZDateTime)
    replaced_by_id: Mapped[int | None] = mapped_column(
        ForeignKey("refresh_tokens.id", ondelete="SET NULL")
    )

    __table_args__ = (
        Index("ix_refresh_tokens_token_hash", "token_hash", unique=True),
        Index("ix_refresh_tokens_family_id", "family_id"),
        Index("ix_refresh_tokens_user_id", "user_id"),
    )


class CustomExercise(Base):
    """v1 kept these in browser localStorage as {name, muscle, type}; now per-user in the DB."""

    __tablename__ = "custom_exercises"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    muscle: Mapped[str] = mapped_column(String(32), nullable=False)
    equipment_type: Mapped[str] = mapped_column(String(32), nullable=False)  # v1 field "type"
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )



# Case-insensitive uniqueness per user (v1 compared names lower-cased).
Index(
    "uq_custom_exercises_user_id_lower_name",
    CustomExercise.user_id,
    func.lower(CustomExercise.name),
    unique=True,
)
