"""Coach pipeline with FakeLLMClient (no GPU, no Ollama)."""
from __future__ import annotations

import asyncio
import json

import pytest

from app.schemas.coaching import CoachingPrescription
from app.schemas.set_summary import SetSummaryPayload
from app.services.coach import rules
from app.services.coach.llm import FakeLLMClient, LLMError, extract_json_text
from app.services.coach.service import CoachService, ContentRejected, fallback_card, validate_prescription
from app.services.gpu import GpuJob, GpuScheduler
from tests.conftest import fixture_payload

SCENARIOS = ("clean", "fatigue", "valgus")


def payload(name="clean") -> SetSummaryPayload:
    return SetSummaryPayload.model_validate(fixture_payload(name))


def good(ref="velocity_loss_pct", summary="Strong, steady set.") -> str:
    return json.dumps({"summary": summary, "focus_metric": ref,
                       "cues": [{"text": "Stay tight at the bottom.", "metric_ref": ref}]})


def run(coro):
    return asyncio.run(coro)


def svc(llm) -> CoachService:
    return CoachService(llm, GpuScheduler())


def test_llm_happy_path_fills_numbers_from_payload():
    llm = FakeLLMClient([good()])
    card = run(svc(llm).coach(payload(), None, {}))
    assert card.source == "llm" and card.model == "fake-llm"
    assert card.focus_value == 11.3  # looked up, not produced by the model
    assert card.cues[0].metric_value == 11.3
    assert llm.unloads == 1  # VRAM released after the GPU job


def test_schema_sent_to_model_is_narrowed_to_this_sets_metrics():
    llm = FakeLLMClient([good()])
    run(svc(llm).coach(payload("valgus"), None, {}))
    enum = llm.calls[0]["schema"]["properties"]["focus_metric"]["anyOf"][0]["enum"]
    assert "fault_counts.valgus" in enum and "velocity_loss_pct" in enum
    assert "mqs_breakdown.stability" in enum and "not_a_metric" not in enum


def test_retry_once_then_succeed():
    llm = FakeLLMClient(["not json at all", good()])
    card = run(svc(llm).coach(payload(), None, {}))
    assert card.source == "llm" and len(llm.calls) == 2


@pytest.mark.parametrize("bad", [
    "garbage",
    json.dumps({"summary": "x", "focus_metric": None, "cues": []}),                      # schema: no cues
    json.dumps({"summary": "x", "focus_metric": "made_up", "cues": [{"text": "t", "metric_ref": None}]}),
    good(summary="Velocity loss hit 42 percent."),                                     # invented number
    good(summary="Rest 120 seconds then add 5 kg."),                                   # numbers the model must not prescribe
    good(summary="This looks like a torn meniscus."),                                  # diagnosis in output
    json.dumps({"summary": "x", "focus_metric": None, "cues": [{"text": "t", "metric_ref": None}], "extra": 1}),
])
def test_two_bad_answers_fall_back_deterministically(bad):
    llm = FakeLLMClient([bad, bad])
    card = run(svc(llm).coach(payload(), None, {}))
    assert card.source == "fallback"
    assert len(llm.calls) == 2  # exactly one retry
    assert "attempt 2" in card.fallback_reason


def test_think_block_is_stripped():
    raw = "<think>The loss is 11.3 so maybe 99 reps...</think>\n" + good()
    card = run(svc(FakeLLMClient([raw])).coach(payload(), None, {}))
    assert card.source == "llm"


@pytest.mark.parametrize("raw", [
    "<think>thinking</think>{\"a\": 1}",
    "thinking without opening tag</think>{\"a\": 1}",
    "```json\n{\"a\": 1}\n```",
])
def test_extract_json_text(raw):
    assert json.loads(extract_json_text(raw)) == {"a": 1}


def test_llm_unavailable_falls_back_without_retry():
    llm = FakeLLMClient(fail_with=LLMError("connection refused"))
    card = run(svc(llm).coach(payload(), None, {}))
    assert card.source == "fallback" and "llm_unavailable" in card.fallback_reason
    assert len(llm.calls) == 1


@pytest.mark.parametrize("note", ["sharp knee pain on rep four", "عندي ألم حاد في الركبة"])
def test_guardrail_bypasses_the_model(note):
    llm = FakeLLMClient([good()])
    card = run(svc(llm).coach(payload(), note, {}))
    assert card.source == "guardrail"
    assert llm.calls == []  # model never invoked
    assert card.next_set.action == "stop_exercise" and card.next_set.rest_seconds is None


@pytest.mark.parametrize("name", SCENARIOS)
def test_fallback_template_passes_every_check(name):
    p = payload(name)
    m = p.metric_values()
    card = fallback_card(p, m, rules.prescribe(p), "test")
    raw = json.dumps({"summary": card.summary, "focus_metric": card.focus_metric,
                      "cues": [{"text": c.text, "metric_ref": c.metric_ref} for c in card.cues]})
    validate_prescription(raw, p, m)  # must not raise


def test_fake_llm_default_output_passes_checks():
    for name in SCENARIOS:
        card = run(svc(FakeLLMClient()).coach(payload(name), None, {}))
        assert card.source == "llm", name


@pytest.mark.parametrize("name,action,rule_id,rest", [
    ("clean", "increase_load", "vl_well_below_cap", 90),
    ("fatigue", "reduce_load", "vl_cap_exceeded", 240),
    ("valgus", "reduce_load", "valgus_repeated", 180),
])
def test_rules_are_deterministic(name, action, rule_id, rest):
    n = rules.prescribe(payload(name))
    assert (n.action, n.rule_id, n.rest_seconds) == (action, rule_id, rest)


def test_validate_rejects_rep_numbers_out_of_range():
    p = payload("clean")  # 5 reps
    with pytest.raises(ContentRejected):
        validate_prescription(good(summary="Rep 7 was slow."), p, p.metric_values())
    validate_prescription(good(summary="Rep 4 was slow."), p, p.metric_values())


def test_gpu_jobs_never_overlap():
    sched = GpuScheduler()
    active, peak, order = 0, 0, []

    async def job(i):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0.01)
        order.append(i)
        active -= 1

    async def main():
        await asyncio.gather(*(sched.run(GpuJob(f"j{i}", lambda i=i: job(i))) for i in range(5)))

    asyncio.run(main())
    assert peak == 1 and sorted(order) == list(range(5)) and sched.completed_jobs == 5


def test_gpu_release_runs_even_when_job_fails():
    sched = GpuScheduler()
    released = []

    async def boom():
        raise RuntimeError("x")

    async def release():
        released.append(True)

    with pytest.raises(RuntimeError):
        asyncio.run(sched.run(GpuJob("boom", boom, release)))
    assert released == [True] and not sched.busy


def test_prescription_schema_matches_pydantic_base():
    base = CoachingPrescription.model_json_schema()
    narrowed = CoachingPrescription.format_schema(["mqs_score"])
    assert set(base["properties"]) == set(narrowed["properties"])
    assert narrowed["additionalProperties"] is False
