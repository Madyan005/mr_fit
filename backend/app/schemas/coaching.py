"""Coaching schemas.

CoachingPrescription = the ONLY thing the SLM may produce (Ollama structured output).
It contains wording plus metric *references* (keys), never numbers to display.

CoachingCard = what the API stores (biomechanical_sets.slm_coaching_json) and returns.
Every number on it is filled deterministically: metric values are looked up from the
SetSummaryPayload by key, and the next-set prescription comes from the rules table.
"""
from __future__ import annotations

import copy
import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

CARD_SCHEMA_VERSION = "1.0.0"
CoachingSource = Literal["llm", "fallback", "guardrail"]
NextAction = Literal["continue", "increase_load", "reduce_load", "stop_exercise"]


class Cue(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=160)
    metric_ref: str | None = Field(description="key of a metric in the set summary, or null")


class CoachingPrescription(BaseModel):
    model_config = ConfigDict(extra="forbid")
    summary: str = Field(min_length=1, max_length=300)
    focus_metric: str | None = Field(description="key of the single most important metric, or null")
    cues: list[Cue] = Field(min_length=1, max_length=3)

    @classmethod
    def format_schema(cls, metric_keys: list[str]) -> dict[str, Any]:
        """`model_json_schema()` with metric_ref/focus_metric narrowed to the keys that
        exist (non-null) in THIS set, so the constrained decoder cannot invent one."""
        schema = copy.deepcopy(cls.model_json_schema())
        ref = {"anyOf": [{"type": "string", "enum": sorted(metric_keys)}, {"type": "null"}]}
        schema["properties"]["focus_metric"].update(ref)
        schema["properties"]["focus_metric"].pop("type", None)
        cue = schema["$defs"]["Cue"]["properties"]["metric_ref"]
        cue.update(ref)
        cue.pop("type", None)
        return schema


class CardCue(BaseModel):
    text: str
    metric_ref: str | None
    metric_value: float | None  # looked up from the payload, never from the model


class NextSetPrescription(BaseModel):
    action: NextAction
    rest_seconds: int | None
    load_change_pct: float
    rule_id: str


class CoachingCard(BaseModel):
    schema_version: Literal["1.0.0"] = CARD_SCHEMA_VERSION
    set_id: uuid.UUID
    source: CoachingSource
    summary: str
    cues: list[CardCue]
    focus_metric: str | None
    focus_value: float | None
    next_set: NextSetPrescription
    medical_notice: str | None = None
    model: str | None = None
    fallback_reason: str | None = None
    generated_at: datetime


class CoachingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    athlete_note: str | None = Field(default=None, max_length=500,
                                     description="optional free text/voice note; checked by the medical guardrail")
    force_regenerate: bool = False
