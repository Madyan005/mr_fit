"""Persistence for biomechanics sets and their streams. All writes are idempotent so the
mobile retry queue can resend safely."""
from __future__ import annotations

import uuid
from collections.abc import Iterable
from typing import Any

from sqlalchemy import Table, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from app.core.contracts import exercise_library
from app.models import BiomechanicalSet, Log, SensorTimeseries, SkeletonFrame
from app.schemas.set_summary import SetSummaryPayload
from app.schemas.streams import SkeletonBatch, TimeseriesBatch
from app.services.volume import exercise_volume

INSERT_CHUNK = 1000  # keeps SQLite under its bound-parameter limit


class SetConflict(Exception):
    """Same set_id already stored with a different payload or another athlete."""


def _display_name(exercise: str) -> str:
    for e in exercise_library()["exercises"]:
        if e.get("biomech_key") == exercise:
            return e["name"]
    return exercise


def create_or_get_set(db: Session, athlete_id: int, p: SetSummaryPayload) -> tuple[BiomechanicalSet, bool]:
    """Returns (row, created). Identical replay -> existing row. Different payload -> SetConflict."""
    body = p.model_dump(mode="json")
    existing = db.get(BiomechanicalSet, p.set_id)
    if existing is not None:
        if existing.athlete_id != athlete_id or existing.payload != body:
            raise SetConflict
        return existing, False

    # Mirror into v1 `logs` so Stats / heatmap / history include sensor-tracked sets (D-021).
    log = Log(user_id=athlete_id, type="EXERCISE", name=_display_name(p.exercise), sets=1,
              reps=p.reps_completed or None, weight=p.load_kg,
              volume=exercise_volume(1, p.reps_completed, p.load_kg),
              raw_text=f"[biomech set {p.set_id}]",
              **({"created_at": p.ended_at} if p.ended_at else {}))
    db.add(log)
    db.flush()
    row = BiomechanicalSet(
        set_id=p.set_id, athlete_id=athlete_id, schema_version=p.schema_version,
        exercise=p.exercise, goal=p.goal, vl_cap_pct=p.vl_cap_pct, set_index=p.set_index,
        reps_completed=p.reps_completed, load_kg=p.load_kg, mpv_initial=p.mpv_initial,
        mpv_final=p.mpv_final, velocity_loss_pct=p.velocity_loss_pct,
        vl_cap_exceeded=p.vl_cap_exceeded, mqs_score=p.mqs_score, mqs_breakdown=p.mqs_breakdown,
        symmetry_index=p.symmetry_index, fault_counts=p.fault_counts.model_dump(),
        per_rep=body["per_rep"], device_labels=list(p.device_labels), data_source=p.data_source,
        payload=body, started_at=p.started_at, ended_at=p.ended_at, log_id=log.id,
    )
    db.add(row)
    db.commit()
    return row, True


def get_owned_set(db: Session, athlete_id: int, set_id: uuid.UUID) -> BiomechanicalSet | None:
    row = db.get(BiomechanicalSet, set_id)
    return row if row is not None and row.athlete_id == athlete_id else None


def _insert_ignore(db: Session, table: Table, rows: list[dict[str, Any]]) -> int:
    dialect = db.get_bind().dialect.name
    ins = {"postgresql": pg_insert, "sqlite": sqlite_insert}.get(dialect)
    if ins is None:
        raise RuntimeError(f"unsupported dialect {dialect}")
    inserted = 0
    for i in range(0, len(rows), INSERT_CHUNK):
        chunk = rows[i : i + INSERT_CHUNK]
        res = db.execute(ins(table).values(chunk).on_conflict_do_nothing())
        inserted += res.rowcount if res.rowcount is not None and res.rowcount >= 0 else 0
    db.commit()
    return inserted


def _dedupe(rows: Iterable[dict[str, Any]], key: tuple[str, ...]) -> list[dict[str, Any]]:
    seen: dict[tuple, dict[str, Any]] = {}
    for r in rows:
        seen.setdefault(tuple(r[k] for k in key), r)  # first wins, same as ON CONFLICT DO NOTHING
    return list(seen.values())


def add_timeseries(db: Session, set_id: uuid.UUID, batch: TimeseriesBatch) -> tuple[int, int]:
    rows = _dedupe(({"time": batch.anchor.to_wall(s.t_mono_ns), "set_id": set_id, "source": s.source,
                     "channel": s.channel, "value": s.value} for s in batch.samples),
                   ("set_id", "source", "channel", "time"))
    return len(batch.samples), _insert_ignore(db, SensorTimeseries.__table__, rows)


def add_skeleton(db: Session, set_id: uuid.UUID, batch: SkeletonBatch) -> tuple[int, int]:
    rows = _dedupe(({"time": batch.anchor.to_wall(f.t_mono_ns), "set_id": set_id,
                     "rep_index": f.rep_index,
                     "keypoints": [k.model_dump() for k in f.keypoints]} for f in batch.frames),
                   ("set_id", "time"))
    return len(batch.frames), _insert_ignore(db, SkeletonFrame.__table__, rows)


def recent_sets(db: Session, athlete_id: int, exercise: str | None, limit: int, before=None):
    q = select(BiomechanicalSet).where(BiomechanicalSet.athlete_id == athlete_id)
    if exercise:
        q = q.where(BiomechanicalSet.exercise == exercise)
    if before is not None:
        q = q.where(BiomechanicalSet.created_at < before)
    return list(db.scalars(q.order_by(BiomechanicalSet.created_at.desc()).limit(limit)))
