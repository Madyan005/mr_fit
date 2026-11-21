# MR-Fit 2.0: final summary

State on 2026-11-21, end of the 7-step build on branch `feat/mr-fit-2`. Details per step
are in [PROGRESS.md](PROGRESS.md), every choice and assumption in
[DECISIONS.md](DECISIONS.md).

**In one paragraph.** MR-Fit 2.0 is a Flutter Android app with a FastAPI backend. The app
guides a lifter through a 7-phase velocity-tracked session, measures each set (reps, bar
velocity, velocity loss, movement quality, faults), saves it on the phone in an encrypted
database first, uploads it through a retry queue, and shows a coaching card from a
constrained local language model. The ported v1 screens (Track, Library with heatmap, Stats,
Coach) work against the same backend. **The sensor and the camera pose model are
simulated**: the hardware is not chosen yet. Every simulated part is labelled on screen
and in the data.

## Real vs simulated

| Part | Status | Where | Labelled how |
|---|---|---|---|
| Motion sensor | **Simulated** (`MockSensorSource`, 100 Hz, three scripted demo sets). Real: REAL SLOT, not implemented | `mobile/lib/data/sensors/` | SIMULATED banner; device "MockSensorSource (SIMULATED)"; `data_source: "simulated"` on every set |
| Pose / camera | **Simulated** (`MockVisionPipeline`, COCO-17 stick figure, no camera image). Real: REAL SLOT | `mobile/lib/data/vision/` | "SIMULATED POSE" on the skeleton; banner; `data_source` |
| Clock sync (3 taps) | **Real algorithm** (`TapTimeSync`), fed by simulated taps; it measures the mock's 37 ms clock lead (41 ms, 2 ms spread on the emulator) | `mobile/lib/data/timesync/` | — |
| Metrics engine (reps, velocity loss, MQS, faults) | **Real code**, tested on simulated data only. MQS formula and fault thresholds are placeholders (D-051, D-053) | `mobile/lib/domain/metrics/` | — |
| Spoken cues, vibration, foreground service | **Real code**; on the emulator the service ran, but no sound or vibration was checked | `mobile/lib/data/feedback/` | — |
| Encrypted local DB + upload queue | **Real** (SQLCipher, key in the Android Keystore) | `mobile/lib/data/local/`, `data/sync/` | — |
| Backend API, auth, sets, logs, library | **Real** (FastAPI). Run on SQLite in tests; never on PostgreSQL/TimescaleDB | `backend/app/` | — |
| Coach model | **Real pipeline** (medical guardrail → `deepseek-r1:1.5b` via Ollama → schema and number checks → rule-based fallback), but **only ever run with the fake model** (`LLM_BACKEND=fake`) | `backend/app/services/coach/` | Card badge names the model: "AI coach (local model · fake-llm)" |
| Next-set advice (rest, load change) | **Real rules table**, placeholder numbers (D-036) | `backend/app/services/coach/rules.py` | — |
| Gemini text parsing | **Optional, off** by default; tested with a fake parser only | `backend/app/services/gemini_optional/` | `503` when off |
| Food recognition | **Mock only** (`MockFoodRecognizer`), isolated, not in the UI | `mobile/lib/features/food/` | "(SIMULATED)" in its label |
| Scripted demo | **Real**: plays the session itself in Mock mode | `mobile/lib/app/session/demo_runner.dart` | Narration bar |

## Architecture

```
 Phone (Flutter)                                                     PC / server
 ┌───────────────────────────────────────────────────────────┐      ┌──────────────────────────────┐
 │ presentation/  Track · Library · Stats · Coach · Session  │      │ FastAPI (backend/app)        │
 │        │ Riverpod                                         │      │  auth · logs · library       │
 │ app/session/   SessionController (7 phases) ◄── DemoRunner│      │  POST /sets (idempotent)     │
 │        │                                                  │      │  POST /sets/{id}/coaching    │
 │ domain/        MetricsEngine (isolate) · contract         │ HTTP │    guardrail → Ollama SLM    │
 │        │ interfaces only                                  │ ───► │    → checks → rules fallback │
 │ app/bindings.dart  ── THE one Mock/Real binding ──        │      │ PostgreSQL + TimescaleDB     │
 │   Mock: MockSensorSource · MockVisionPipeline · TapTimeSync│      │ Ollama deepseek-r1:1.5b      │
 │   Real: REAL SLOT sensor · REAL SLOT pose (not built)     │      │ (docker compose; not run)    │
 │ data/   SQLCipher DB → outbox retry queue → dio client ───┼──────┘                              │
 └───────────────────────────────────────────────────────────┘      └──────────────────────────────┘
```

