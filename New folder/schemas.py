from typing import Optional
from pydantic import BaseModel, field_validator

# =======================
# PYDANTIC SCHEMAS
# =======================

class AuthRequest(BaseModel):
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def email_lower(cls, v: str) -> str:
        return v.strip().lower()

    @field_validator("password")
    @classmethod
    def password_min_length(cls, v: str) -> str:
        if len(v) < 6:
            raise ValueError("Password must be at least 6 characters")
        return v


class ParseRequest(BaseModel):
    text: str
    prefill_exercise: Optional[str] = None

    @field_validator("text")
    @classmethod
    def text_not_empty(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Text cannot be empty")
        if len(v) > 2000:
            raise ValueError("Text too long (max 2000 chars)")
        return v


class LogCreate(BaseModel):
    type: str
    name: str
    sets: Optional[int] = None
    reps: Optional[int] = None
    weight: Optional[float] = None
    calories: Optional[int] = None
    volume: Optional[float] = None
    raw_text: str

    @field_validator("type")
    @classmethod
    def valid_type(cls, v: str) -> str:
        if v not in ("EXERCISE", "NUTRITION"):
            raise ValueError("type must be EXERCISE or NUTRITION")
        return v

    @field_validator("calories")
    @classmethod
    def non_negative_cals(cls, v):
        if v is not None and v < 0:
            raise ValueError("Calories cannot be negative")
        return v

    @field_validator("weight")
    @classmethod
    def non_negative_weight(cls, v):
        if v is not None and v < 0:
            raise ValueError("Weight cannot be negative")
        return v

    @field_validator("sets", "reps")
    @classmethod
    def positive_sets_reps(cls, v):
        if v is not None and v <= 0:
            raise ValueError("Sets/reps must be positive")
        return v
