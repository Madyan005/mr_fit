# MetricsEngine definitions and the MQS placeholder

> **ASSUMPTION, needs validation.** No MQS formula or thresholds were supplied, so
> everything below is a documented placeholder. All numbers live in
> `mobile/lib/domain/metrics/metrics_config.dart`. Change them there; the engine code
> doesn't need to change.

The LLM never computes any of these. They come from `MetricsEngine`, which is pure Dart
and runs in an Isolate via `MetricsWorker`.

## Rep segmentation (vertical velocity, + = up)

| Step | Rule |
|---|---|
| Velocity source | `bar_vel_z` if the sensor offers it (`velocity_source = imu`). Otherwise it is derived from vision, from the tracked keypoints listed below (`vision`, flagged lower confidence). Otherwise there is none and all velocity metrics are `null` |
| Concentric start | v > 0.10 m/s, then the window is extended **back** to the last sample with v ≤ 0.015 (IMU) or ≤ 0.04 (vision), so the threshold doesn't bias the mean |
| Concentric end | v < 0.05, then extended **forward** to v ≤ the zero-cross value (or after a 0.3 s timeout) |
| Valid rep | duration ≥ 0.25 s and displacement ≥ min ROM (squat/deadlift 0.15 m, bench/push-up 0.08 m) |
| Mean velocity (IMU) | Mean *propulsive* velocity: the trapezoid mean over the window, up to the point where the bar decelerates faster than *g*. Acceleration is a finite difference over ≥ 50 ms |
| Mean velocity (vision) | Raw displacement of the tracked keypoints between the window ends pulled in by 2 frames, divided by the time between them. This undoes the widening caused by smoothing (5 frames) plus differencing |
| Tracked keypoints (vision velocity) | squat and push-up: shoulders; deadlift and bench: wrists. The scale is `visionMetersPerUnit = 2.25` (camera about 2 m away) |

## Per-rep vision metrics

Taken at the frame of maximum flexion between the previous rep's end and this rep's end.

| Metric | Definition |
|---|---|
| `peak_depth_deg` | Flexion of the primary joint = 180° − 2D angle. squat: hip-knee-ankle; deadlift: shoulder-hip-knee; bench and push-up: shoulder-elbow-wrist. Left/right mean |
| `valgus` | Squat/deadlift only: knee distance / ankle distance < 0.75 |
| `lumbar_flexion` | Squat/deadlift only: trunk lean (shoulder midpoint vs hip midpoint, measured from vertical) > 55° for squat, > 75° for deadlift. **This is a 2D proxy.** A single camera can't measure true spine flexion |
| `incomplete_rom` | Peak depth < 85° (squat), 60° (deadlift), 80° (bench, push-up) |
| `symmetry_index` | Mean over reps of \|L − R\| / mean(L, R) × 100 at the deepest frame |

## Set-level metrics

| Metric | Definition |
|---|---|
| `mpv_initial` | Fastest of the first two reps (a slow first rep is common) |
| `mpv_final` | Last rep |
| `velocity_loss_pct` | (mpv_initial − mpv_final) / mpv_initial × 100, rounded to 0.1 |
| `vl_cap_exceeded` | `velocity_loss_pct ≥ vl_cap_pct` (20 % max strength, 30 % hypertrophy) |
| Phase 5 cues | A rep with a fault → `FaultDetected` (tone + double buzz). VL ≥ cap → `FatigueCapReached`, sent once (tone + long buzz) |
| Phase 6 conclusion | The sensor reports `restingDwell` for > 2.0 s, **or** the 0.25 s moving mean of \|v\| stays < 0.03 m/s for > 2.0 s, after at least one rep → `SetConcluded` |

## MQS (0–100), placeholder

`MQS = Σ wᵢ·sᵢ / Σ wᵢ` over the sub-scores that can be computed. Sub-scores that can't
be computed are `null` in `mqs_breakdown` and their weight is dropped.

| Sub-score | Weight | Formula | Needs |
|---|---|---|---|
| `rom` | 0.30 | mean over reps of min(1, depth / target) × 100. Targets: squat 90°, deadlift 75°, bench 85°, push-up 85° | vision |
| `stability` | 0.30 | 100 × (1 − (0.6 × valgus reps + 1.0 × lumbar reps) / reps) | vision |
| `tempo` | 0.10 | 100 − 200 × CV(concentric durations) | ≥ 2 reps |
| `velocity` | 0.15 | 100 − 50 × max(0, VL) / cap (VL at the cap scores 50) | velocity |
| `symmetry` | 0.15 | 100 − 5 × symmetry_index | vision |

## Validation status

- **Dart:** golden tests in `mobile/test/domain/metrics_engine_golden_test.dart` cover the
  three demo scenarios, deadlift, push-up, the degraded modes (no IMU, no vision, neither)
  and the Isolate worker. **They have not been run** (no Flutter SDK on the build machine).
- **Python mirror:** `docs/validation/engine_reference.py` (stdlib only) mirrors the mock
  and the segmentation/pose logic. It was used to pick the test tolerances. Over seeds 42,
  7, 123 and 2026, with IMU:
  - rep counts were always correct and faults always matched
  - worst error: MPV 0.014 m/s, depth 3.1°, VL 2.6 points against the fixtures
  - vision-only (seeds 42, 7, 123, 2026, 99, 5): rep counts and faults always correct, worst
    MPV error 0.045 m/s after the window-shrink correction (it was 0.13 before)
- **Vision-only VL is unreliable.** The fatigue set (true 24.4 %) read 12.2–29.7 % and
  crossed the 20 % cap in only 4 of 6 seeds. That's why vision velocity is flagged lower
  confidence, and why the HUD should treat the cap cue as advisory in that mode.
- **Real-world accuracy:** unknown. The mock was designed to agree with the engine; real
  sensors and real pose models need their own validation.
