from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import BiomechanicalSet, Log, SensorTimeseries, SkeletonFrame
from app.services.coach.llm import FakeLLMClient
from tests.conftest import auth_headers, fixture_payload, signup

ANCHOR = {"t_mono_ns": 1_000_000_000, "wall_time": "2026-11-20T10:00:00Z"}


def _post_set(client, h, name="clean", **over):
    return client.post("/sets", json={**fixture_payload(name), **over}, headers=h)


def test_post_set_is_idempotent(client, user_headers, engine):
    r1 = _post_set(client, user_headers)
    assert r1.status_code == 201
    r2 = _post_set(client, user_headers)  # mobile retry queue resend
    assert r2.status_code == 200 and r2.json()["set_id"] == r1.json()["set_id"]
    changed = _post_set(client, user_headers, mqs_score=10.0)
    assert changed.status_code == 409
    with Session(engine) as s:
        assert s.scalar(select(func.count()).select_from(BiomechanicalSet)) == 1
        assert s.scalar(select(func.count()).select_from(Log)) == 1  # mirror row, not duplicated


def test_mirror_log_feeds_v1_stats(client, user_headers):
    _post_set(client, user_headers)
    logs = client.get("/logs", headers=user_headers).json()
    assert logs[0]["name"] == "Squat" and logs[0]["reps"] == 5 and logs[0]["volume"] == 400.0


def test_contract_violations_rejected(client, user_headers):
    base = fixture_payload("clean")
    bad_cases = [
        {**base, "unknown_field": 1},
        {k: v for k, v in base.items() if k != "mqs_score"},     # optional metric omitted, not null
        {**base, "exercise": "bicep_curl"},
        {**base, "schema_version": "2.0.0"},
        {**base, "vl_cap_exceeded": True},                       # inconsistent with 11.3 < 30
        {**base, "reps_completed": 4},                           # != len(per_rep)
        {**base, "fault_counts": {"valgus": 1, "lumbar_flexion": 0, "incomplete_rom": 0}},
        {**base, "data_source": "guess"},
    ]
    for body in bad_cases:
        assert client.post("/sets", json=body, headers=user_headers).status_code == 422


def test_null_metrics_are_accepted(client, user_headers):
    body = {**fixture_payload("clean"), "mqs_score": None, "mqs_breakdown": None,
            "symmetry_index": None, "velocity_source": None}
    assert client.post("/sets", json=body, headers=user_headers).status_code == 201


def test_sets_are_private(client, user_headers):
    set_id = _post_set(client, user_headers).json()["set_id"]
    other = auth_headers(signup(client, "other@test.dev"))
    assert client.get(f"/sets/{set_id}", headers=other).status_code == 404
    assert _post_set(client, other).status_code == 409  # same set_id, other athlete
    assert client.get("/sets", headers=other).json()["items"] == []
    batch = {"anchor": ANCHOR, "samples": [{"channel": "accel_x", "value": 1, "t_mono_ns": 1, "source": "m"}]}
    assert client.post(f"/sets/{set_id}/timeseries", json=batch, headers=other).status_code == 404


def test_list_and_get(client, user_headers):
    for n in ("clean", "fatigue", "valgus"):
        _post_set(client, user_headers, n)
    items = client.get("/sets", headers=user_headers).json()["items"]
    assert len(items) == 3
    squats = client.get("/sets?exercise=squat", headers=user_headers).json()["items"]
    assert {i["payload"]["exercise"] for i in squats} == {"squat"} and len(squats) == 2
    page = client.get("/sets?limit=2", headers=user_headers).json()
    assert len(page["items"]) == 2 and page["next_before"] is not None


def test_timeseries_batch_idempotent_and_time_converted(client, user_headers, engine):
    set_id = _post_set(client, user_headers).json()["set_id"]
    samples = [{"channel": "bar_vel_z", "value": 0.1 * i, "t_mono_ns": 1_000_000_000 + i * 10_000_000,
                "source": "MockSensorSource"} for i in range(100)]
    samples.append(dict(samples[0]))  # duplicate inside one batch
    r = client.post(f"/sets/{set_id}/timeseries", json={"anchor": ANCHOR, "samples": samples}, headers=user_headers)
    assert r.json() == {"received": 101, "inserted": 100, "duplicates": 1}
    again = client.post(f"/sets/{set_id}/timeseries", json={"anchor": ANCHOR, "samples": samples}, headers=user_headers)
    assert again.json()["inserted"] == 0  # resend is a no-op
    with Session(engine) as s:
        times = sorted(s.scalars(select(SensorTimeseries.time)))
    assert len(times) == 100
    assert times[0].replace(tzinfo=timezone.utc) == datetime(2026, 11, 20, 10, 0, tzinfo=timezone.utc)
    assert (times[1] - times[0]).total_seconds() == 0.01  # 10 ms apart (100 Hz)


