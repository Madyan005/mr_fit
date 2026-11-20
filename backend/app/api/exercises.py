"""Exercise library: 26 built-ins (contracts/exercise_library.v1.json, extracted from v1)
plus per-user custom exercises (v1 kept these in browser localStorage)."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.core.contracts import exercise_library
from app.models import CustomExercise, User
from app.schemas.exercises import CustomExerciseCreate, ExerciseLibraryOut, ExerciseOut

router = APIRouter(prefix="/exercises", tags=["exercises"])


def _custom_out(c: CustomExercise) -> ExerciseOut:
    return ExerciseOut(name=c.name, muscle=c.muscle, equipment_type=c.equipment_type,
                       custom=True, id=c.id, created_at=c.created_at)


@router.get("", response_model=ExerciseLibraryOut)
def get_library(user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> ExerciseLibraryOut:
    lib = exercise_library()
    custom = db.scalars(select(CustomExercise).where(CustomExercise.user_id == user.id)
                        .order_by(CustomExercise.created_at)).all()
    return ExerciseLibraryOut(
        muscles=lib["muscles"],
        equipment_types=lib["equipment_types"],
        exercises=[ExerciseOut(**e) for e in lib["exercises"]] + [_custom_out(c) for c in custom],
    )


@router.post("/custom", response_model=ExerciseOut, status_code=status.HTTP_201_CREATED)
def add_custom(body: CustomExerciseCreate, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> ExerciseOut:
    lowered = body.name.lower()
    clash_builtin = any(e["name"].lower() == lowered for e in exercise_library()["exercises"])
    clash_custom = db.scalar(select(CustomExercise.id).where(
        CustomExercise.user_id == user.id, func.lower(CustomExercise.name) == lowered))
    if clash_builtin or clash_custom is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Exercise already exists")
    row = CustomExercise(user_id=user.id, name=body.name, muscle=body.muscle,
                         equipment_type=body.equipment_type)
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Exercise already exists") from None
    db.refresh(row)
    return _custom_out(row)


@router.delete("/custom/{exercise_id}")
def delete_custom(exercise_id: int, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)) -> dict:
    row = db.scalars(select(CustomExercise).where(
        CustomExercise.id == exercise_id, CustomExercise.user_id == user.id)).first()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Custom exercise not found")
    db.delete(row)
    db.commit()
    return {"status": "deleted"}
