from typing import Optional, List
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
    session_id: Optional[str] = None
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


class LogUpdate(BaseModel):
    name: Optional[str] = None
    session_id: Optional[str] = None
    sets: Optional[int] = None
    reps: Optional[int] = None
    weight: Optional[float] = None
    calories: Optional[int] = None

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
    def non_negative_sets_reps(cls, v):
        if v is not None and v < 0:
            raise ValueError("Sets/reps cannot be negative")
        return v


class CoachChatRequest(BaseModel):
    message: str
    history: List[dict] = []  # previous turns: [{"role":"user"|"coach", "text":"..."}]

    @field_validator("message")
    @classmethod
    def message_not_empty(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Message cannot be empty")
        if len(v) > 1000:
            raise ValueError("Message too long (max 1000 chars)")
        return v

    @field_validator("history")
    @classmethod
    def history_max_length(cls, v: list) -> list:
        # Keep at most the last 10 turns to prevent prompt bloat
        return v[-10:] if len(v) > 10 else v

