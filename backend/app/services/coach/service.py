"""Post-set coaching pipeline:

    athlete_note -> medical guardrail ──match──> canned referral card (source="guardrail")
                         │ no match
                         ▼
    deterministic prescription (rules.py) ── always computed, never by the model
                         ▼
    SLM via GpuScheduler (Ollama structured output, schema narrowed to this set's metrics)
       -> strip <think> -> Pydantic validate -> metric_ref exists -> number checker
       -> output guardrail      (any failure: retry once, then deterministic template)
                         ▼
    CoachingCard (numbers looked up from the payload by key)
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

from pydantic import ValidationError

from app.schemas.coaching import CardCue, CoachingCard, CoachingPrescription, Cue
from app.schemas.set_summary import SetSummaryPayload
from app.services.coach import guardrail, rules
from app.services.coach.llm import LLMClient, LLMError, extract_json_text
from app.services.coach.numbers import check_numbers
from app.services.gpu import GpuJob, GpuScheduler

log = logging.getLogger(__name__)
MAX_ATTEMPTS = 2  # first try + one retry

SYSTEM_PROMPT = """You are a strength coach writing a short post-set note.
Hard rules:
1. Do NOT write any digits or number words. The app shows every number itself.
2. Refer to a metric only through its key in "metric_ref" / "focus_metric", chosen from the provided list.
3. Never calculate anything. Never diagnose, name injuries, or give medical or rehab advice.
4. Use the deterministic next_set action as given; do not change it.
5. Plain English, encouraging, specific to the faults and metrics provided. At most three cues.
Reply with JSON only, matching the schema."""

_EX_NAMES = {"squat": "squat", "deadlift": "deadlift", "bench_press": "bench press", "push_up": "push-up"}
_FAULT_CUES = {
    "lumbar_flexion": "Brace hard and keep a neutral spine; your lower back rounded.",
    "valgus": "Push your knees out in line with your toes; they caved inward.",
    "incomplete_rom": "Reach full depth on every rep before driving up.",
}


class ContentRejected(Exception):
    pass


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _user_prompt(p: SetSummaryPayload, metrics: dict[str, float], history: dict[str, str],
                 next_action: str) -> str:
    faults = {k: v for k, v in p.fault_counts.model_dump().items() if v}
    return json.dumps({
        "exercise": p.exercise, "goal": p.goal,
        "metrics_available": {k: v for k, v in metrics.items() if not k.startswith("per_rep.")},
        "faults_present": sorted(faults),
        "velocity_loss_cap_exceeded": p.vl_cap_exceeded,
        "velocity_measured_by": p.velocity_source or "not_measured",
        "history": history,
        "next_set_action": next_action,
    }, sort_keys=True)


def _card(p: SetSummaryPayload, metrics: dict[str, float], source: str, summary: str,
          cues: list[Cue], focus: str | None, next_set, *, model: str | None = None,
          fallback_reason: str | None = None, medical_notice: str | None = None) -> CoachingCard:
    return CoachingCard(
        set_id=p.set_id, source=source, summary=summary,
        cues=[CardCue(text=c.text, metric_ref=c.metric_ref,
                      metric_value=metrics.get(c.metric_ref) if c.metric_ref else None) for c in cues],
        focus_metric=focus, focus_value=metrics.get(focus) if focus else None,
        next_set=next_set, model=model, fallback_reason=fallback_reason,
        medical_notice=medical_notice, generated_at=_now(),
    )


def validate_prescription(raw: str, p: SetSummaryPayload, metrics: dict[str, float]) -> CoachingPrescription:
    """Raises ContentRejected with a short reason. Used on every model answer."""
    try:
        presc = CoachingPrescription.model_validate_json(extract_json_text(raw))
    except (ValueError, ValidationError) as e:
        raise ContentRejected(f"schema: {type(e).__name__}") from None
    refs = [presc.focus_metric] + [c.metric_ref for c in presc.cues]
    if any(r is not None and r not in metrics for r in refs):
        raise ContentRejected("unknown metric_ref")
    texts = [presc.summary] + [c.text for c in presc.cues]
    allowed = list(metrics.values()) + [float(i) for i in range(1, p.reps_completed + 1)]
    nc = check_numbers(texts, allowed)
    if not nc.ok:
        raise ContentRejected(f"numbers not in payload: {list(nc.unmatched)}")
    if guardrail.check_output(" ".join(texts)).triggered:
        raise ContentRejected("medical content in output")
    return presc


def fallback_card(p: SetSummaryPayload, metrics: dict[str, float], next_set, reason: str) -> CoachingCard:
    """Deterministic template. Text has no numbers; values come via metric_ref lookup."""
    ex = _EX_NAMES[p.exercise]
    cues: list[Cue] = []
    for fault in ("lumbar_flexion", "valgus", "incomplete_rom"):
        if getattr(p.fault_counts, fault):
            cues.append(Cue(text=_FAULT_CUES[fault], metric_ref=f"fault_counts.{fault}"))
    if p.vl_cap_exceeded:
        cues.append(Cue(text="Velocity dropped past your goal's limit; end sets earlier.",
                        metric_ref="velocity_loss_pct"))
    if not cues:
        ref = "velocity_loss_pct" if "velocity_loss_pct" in metrics else None
        cues.append(Cue(text="Clean set. Keep the same tempo and bar path.", metric_ref=ref))
    cues = cues[:3]
    action_text = {
        "continue": "Keep the same load for the next set.",
        "increase_load": "You have room to add a little load next set.",
        "reduce_load": "Reduce the load for the next set.",
        "stop_exercise": "Stop this exercise for today.",
    }[next_set.action]
    summary = f"{ex.capitalize()} set logged. {action_text}"
    focus = cues[0].metric_ref
    return _card(p, metrics, "fallback", summary, cues, focus, next_set, fallback_reason=reason)


class CoachService:
    def __init__(self, llm: LLMClient, gpu: GpuScheduler):
        self.llm = llm
        self.gpu = gpu

    async def coach(self, p: SetSummaryPayload, athlete_note: str | None,
                    history: dict[str, str]) -> CoachingCard:
        metrics = p.metric_values()

        g = guardrail.check(athlete_note)
        if g.triggered:  # bypass the model entirely
            return _card(p, metrics, "guardrail", guardrail.canned_message(g), [], None,
                         rules.stop_prescription(), medical_notice=",".join(g.categories))

        next_set = rules.prescribe(p)
        schema = CoachingPrescription.format_schema(list(metrics))
        user = _user_prompt(p, metrics, history, next_set.action)
        reason = "unknown"
        for attempt in range(1, MAX_ATTEMPTS + 1):
            try:
                raw = await self.gpu.run(GpuJob(
                    name="coach_slm",
                    run=lambda: self.llm.generate_json(SYSTEM_PROMPT, user, schema),
                    release=self.llm.unload,
                ))
                presc = validate_prescription(raw, p, metrics)
                return _card(p, metrics, "llm", presc.summary, presc.cues, presc.focus_metric,
                             next_set, model=self.llm.model_name)
            except LLMError as e:
                reason = f"llm_unavailable: {e}"
                break  # transport failure: retrying immediately rarely helps
            except ContentRejected as e:
                reason = f"attempt {attempt}: {e}"
                log.info("coach output rejected (%s)", reason)
        return fallback_card(p, metrics, next_set, reason)
