"""Biomechanics tables: baselines, set summaries, and the two TimescaleDB hypertables.

Hypertable rule: every UNIQUE/PK constraint must include the partition column `time`.
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Float,
    ForeignKey,
    Index,
    Integer,
    PrimaryKeyConstraint,
    String,
    Uuid,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import JSONB_T, Base, TZDateTime
from app.models.constants import (
    BIOMECH_EXERCISES,
    COACHING_SOURCES,
    DATA_SOURCES,
    GOALS,
    sql_in,
)


class BiomechanicalSet(Base):
    """One concluded set (SetSummaryPayload, see docs/CONTRACT.md). `set_id` is generated
    on the phone, so POST /sets is idempotent under retry."""

    __tablename__ = "biomechanical_sets"

    set_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    athlete_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    schema_version: Mapped[str] = mapped_column(String(16), nullable=False)
    exercise: Mapped[str] = mapped_column(String(32), nullable=False)
    goal: Mapped[str] = mapped_column(String(32), nullable=False)
    vl_cap_pct: Mapped[float] = mapped_column(Float, nullable=False)
    set_index: Mapped[int] = mapped_column(Integer, nullable=False)
    reps_completed: Mapped[int] = mapped_column(Integer, nullable=False)
    load_kg: Mapped[float | None] = mapped_column(Float)

    mpv_initial: Mapped[float | None] = mapped_column(Float)
    mpv_final: Mapped[float | None] = mapped_column(Float)
    velocity_loss_pct: Mapped[float | None] = mapped_column(Float)
    vl_cap_exceeded: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    mqs_score: Mapped[float | None] = mapped_column(Float)
    mqs_breakdown: Mapped[dict[str, Any] | None] = mapped_column(JSONB_T)
    symmetry_index: Mapped[float | None] = mapped_column(Float)
    fault_counts: Mapped[dict[str, Any]] = mapped_column(JSONB_T, nullable=False)
    per_rep: Mapped[list[Any]] = mapped_column(JSONB_T, nullable=False)
    device_labels: Mapped[list[Any]] = mapped_column(JSONB_T, nullable=False)
    data_source: Mapped[str] = mapped_column(String(16), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB_T, nullable=False)  # full original, for audit

    slm_coaching_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB_T)
    coaching_source: Mapped[str | None] = mapped_column(String(16))
    coached_at: Mapped[datetime | None] = mapped_column(TZDateTime)

    started_at: Mapped[datetime | None] = mapped_column(TZDateTime)
    ended_at: Mapped[datetime | None] = mapped_column(TZDateTime)
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )
    # Mirror row in v1 `logs` so Stats / heatmap include sensor-tracked sets (D-021).
    log_id: Mapped[int | None] = mapped_column(ForeignKey("logs.id", ondelete="SET NULL"))

    __table_args__ = (
        CheckConstraint(sql_in("exercise", BIOMECH_EXERCISES), name="exercise"),
        CheckConstraint(sql_in("goal", GOALS), name="goal"),
        CheckConstraint(sql_in("data_source", DATA_SOURCES), name="data_source"),
        CheckConstraint(
            "coaching_source IS NULL OR " + sql_in("coaching_source", COACHING_SOURCES),
            name="coaching_source",
        ),
        CheckConstraint("vl_cap_pct > 0 AND vl_cap_pct <= 100", name="vl_cap_pct"),
        CheckConstraint("reps_completed >= 0", name="reps_completed"),
        Index("ix_biomechanical_sets_athlete_id_created_at", "athlete_id", "created_at"),
        Index(
            "ix_biomechanical_sets_athlete_id_exercise_created_at",
            "athlete_id",
            "exercise",
            "created_at",
        ),
    )


class AthleteBaseline(Base):
    """Per-athlete reference values per biomechanics exercise (ASSUMPTION: one row per
    athlete+exercise, measured at `load_kg`). Feeds MQS normalisation and coaching context."""

    __tablename__ = "athlete_baselines"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    athlete_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    exercise: Mapped[str] = mapped_column(String(32), nullable=False)
    load_kg: Mapped[float | None] = mapped_column(Float)
    mpv_reference_m_s: Mapped[float | None] = mapped_column(Float)
    peak_depth_reference_deg: Mapped[float | None] = mapped_column(Float)
    symmetry_reference: Mapped[float | None] = mapped_column(Float)
    sets_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    source_set_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("biomechanical_sets.set_id", ondelete="SET NULL")
    )
    meta: Mapped[dict[str, Any] | None] = mapped_column(JSONB_T)
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint(sql_in("exercise", BIOMECH_EXERCISES), name="exercise"),
        Index("uq_athlete_baselines_athlete_id_exercise", "athlete_id", "exercise", unique=True),
    )


class SensorTimeseries(Base):
    """GENERIC sample stream: any source, any channel (names from the channel registry).
    TimescaleDB hypertable on `time`; compressed by (set_id, channel)."""

    __tablename__ = "sensor_timeseries"

    time: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    set_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("biomechanical_sets.set_id", ondelete="CASCADE"), nullable=False
    )
    source: Mapped[str] = mapped_column(String(64), nullable=False)
    channel: Mapped[str] = mapped_column(String(64), nullable=False)
    value: Mapped[float] = mapped_column(Float, nullable=False)
    meta: Mapped[dict[str, Any] | None] = mapped_column(JSONB_T)

    __table_args__ = (
        # Includes `time` (hypertable rule) and makes batch re-sends idempotent.
        PrimaryKeyConstraint("set_id", "source", "channel", "time", name="pk_sensor_timeseries"),
    )


Index(
    "ix_sensor_timeseries_set_id_channel_time",
    SensorTimeseries.set_id,
    SensorTimeseries.channel,
    SensorTimeseries.time.desc(),
)


class SkeletonFrame(Base):
    """Pose keypoints per frame (keypoints JSONB: [{x, y, confidence}, ...], COCO-17 default)."""

    __tablename__ = "skeleton_frames"

    time: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    set_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("biomechanical_sets.set_id", ondelete="CASCADE"), nullable=False
    )
    rep_index: Mapped[int | None] = mapped_column(Integer)
    keypoints: Mapped[list[Any]] = mapped_column(JSONB_T, nullable=False)

    __table_args__ = (PrimaryKeyConstraint("set_id", "time", name="pk_skeleton_frames"),)


Index("ix_skeleton_frames_set_id_time", SkeletonFrame.set_id, SkeletonFrame.time.desc())
