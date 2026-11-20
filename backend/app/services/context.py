"""Training context for the coach — computed deterministically, never raw DB rows.

`build_user_context` is ported from v1 (archive/legacy_v1/ai_logic.py) almost verbatim
(log analytics: frequency, volume, PRs, muscle balance). `biomech_history_labels` adds
the biomechanics history.

What reaches the model: only categorical LABELS (e.g. velocity_loss_trend="rising").
Numbers stay out of the prompt except the current SetSummaryPayload's own metrics, so the
number checker can require every number in the output to come from that payload.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta, timezone
from statistics import mean

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import BiomechanicalSet, Log

# v1 EXERCISE_MUSCLE_MAP (unchanged)
EXERCISE_MUSCLE_MAP = {
    "bench press": "chest", "incline bench press": "chest", "decline bench press": "chest",
    "dumbbell press": "chest", "chest press": "chest", "push up": "chest", "pushup": "chest",
    "push-up": "chest", "chest fly": "chest", "dumbbell fly": "chest", "cable fly": "chest", "pec deck": "chest",
    "pull up": "back", "pullup": "back", "pull-up": "back", "chin up": "back", "lat pulldown": "back",
    "barbell row": "back", "bent over row": "back", "dumbbell row": "back", "cable row": "back",
    "seated row": "back", "t-bar row": "back",
    "overhead press": "shoulders", "shoulder press": "shoulders", "military press": "shoulders",
    "lateral raise": "shoulders", "front raise": "shoulders", "rear delt fly": "shoulders",
    "arnold press": "shoulders", "face pull": "shoulders", "upright row": "shoulders",
    "romanian deadlift": "legs", "squat": "legs", "back squat": "legs", "front squat": "legs",
    "leg press": "legs", "lunge": "legs", "lunges": "legs", "leg extension": "legs", "leg curl": "legs",
    "hamstring curl": "legs", "calf raise": "legs", "hip thrust": "legs",
    "bulgarian split squat": "legs", "goblet squat": "legs", "deadlift": "back",
    "bicep curl": "arms", "barbell curl": "arms", "hammer curl": "arms", "preacher curl": "arms",
    "tricep pushdown": "arms", "tricep extension": "arms", "tricep dip": "arms", "skull crusher": "arms",
    "concentration curl": "arms", "dips": "arms", "cable curl": "arms",
    "plank": "core", "crunch": "core", "sit up": "core", "leg raise": "core",
    "russian twist": "core", "ab wheel": "core", "cable crunch": "core",
    "hanging leg raise": "core", "mountain climber": "core",
}


def classify_muscle_group(exercise_name: str) -> str:
    """Longest pattern wins (v1 took the first substring hit, so 'romanian deadlift' -> back)."""
    name = exercise_name.lower().strip()
    hits = [p for p in EXERCISE_MUSCLE_MAP if p in name]
    return EXERCISE_MUSCLE_MAP[max(hits, key=len)] if hits else "other"


def _date(dt: datetime):
    return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).date()


def build_user_context(user_id: int, db: Session, days: int = 14) -> dict:
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    logs = db.scalars(select(Log).where(Log.user_id == user_id, Log.created_at >= cutoff)
                      .order_by(Log.created_at)).all()
    if not logs:
        return {"period_days": days, "has_data": False}
    ex = [l for l in logs if l.type == "EXERCISE"]
    nu = [l for l in logs if l.type == "NUTRITION"]
    workout_dates = sorted({_date(l.created_at) for l in ex})
    cal_by_day: dict[str, int] = defaultdict(int)
    for l in nu:
        cal_by_day[_date(l.created_at).isoformat()] += l.calories or 0
    vol_by_ex: dict[str, float] = defaultdict(float)
    sets_by_ex: dict[str, int] = defaultdict(int)
    pr: dict[str, dict] = {}
    vol_by_muscle: dict[str, float] = defaultdict(float)
    for l in ex:
        vol_by_ex[l.name] += l.volume or 0
        sets_by_ex[l.name] += 1
        vol_by_muscle[classify_muscle_group(l.name)] += l.volume or 0
        if (l.weight or 0) > 0 and (l.name not in pr or l.weight > pr[l.name]["weight"]):
            pr[l.name] = {"weight": l.weight, "reps": l.reps, "date": _date(l.created_at).isoformat()}
    total_muscle = sum(vol_by_muscle.values()) or 1
    return {
        "period_days": days,
        "has_data": True,
        "weekly_workout_frequency": round(len(workout_dates) / max(days / 7, 1), 1),
        "total_training_volume": round(sum(l.volume or 0 for l in ex), 2),
        "avg_daily_calories": round(sum(cal_by_day.values()) / len(cal_by_day)) if cal_by_day else 0,
        "nutrition_days_logged": len(cal_by_day),
        "top_exercises": [
            {"name": n, "total_volume": round(v, 2), "total_sets": sets_by_ex[n]}
            for n, v in sorted(vol_by_ex.items(), key=lambda x: x[1], reverse=True)[:8]
        ],
        "personal_records": sorted(({"exercise": k, **v} for k, v in pr.items()),
                                   key=lambda x: x["weight"], reverse=True),
        "last_workout_date": workout_dates[-1].isoformat() if workout_dates else None,
        "workout_consistency_pct": round(len(workout_dates) / days * 100, 1),
        "muscle_balance": {
            g: {"volume": round(v, 2), "pct": round(v / total_muscle * 100, 1)}
            for g, v in sorted(vol_by_muscle.items(), key=lambda x: x[1], reverse=True)
        },
        "num_workout_days": len(workout_dates),
    }


def _trend(values: list[float], tolerance: float) -> str:
    if len(values) < 3:
        return "not_enough_data"
    half = len(values) // 2
    old, new = mean(values[:half]), mean(values[half:])
    if new > old + tolerance:
        return "rising"
    if new < old - tolerance:
        return "falling"
    return "stable"


def biomech_history_labels(athlete_id: int, exercise: str, db: Session,
                           exclude_set_id=None, limit: int = 10) -> dict[str, str]:
    """Categorical labels over the athlete's previous sets of this exercise (oldest first)."""
    q = (select(BiomechanicalSet)
         .where(BiomechanicalSet.athlete_id == athlete_id, BiomechanicalSet.exercise == exercise)
         .order_by(BiomechanicalSet.created_at.desc()).limit(limit))
    rows = [r for r in db.scalars(q) if r.set_id != exclude_set_id][::-1]
    if not rows:
        return {"history": "first_recorded_set_of_this_exercise"}
    vl = [r.velocity_loss_pct for r in rows if r.velocity_loss_pct is not None]
    mqs = [r.mqs_score for r in rows if r.mqs_score is not None]
    faults = [sum((r.fault_counts or {}).values()) for r in rows]
    return {
        "history": "has_previous_sets",
        "previous_sets_bucket": "few" if len(rows) < 5 else "several",
        "velocity_loss_trend": _trend(vl, tolerance=3.0),
        "movement_quality_trend": _trend(mqs, tolerance=3.0),
        "fault_trend": _trend([float(f) for f in faults], tolerance=0.5),
    }