def test_timeseries_limits_and_registry(app_factory):
    with TestClient(app_factory(max_timeseries_batch=10)) as c:
        h = auth_headers(signup(c))
        set_id = c.post("/sets", json=fixture_payload("clean"), headers=h).json()["set_id"]
        s = {"channel": "accel_x", "value": 1.0, "t_mono_ns": 1, "source": "m"}
        too_many = [dict(s, t_mono_ns=i) for i in range(11)]
        assert c.post(f"/sets/{set_id}/timeseries", json={"anchor": ANCHOR, "samples": too_many}, headers=h).status_code == 413
        unknown = [dict(s, channel="esp32_raw_byte")]
        r = c.post(f"/sets/{set_id}/timeseries", json={"anchor": ANCHOR, "samples": unknown}, headers=h)
        assert r.status_code == 422 and "esp32_raw_byte" in r.text
        nan = '{"anchor": %s, "samples": [{"channel": "accel_x", "value": NaN, "t_mono_ns": 1, "source": "m"}]}' % json.dumps(ANCHOR)
        assert c.post(f"/sets/{set_id}/timeseries", content=nan, headers={**h, "Content-Type": "application/json"}).status_code == 422
        naive = {"anchor": {"t_mono_ns": 0, "wall_time": "2026-11-20T10:00:00"}, "samples": [s]}
        assert c.post(f"/sets/{set_id}/timeseries", json=naive, headers=h).status_code == 422


def test_skeleton_batch(client, user_headers, engine):
    set_id = _post_set(client, user_headers).json()["set_id"]
    kp = [{"x": 0.5, "y": 0.5, "confidence": 0.9}] * 17
    frames = [{"t_mono_ns": 1_000_000_000 + i * 33_333_333, "rep_index": 1, "keypoints": kp} for i in range(30)]
    r = client.post(f"/sets/{set_id}/skeleton", json={"anchor": ANCHOR, "frames": frames}, headers=user_headers)
    assert r.json() == {"received": 30, "inserted": 30, "duplicates": 0}
    with Session(engine) as s:
        assert len(s.scalars(select(SkeletonFrame)).first().keypoints) == 17
    bad = [{"t_mono_ns": 1, "keypoints": [{"x": 0, "y": 0, "confidence": 1.5}]}]
    assert client.post(f"/sets/{set_id}/skeleton", json={"anchor": ANCHOR, "frames": bad},
                       headers=user_headers).status_code == 422


def test_coaching_endpoint_llm_then_cached(client, user_headers, fake_llm):
    set_id = _post_set(client, user_headers, "fatigue").json()["set_id"]
    r = client.post(f"/sets/{set_id}/coaching", json={}, headers=user_headers)
    assert r.status_code == 200
    card = r.json()
    assert card["source"] == "llm" and card["next_set"]["rule_id"] == "vl_cap_exceeded"
    assert card["focus_value"] == 24.4
    again = client.post(f"/sets/{set_id}/coaching", json={}, headers=user_headers).json()
    assert again["generated_at"] == card["generated_at"] and len(fake_llm.calls) == 1  # no second LLM run
    stored = client.get(f"/sets/{set_id}", headers=user_headers).json()
    assert stored["coaching_source"] == "llm" and stored["coaching"]["summary"] == card["summary"]


def test_coaching_guardrail_via_api(client, user_headers, fake_llm):
    set_id = _post_set(client, user_headers).json()["set_id"]
    r = client.post(f"/sets/{set_id}/coaching",
                    json={"athlete_note": "I have a herniated disc", "force_regenerate": True}, headers=user_headers)
    assert r.json()["source"] == "guardrail" and fake_llm.calls == []


def test_coaching_rate_limited_but_never_for_safety(app_factory):
    with TestClient(app_factory(llm=FakeLLMClient(), ai_cooldown_seconds=60)) as c:
        h = auth_headers(signup(c))
        ids = [c.post("/sets", json=fixture_payload(n), headers=h).json()["set_id"] for n in ("clean", "fatigue")]
        assert c.post(f"/sets/{ids[0]}/coaching", json={}, headers=h).status_code == 200
        assert c.post(f"/sets/{ids[1]}/coaching", json={}, headers=h).status_code == 429
        safety = c.post(f"/sets/{ids[1]}/coaching", json={"athlete_note": "ألم حاد في الركبة"}, headers=h)
        assert safety.status_code == 200 and safety.json()["source"] == "guardrail"


def test_coaching_falls_back_when_model_misbehaves(app_factory):
    llm = FakeLLMClient(["Your velocity loss of 99% means rest 300 s"])
    with TestClient(app_factory(llm=llm)) as c:
        h = auth_headers(signup(c))
        set_id = c.post("/sets", json=fixture_payload("valgus"), headers=h).json()["set_id"]
        card = c.post(f"/sets/{set_id}/coaching", json={}, headers=h).json()
        assert card["source"] == "fallback" and len(llm.calls) == 2
        assert any(cue["metric_ref"] == "fault_counts.valgus" and cue["metric_value"] == 2 for cue in card["cues"])


def test_parse_entry_disabled_by_default(client, user_headers):
    r = client.post("/parse-entry", json={"text": "bench 3x10 60kg"}, headers=user_headers)
    assert r.status_code == 503 and "GEMINI_ENABLED" in r.json()["detail"]


def test_parse_entry_with_injected_parser(app_factory):
    class FakeParser:
        def raw_parse(self, prompt: str) -> str:
            assert "bench 3x10 60kg" in prompt
            return json.dumps([{"type": "EXERCISE", "name": "Bench Press", "sets": 1, "reps": 10, "weight": 60}] * 3
                              + [{"type": "BOGUS", "name": "x"}])

    with TestClient(app_factory(text_parser=FakeParser())) as c:
        h = auth_headers(signup(c))
        items = c.post("/parse-entry", json={"text": "bench 3x10 60kg"}, headers=h).json()
        assert len(items) == 3 and items[0]["volume"] == 600.0  # invalid item skipped, volume server-side


def test_health_reports_modes(client):
    assert client.get("/health").json() == {"status": "ok", "version": "2.0.0-dev",
                                            "llm_backend": "fake", "gemini_enabled": False}
