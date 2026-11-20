"""Batched uploads for POST /sets/{id}/timeseries and /skeleton.

Timestamps: samples carry phone-monotonic nanoseconds (sensor clock already mapped to
the phone clock by TimeSync). Each batch carries one `anchor` pairing a monotonic
instant with its UTC wall time; the server converts:  time = wall_time + (t - t_anchor).
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Annotated

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, StringConstraints

Name = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.:-]+$")]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ClockAnchor(_Strict):
    t_mono_ns: int = Field(ge=0)
    wall_time: AwareDatetime

    def to_wall(self, t_mono_ns: int) -> datetime:
        # timedelta has microsecond resolution (enough for <= 1 kHz streams).
        return self.wall_time + timedelta(microseconds=(t_mono_ns - self.t_mono_ns) / 1000)


class SampleIn(_Strict):
    channel: Name
    value: float = Field(allow_inf_nan=False)
    t_mono_ns: int = Field(ge=0)
    source: Name


class TimeseriesBatch(_Strict):
    anchor: ClockAnchor
    samples: list[SampleIn] = Field(min_length=1)  # max enforced from settings in the route


class Keypoint(_Strict):
    x: float = Field(allow_inf_nan=False)
    y: float = Field(allow_inf_nan=False)
    confidence: float = Field(ge=0, le=1)


class FrameIn(_Strict):
    t_mono_ns: int = Field(ge=0)
    rep_index: int | None = Field(default=None, ge=1)
    keypoints: list[Keypoint] = Field(min_length=1, max_length=133)  # COCO-17 default; whole-body max


class SkeletonBatch(_Strict):
    anchor: ClockAnchor
    frames: list[FrameIn] = Field(min_length=1)


class BatchResult(BaseModel):
    received: int
    inserted: int
    duplicates: int
