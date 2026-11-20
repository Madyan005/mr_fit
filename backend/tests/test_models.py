"""ORM-level constraints, run on SQLite (CHECK, UNIQUE, FK cascade, composite PKs)."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.models import (
    BiomechanicalSet,
    CustomExercise,
    Log,
    SensorTimeseries,
    SkeletonFrame,
    User,
)

T0 = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)


def _user(db, email="a@test.dev") -> User:
    u = User(email=email, hashed_password="h")
    db.add(u)
    db.commit()
    return u


def _set(db, user: User, **kw) -> BiomechanicalSet:
    fields = dict(
        set_id=uuid.uuid4(), athlete_id=user.id, schema_version="1.0.0", exercise="squat",
        goal="hypertrophy", vl_cap_pct=30.0, set_index=1, reps_completed=5, fault_counts={},
        per_rep=[], device_labels=["MockSensorSource"], data_source="simulated", payload={},
    )
    fields.update(kw)
    s = BiomechanicalSet(**fields)
    db.add(s)
    db.commit()
    return s


def test_user_email_unique(db):
    _user(db)
    db.add(User(email="a@test.dev", hashed_password="x"))
    with pytest.raises(IntegrityError):
        db.commit()


@pytest.mark.parametrize(
    "field,value",
    [("exercise", "bicep_curl"), ("goal", "endurance"), ("data_source", "guess"),
     ("vl_cap_pct", 0.0), ("reps_completed", -1), ("coaching_source", "gemini")],
)
def test_biomechanical_set_checks(db, field, value):
    u = _user(db)
    with pytest.raises(IntegrityError):
        _set(db, u, **{field: value})


def test_log_type_check(db):
    u = _user(db)
    db.add(Log(user_id=u.id, type="CARDIO", name="run"))
    with pytest.raises(IntegrityError):
        db.commit()


def test_custom_exercise_case_insensitive_unique_per_user(db):
    a, b = _user(db, "a@x.dev"), _user(db, "b@x.dev")
    db.add(CustomExercise(user_id=a.id, name="Zercher Squat", muscle="Legs", equipment_type="Barbell"))
    db.add(CustomExercise(user_id=b.id, name="zercher squat", muscle="Legs", equipment_type="Barbell"))
    db.commit()  # different users: fine
    db.add(CustomExercise(user_id=a.id, name="ZERCHER SQUAT", muscle="Legs", equipment_type="Barbell"))
    with pytest.raises(IntegrityError):
        db.commit()


def test_timeseries_pk_makes_resend_detectable(db):
    s = _set(db, _user(db))
    row = dict(time=T0, set_id=s.set_id, source="mock_imu", channel="bar_vel_z", value=0.5)
    db.add(SensorTimeseries(**row))
    db.commit()
    db.add(SensorTimeseries(**row))  # same (set_id, source, channel, time)
    with pytest.raises(IntegrityError):
        db.commit()
    db.rollback()
    db.add(SensorTimeseries(**{**row, "time": T0 + timedelta(milliseconds=10)}))
    db.add(SensorTimeseries(**{**row, "channel": "accel_x"}))
    db.commit()


def test_deleting_user_cascades_to_sets_and_series(db):
    u = _user(db)
    s = _set(db, u)
    db.add(SensorTimeseries(time=T0, set_id=s.set_id, source="m", channel="accel_x", value=1.0))
    db.add(SkeletonFrame(time=T0, set_id=s.set_id, rep_index=0, keypoints=[{"x": 0, "y": 0, "confidence": 1}]))
    db.add(Log(user_id=u.id, type="EXERCISE", name="Squat"))
    db.commit()
    db.delete(u)
    db.commit()
    for model in (BiomechanicalSet, SensorTimeseries, SkeletonFrame, Log):
        assert db.scalars(select(model)).first() is None


def test_jsonb_roundtrip(db):
    s = _set(db, _user(db), fault_counts={"valgus": 2}, mqs_breakdown={"rom": 0.9})
    db.expire_all()
    got = db.get(BiomechanicalSet, s.set_id)
    assert got.fault_counts == {"valgus": 2}
    assert got.mqs_breakdown == {"rom": 0.9}
