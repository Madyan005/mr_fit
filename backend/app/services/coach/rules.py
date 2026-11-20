"""Deterministic next-set prescription. The model never produces these numbers.

ALL THRESHOLDS ARE PLACEHOLDERS — ASSUMPTION, needs validation by the team / a coach.
Evaluated top to bottom; the first matching rule wins. Edit RULES/REST_SECONDS to tune.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from app.schemas.coaching import NextSetPrescription
from app.schemas.set_summary import SetSummaryPayload

REST_SECONDS = {"max_strength": 180, "hypertrophy": 90}
EXTRA_REST_WHEN_CAP_EXCEEDED = 60


@dataclass(frozen=True)
class Rule:
    rule_id: str
    when: Callable[[SetSummaryPayload], bool]
    action: str
    load_change_pct: float


def _vl(p: SetSummaryPayload) -> float | None:
    return p.velocity_loss_pct


RULES: tuple[Rule, ...] = (
    Rule("lumbar_flexion_any", lambda p: p.fault_counts.lumbar_flexion >= 1, "reduce_load", -10.0),
    Rule("valgus_repeated", lambda p: p.fault_counts.valgus >= 2, "reduce_load", -5.0),
    Rule("vl_cap_exceeded", lambda p: p.vl_cap_exceeded, "reduce_load", -5.0),
    Rule("rom_incomplete_repeated", lambda p: p.fault_counts.incomplete_rom >= 2, "continue", 0.0),
    Rule("vl_well_below_cap",
         lambda p: _vl(p) is not None and _vl(p) < 0.5 * p.vl_cap_pct
         and sum(p.fault_counts.model_dump().values()) == 0 and p.reps_completed > 0,
         "increase_load", 2.5),
    Rule("default", lambda p: True, "continue", 0.0),
)


def prescribe(p: SetSummaryPayload) -> NextSetPrescription:
    rule = next(r for r in RULES if r.when(p))
    rest = REST_SECONDS[p.goal] + (EXTRA_REST_WHEN_CAP_EXCEEDED if p.vl_cap_exceeded else 0)
    return NextSetPrescription(action=rule.action, rest_seconds=rest,
                               load_change_pct=rule.load_change_pct, rule_id=rule.rule_id)


def stop_prescription() -> NextSetPrescription:
    """Used when the medical guardrail fires."""
    return NextSetPrescription(action="stop_exercise", rest_seconds=None, load_change_pct=0.0,
                               rule_id="medical_guardrail")