## Plugging in the real sensor and vision

Short version: implement the two REAL SLOT classes, add them to the contract tests, change
the Real list in `mobile/lib/app/bindings.dart`. No UI, engine or backend change for the
data. Two exceptions to know up front:

- **Camera.** There is no camera code yet: the session sends empty frames on a timer, so
  the real pose pipeline must open the camera itself.
- **Preview.** Showing the live camera image behind the skeleton is a UI addition.

Step-by-step, with what the session needs from each slot:
[INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md).

## Running the demo

1. **Backend.** The supported way is `docker compose up` (root [README](../README.md)). For a
   demo without a GPU, set `COMPOSE_PROFILES=` and `LLM_BACKEND=fake` in `.env`. **This
   stack has never been run** (Docker is not installed on the build PC). The emulator
   checks below used a throwaway script instead: the same FastAPI app on SQLite with the
   fake model. That script is not in the repo.
2. **App.** `cd mobile && flutter run` on an emulator (Mock mode is the default). On the
   sign-in screen set the backend URL (`http://10.0.2.2:8000` from the emulator), sign up.
3. **Demo.** Session tab → **Run scripted demo**. It runs 6:40 with narration:
   - Phases 1–4: connect, exercise and goal, camera position, three-tap calibration.
   - Set 1, clean squat.
   - Set 2, bench press that crosses its velocity-loss limit (long buzz, "Rack the bar").
   - Set 3, squat with knees caving in (red skeleton, "Knees out.").

   Each set ends on a rest view with the upload status and the coaching card. **Take
   over** hands control back to you; afterwards the Coach tab lists the three cards.

## What was verified, and what was not

Verified by running it:

- **Tests:**
  - Backend: 167 passed, 1 skipped (the TimescaleDB test needs a server).
  - App: `flutter analyze` clean, 130 passed, 1 skipped (the opt-in live-server test).
  - Metrics engine: golden tests against the three contract fixtures.
- **On the Android 16 emulator** (debug build, local API with the fake model):
  - sign-in, all ported screens, the 7 phases by hand and the full scripted demo;
  - the demo finished at 6:40.0, all three sets uploaded and coached, no app errors;
  - the foreground service ran during the session.
- **Opt-in client test** against the live local API: auth with refresh-token rotation, logs,
  library, stats, set upload, idempotent resend, coaching.

Not verified:

- **Real hardware**: no real sensor, camera or pose model exists yet. All thresholds
  (tap spike, framing score, fault angles, MQS weights) were tuned on simulated data.
- **The docker compose stack**: PostgreSQL/TimescaleDB migrations, the real
  `deepseek-r1:1.5b` model on Ollama, GPU passthrough. The coach has never produced a real
  model answer, so its quality and fallback rate are unknown.
- **A physical phone**: sound, vibration, screen-off streaming, battery use, the real
  permission dialogs.
- **Gemini**: never called (module off; key handling only).

## Open decisions

The full list, with defaults in use, is in PROGRESS.md under "Open questions". The ones that
block real use:

| Decision | Who |
|---|---|
| Sensor hardware, pose model and transport (O-1…O-4) | Team |
| Rest/load rules, MQS formula, guardrail word lists (EN + AR) | Coach / clinician review |
| Install Docker (admin + WSL2) to verify the full stack, or run it on another machine | User |
| Rotate the Gemini key that is in the v1 git history (D-002) | User (agreed) |
| Move the repo out of OneDrive (file locks broke builds twice) | User |

## Document map

| Document | For |
|---|---|
| [README.md](../README.md), [mobile/README.md](../mobile/README.md) | Running the backend and the app |
| [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) | Replacing the mocks with hardware |
| [CONTRACT.md](CONTRACT.md) | `SetSummaryPayload` and the coaching card |
| [MQS.md](MQS.md) | Movement-quality score (placeholder) |
| [ANDROID_PERMISSIONS.md](ANDROID_PERMISSIONS.md) | Permissions and the foreground service |
| [DECISIONS.md](DECISIONS.md) | Every decision and assumption (D-001…D-086, O-1…O-5) |
| [PROGRESS.md](PROGRESS.md) | Step log, verification per step, open questions |
