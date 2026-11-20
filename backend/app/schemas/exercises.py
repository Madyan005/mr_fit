from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Same option lists as the v1 "add custom exercise" form (archive/legacy_v1/static/index.html).
Muscle = Literal["Chest", "Back", "Shoulders", "Legs", "Arms", "Core"]
EquipmentType = Literal["Barbell", "Dumbbell", "Machine", "Cable", "Bodyweight", "Equipment"]


class CustomExerciseCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=100)
    muscle: Muscle
    equipment_type: EquipmentType

    @field_validator("name")
    @classmethod
    def _name(cls, v: str) -> str:
        v = " ".join(v.split())
        if not v:
            raise ValueError("Enter an exercise name")
        return v


class ExerciseOut(BaseModel):
    name: str
    muscle: str
    equipment_type: str
    biomech_key: str | None = None
    custom: bool = False
    id: int | None = None  # custom exercises only
    created_at: datetime | None = None


class ExerciseLibraryOut(BaseModel):
    muscles: list[str]
    equipment_types: list[str]
    exercises: list[ExerciseOut]
