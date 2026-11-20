"""SetSummaryPayload v1.0.0 — the contract between the phone's MetricsEngine and the API.

Mirrored by the Dart class in mobile/ and by contracts/set_summary.v1.schema.json
(generated from this model: `python -m scripts.export_contracts`). See docs/CONTRACT.md.

Rules
- Unknown fields are rejected (extra="forbid").
- Every field is REQUIRED. Optional metrics are nullable: the client must send an
  explicit null when it could not measure something; the server never guesses.
- Derived fields are cross-checked (fault_counts vs per_rep flags, vl_cap_exceeded
  vs velocity_loss_pct, len(per_rep) vs reps_completed).
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

SCHEMA_VERSION = "1.0.0"

Exercise = Literal["squat", "deadlift", "bench_press", "push_up"]
Goal = Literal["max_strength", "hypertrophy"]
FaultFlag = Literal["valgus", "lumbar_flexion", "incomplete_rom"]
DataSource = Literal["simulated", "real"]
VelocitySource = Literal["imu", "vision", "fused"]
SubScoreName = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_]{0,31}$")]
DeviceLabel = Annotated[str, StringConstraints(min_length=1, max_length=64)]

NonNegFloat = Annotated[float, Field(ge=0, allow_inf_nan=False)]
Pct = Annotated[float, Field(ge=0, le=100, allow_inf_nan=False)]
Score = Annotated[float, Field(ge=0, le=100, allow_inf_nan=False)]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class RepMetrics(_Strict):
    rep_index: int = Field(ge=1, description="1-based, contiguous")
    peak_depth_deg: Annotated[float, Field(ge=0, le=360, allow_inf_nan=False)] | None
    mean_velocity_m_s: NonNegFloat | None = Field(description="mean concentric (propulsive) velocity")
    fault_flags: list[FaultFlag] = Field(max_length=3)


class FaultCounts(_Strict):
    valgus: int = Field(ge=0)
    lumbar_flexion: int = Field(ge=0)
    incomplete_rom: int = Field(ge=0)


class SetSummaryPayload(_Strict):
    schema_version: Literal["1.0.0"]
    set_id: uuid.UUID
    exercise: Exercise
    goal: Goal
    vl_cap_pct: Annotated[float, Field(gt=0, le=100, allow_inf_nan=False)]
    set_index: int = Field(ge=1)
    reps_completed: int = Field(ge=0, le=200)
    load_kg: Annotated[float, Field(ge=0, le=1000, allow_inf_nan=False)] | None
    per_rep: list[RepMetrics] = Field(max_length=200)
    mpv_initial: NonNegFloat | None
    mpv_final: NonNegFloat | None
    velocity_loss_pct: Annotated[float, Field(ge=-100, le=100, allow_inf_nan=False)] | None
    vl_cap_exceeded: bool
    velocity_source: VelocitySource | None = Field(
        description="imu = sensor; vision = pose-derived (lower confidence); null = no velocity"
    )
    mqs_score: Score | None
    mqs_breakdown: Annotated[dict[SubScoreName, Score | None], Field(max_length=16)] | None
    symmetry_index: Annotated[float, Field(ge=-100, le=100, allow_inf_nan=False)] | None
    fault_counts: FaultCounts
    data_source: DataSource
    device_labels: list[DeviceLabel] = Field(min_length=1, max_length=8)
    started_at: datetime | None
    ended_at: datetime | None

    @model_validator(mode="after")
    def _consistent(self) -> "SetSummaryPayload":
        if len(self.per_rep) != self.reps_completed:
            raise ValueError("per_rep must have exactly reps_completed entries")
        if [r.rep_index for r in self.per_rep] != list(range(1, self.reps_completed + 1)):
            raise ValueError("per_rep.rep_index must be 1..reps_completed in order")
        for r in self.per_rep:
            if len(set(r.fault_flags)) != len(r.fault_flags):
                raise ValueError(f"rep {r.rep_index}: duplicate fault flag")
        tally = {f: 0 for f in FaultCounts.model_fields}
        for r in self.per_rep:
            for f in r.fault_flags:
                tally[f] += 1
        if tally != self.fault_counts.model_dump():
            raise ValueError("fault_counts must equal the tally of per_rep.fault_flags")
        if self.velocity_loss_pct is None:
            if self.vl_cap_exceeded:
                raise ValueError("vl_cap_exceeded cannot be true when velocity_loss_pct is null")
        elif self.vl_cap_exceeded != (self.velocity_loss_pct >= self.vl_cap_pct):
            raise ValueError("vl_cap_exceeded must equal velocity_loss_pct >= vl_cap_pct")
        if self.started_at and self.ended_at and self.ended_at < self.started_at:
            raise ValueError("ended_at is before started_at")
        return self

    # ---- metric lookup used by the coach (metric_ref keys) ----
    def metric_values(self) -> dict[str, float]:
        """Every numeric metric addressable by `metric_ref`, non-null only."""
        out: dict[str, float] = {}
        for key in ("set_index", "reps_completed", "load_kg", "vl_cap_pct", "mpv_initial",
                    "mpv_final", "velocity_loss_pct", "mqs_score", "symmetry_index"):
            v = getattr(self, key)
            if v is not None:
                out[key] = float(v)
        for k, v in self.fault_counts.model_dump().items():
            out[f"fault_counts.{k}"] = float(v)
        for k, v in (self.mqs_breakdown or {}).items():
            if v is not None:
                out[f"mqs_breakdown.{k}"] = float(v)
        for r in self.per_rep:
            if r.peak_depth_deg is not None:
                out[f"per_rep.{r.rep_index}.peak_depth_deg"] = float(r.peak_depth_deg)
            if r.mean_velocity_m_s is not None:
                out[f"per_rep.{r.rep_index}.mean_velocity_m_s"] = float(r.mean_velocity_m_s)
        return out
