"""Ported from v1 archive/legacy_v1/schemas.py (LogCreate/LogUpdate/ParseRequest)."""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


def _positive(v: int | None) -> int | None:
    if v is not None and v <= 0:
        raise ValueError("Sets/reps must be positive")
    return v


def _non_negative(v: float | None) -> float | None:
    if v is not None and v < 0:
        raise ValueError("Value cannot be negative")
    return v


class LogCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: Literal["EXERCISE", "NUTRITION"]
    name: str = Field(min_length=1, max_length=200)
    session_id: str | None = Field(default=None, max_length=100)
    sets: int | None = None
    reps: int | None = None
    weight: float | None = Field(default=None, allow_inf_nan=False)
    calories: int | None = None
    volume: float | None = None  # ignored for EXERCISE: recomputed server-side (as in v1)
    raw_text: str = Field(default="", max_length=2000)

    @field_validator("sets", "reps")
    @classmethod
    def _pos(cls, v: int | None) -> int | None:
        return _positive(v)

    @field_validator("weight", "calories")
    @classmethod
    def _nonneg(cls, v):
        return _non_negative(v)


class LogUpdate(BaseModel):
    """v1 allowed sets/reps = 0 on update but not on create; v2 requires > 0 for both (D-028)."""

    model_config = ConfigDict(extra="forbid")
    name: str | None = Field(default=None, min_length=1, max_length=200)
    session_id: str | None = Field(default=None, max_length=100)
    sets: int | None = None
    reps: int | None = None
    weight: float | None = Field(default=None, allow_inf_nan=False)
    calories: int | None = None

    @field_validator("sets", "reps")
    @classmethod
    def _pos(cls, v: int | None) -> int | None:
        return _positive(v)

    @field_validator("weight", "calories")
    @classmethod
    def _nonneg(cls, v):
        return _non_negative(v)


class LogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    user_id: int
    session_id: str | None
    type: str
    name: str
    sets: int | None
    reps: int | None
    weight: float | None
    calories: int | None
    volume: float | None
    raw_text: str | None
    created_at: datetime


class ParseRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str
    prefill_exercise: str | None = Field(default=None, max_length=200)

    @field_validator("text")
    @classmethod
    def _text(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Text cannot be empty")
        if len(v) > 2000:
            raise ValueError("Text too long (max 2000 chars)")
        return v
