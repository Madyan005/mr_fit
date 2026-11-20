"""Ported from v1 archive/legacy_v1/main.py: /logs CRUD, /logs/heatmap, /stats.
Day boundaries are UTC, as in v1."""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models import Log, User
from app.schemas.logs import LogCreate, LogOut, LogUpdate
from app.services.volume import exercise_volume

router = APIRouter(tags=["logs"])


def _utc_day(d: date) -> tuple[datetime, datetime]:
    start = datetime.combine(d, time.min, tzinfo=timezone.utc)
    return start, start + timedelta(days=1)


def _day_key(dt: datetime) -> str:
    dt = dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)  # SQLite returns naive
    return dt.astimezone(timezone.utc).date().isoformat()


@router.post("/logs", response_model=LogOut, status_code=status.HTTP_201_CREATED)
def create_log(log: LogCreate, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> Log:
    volume = exercise_volume(log.sets, log.reps, log.weight) if log.type == "EXERCISE" else None
    row = Log(user_id=user.id, session_id=log.session_id, type=log.type, name=log.name,
              sets=log.sets, reps=log.reps, weight=log.weight, calories=log.calories,
              volume=volume, raw_text=log.raw_text)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@router.get("/logs", response_model=list[LogOut])
def list_logs(
    date_: date | None = Query(default=None, alias="date", description="YYYY-MM-DD (UTC day)"),
    limit: int = Query(default=200, ge=1, le=500),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Log]:
    q = select(Log).where(Log.user_id == user.id)
    if date_:
        start, end = _utc_day(date_)
        q = q.where(Log.created_at >= start, Log.created_at < end)
    return list(db.scalars(q.order_by(Log.created_at.desc(), Log.id.desc()).limit(limit)))


@router.get("/logs/heatmap")
def heatmap(
    days: int = Query(default=90, ge=1, le=366),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, dict]:
    """{date: {count, details[]}}. count = distinct session_ids + ungrouped rows (v1 rule)."""
    start, _ = _utc_day(datetime.now(timezone.utc).date() - timedelta(days=days - 1))
    rows = db.scalars(select(Log).where(Log.user_id == user.id, Log.created_at >= start)
                      .order_by(Log.created_at)).all()
    out: dict[str, dict] = {}
    for r in rows:
        d = out.setdefault(_day_key(r.created_at), {"count": 0, "details": []})
        d["details"].append(LogOut.model_validate(r).model_dump(mode="json", exclude={"user_id", "raw_text"}))
    for d in out.values():
        sessions = {x["session_id"] for x in d["details"] if x["session_id"]}
        d["count"] = len(sessions) + sum(1 for x in d["details"] if not x["session_id"])
    return out


def _owned(db: Session, log_id: int, user: User) -> Log:
    row = db.scalars(select(Log).where(Log.id == log_id, Log.user_id == user.id)).first()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Log not found")
    return row


@router.put("/logs/{log_id}", response_model=LogOut)
def update_log(log_id: int, upd: LogUpdate, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> Log:
    row = _owned(db, log_id, user)
    for k, v in upd.model_dump(exclude_unset=True).items():
        setattr(row, k, v)
    if row.type == "EXERCISE":
        row.volume = exercise_volume(row.sets, row.reps, row.weight)
    db.commit()
    db.refresh(row)
    return row


@router.delete("/logs/{log_id}")
def delete_log(log_id: int, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> dict:
    db.delete(_owned(db, log_id, user))
    db.commit()
    return {"status": "deleted"}


@router.get("/stats")
def stats(
    days: int = Query(default=7, ge=1, le=90),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    today = datetime.now(timezone.utc).date()
    start, _ = _utc_day(today - timedelta(days=days - 1))
    rows = db.scalars(select(Log).where(Log.user_id == user.id, Log.created_at >= start)).all()
    per_day = {(today - timedelta(days=i)).isoformat(): {"volume": 0.0, "calories": 0}
               for i in range(days - 1, -1, -1)}
    total_v = 0.0
    total_c = workouts = meals = 0
    for r in rows:
        k = _day_key(r.created_at)
        if k not in per_day:
            continue
        if r.type == "EXERCISE":
            per_day[k]["volume"] += r.volume or 0
            total_v += r.volume or 0
            workouts += 1
        else:
            per_day[k]["calories"] += r.calories or 0
            total_c += r.calories or 0
            meals += 1
    return {
        "avg_volume": round(total_v / days),
        "avg_calories": round(total_c / days),
        "total_workouts": workouts,
        "total_meals": meals,
        "days": [{"date": k, **v} for k, v in per_day.items()],
    }
