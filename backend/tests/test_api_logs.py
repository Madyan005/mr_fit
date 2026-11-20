"""Ported v1 routes: /logs, /logs/heatmap, /stats, plus the exercise library."""
from __future__ import annotations

from datetime import datetime, timezone

from tests.conftest import auth_headers, signup


def _log(client, h, **kw):
    body = {"type": "EXERCISE", "name": "Squat", "sets": 1, "reps": 5, "weight": 100.0, "raw_text": "squat"}
    body.update(kw)
    r = client.post("/logs", json=body, headers=h)
    assert r.status_code == 201, r.text
    return r.json()


def test_create_recomputes_volume_server_side(client, user_headers):
    row = _log(client, user_headers, volume=999999)
    assert row["volume"] == 500.0  # 1 * 5 * 100, client value ignored (v1 rule)
    food = _log(client, user_headers, type="NUTRITION", name="Salad", sets=None, reps=None,
                weight=None, calories=300)
    assert food["volume"] is None and food["calories"] == 300


def test_validation_ported_from_v1(client, user_headers):
    for bad in ({"type": "CARDIO"}, {"reps": 0}, {"weight": -1}, {"calories": -5}, {"unknown": 1}):
        body = {"type": "EXERCISE", "name": "Squat", "raw_text": "", **bad}
        assert client.post("/logs", json=body, headers=user_headers).status_code == 422, bad


def test_list_filter_update_delete(client, user_headers):
    a = _log(client, user_headers)
    today = datetime.now(timezone.utc).date().isoformat()
    assert [x["id"] for x in client.get(f"/logs?date={today}", headers=user_headers).json()] == [a["id"]]
    assert client.get("/logs?date=2001-01-01", headers=user_headers).json() == []
    assert client.get("/logs?date=not-a-date", headers=user_headers).status_code == 422

    up = client.put(f"/logs/{a['id']}", json={"reps": 8}, headers=user_headers).json()
    assert up["reps"] == 8 and up["volume"] == 800.0
    assert client.delete(f"/logs/{a['id']}", headers=user_headers).json() == {"status": "deleted"}
    assert client.delete(f"/logs/{a['id']}", headers=user_headers).status_code == 404


def test_users_cannot_touch_each_others_logs(client):
    a = auth_headers(signup(client, "a@test.dev"))
    b = auth_headers(signup(client, "b@test.dev"))
    row = _log(client, a)
    assert client.get("/logs", headers=b).json() == []
    assert client.put(f"/logs/{row['id']}", json={"reps": 1}, headers=b).status_code == 404
    assert client.delete(f"/logs/{row['id']}", headers=b).status_code == 404


def test_heatmap_counts_sessions_like_v1(client, user_headers):
    _log(client, user_headers, session_id="s1")
    _log(client, user_headers, session_id="s1")
    _log(client, user_headers, session_id="s2")
    _log(client, user_headers)  # ungrouped
    data = client.get("/logs/heatmap", headers=user_headers).json()
    (day,) = data.values()
    assert day["count"] == 3 and len(day["details"]) == 4


def test_stats_shape_and_totals(client, user_headers):
    _log(client, user_headers)
    _log(client, user_headers, type="NUTRITION", name="Rice", sets=None, reps=None, weight=None, calories=700)
    s = client.get("/stats?days=7", headers=user_headers).json()
    assert len(s["days"]) == 7 and s["days"][-1]["volume"] == 500.0 and s["days"][-1]["calories"] == 700
    assert (s["total_workouts"], s["total_meals"]) == (1, 1)
    assert s["avg_volume"] == round(500 / 7) and s["avg_calories"] == 100
    assert client.get("/stats?days=0", headers=user_headers).status_code == 422


def test_exercise_library_builtin_and_custom(client, user_headers):
    lib = client.get("/exercises", headers=user_headers).json()
    assert len(lib["exercises"]) == 26
    assert {e["biomech_key"] for e in lib["exercises"]} - {None} == {"squat", "deadlift", "bench_press", "push_up"}

    body = {"name": "  Zercher   Squat ", "muscle": "Legs", "equipment_type": "Barbell"}
    r = client.post("/exercises/custom", json=body, headers=user_headers)
    assert r.status_code == 201 and r.json()["name"] == "Zercher Squat" and r.json()["custom"]
    assert client.post("/exercises/custom", json={**body, "name": "zercher squat"}, headers=user_headers).status_code == 409
    assert client.post("/exercises/custom", json={**body, "name": "BENCH PRESS"}, headers=user_headers).status_code == 409
    assert client.post("/exercises/custom", json={**body, "muscle": "Neck"}, headers=user_headers).status_code == 422
    assert len(client.get("/exercises", headers=user_headers).json()["exercises"]) == 27

    other = auth_headers(signup(client, "other@test.dev"))
    assert len(client.get("/exercises", headers=other).json()["exercises"]) == 26  # per-user
    assert client.delete(f"/exercises/custom/{r.json()['id']}", headers=other).status_code == 404
    assert client.delete(f"/exercises/custom/{r.json()['id']}", headers=user_headers).status_code == 200
