# Contracts (phone ⇄ API)

Single source of truth: the Pydantic models in `backend/app/schemas/`. JSON Schemas in
`contracts/` are generated from them and committed; tests fail if they drift.

```bash
cd backend
python -m scripts.export_contracts           # regenerate after changing a model
python -m scripts.export_contracts --check   # CI: exit 1 if out of date
```

| File | Purpose |
|---|---|
| `contracts/set_summary.v1.schema.json` | `SetSummaryPayload` — `POST /sets` body |
| `contracts/coaching_card.v1.schema.json` | `CoachingCard` — `POST /sets/{id}/coaching` response, stored in `biomechanical_sets.slm_coaching_json` |
| `contracts/coaching_prescription.v1.schema.json` | `CoachingPrescription` — the only thing the SLM may produce |
| `contracts/channels.v1.json` | Registry of `SensorSample.channel` names (API rejects unknown names) |
| `contracts/exercise_library.v1.json` | The 26 v1 built-in exercises + `biomech_key` for the 4 biomechanics exercises |
| `contracts/fixtures/set_summary_{clean,fatigue,valgus}.json` | Golden payloads (one per demo scenario), used by Python and Dart tests |

The Dart mirror lives at `mobile/lib/domain/contracts/set_summary_payload.dart` (step 5).
`backend/tests/test_contract.py` checks that every schema key appears in it (text-level,
so it runs without a Dart SDK); the Dart tests parse the same fixtures.

## SetSummaryPayload v1.0.0

Rules:
1. **Unknown fields are rejected** (`additionalProperties: false`).
2. **Every field is required.** Optional metrics are *nullable*: send `null` when a value
   could not be measured. The server never fills in or guesses a value.
3. **Consistency is enforced:**
   - `len(per_rep) == reps_completed`
   - `rep_index` runs 1..n in order
   - `fault_counts` equals the tally of `per_rep[].fault_flags`
   - `vl_cap_exceeded == (velocity_loss_pct >= vl_cap_pct)`, and it is `false` when `velocity_loss_pct` is null
   - `ended_at >= started_at`
4. `set_id` is a UUID generated on the phone. `POST /sets` is idempotent: an identical
   replay returns `200` with the stored row; the same `set_id` with different content
   returns `409`.

| Field | Type | Notes |
|---|---|---|
| `schema_version` | `"1.0.0"` | const |
| `set_id` | UUID | phone-generated |
| `exercise` | `squat \| deadlift \| bench_press \| push_up` | |
| `goal` | `max_strength \| hypertrophy` | default caps 20 % / 30 % |
| `vl_cap_pct` | number (0, 100] | cap used for this set |
| `set_index` | int ≥ 1 | |
| `reps_completed` | int 0..200 | |
| `load_kg` | number \| null | *added beyond the minimum list*; enables the v1 volume mirror |
| `per_rep[]` | `{rep_index, peak_depth_deg?, mean_velocity_m_s?, fault_flags[]}` | `fault_flags` ⊆ `valgus, lumbar_flexion, incomplete_rom` |
| `mpv_initial`, `mpv_final` | m/s \| null | mean propulsive velocity |
| `velocity_loss_pct` | number \| null | |
| `vl_cap_exceeded` | bool | |
| `velocity_source` | `imu \| vision \| fused` \| null | *added*: `vision` = derived from pose, lower confidence |
| `mqs_score` | 0..100 \| null | formula: `docs/MQS.md` (ASSUMPTION) |
| `mqs_breakdown` | `{name: 0..100 \| null}` \| null | named sub-scores |
| `symmetry_index` | number \| null | |
| `fault_counts` | `{valgus, lumbar_flexion, incomplete_rom}` ints | |
| `data_source` | `simulated \| real` | set by the app from the active bindings |
| `device_labels` | string[1..8] | e.g. `MockSensorSource` |
| `started_at`, `ended_at` | ISO 8601 \| null | *added* |

The fixture values are illustrative. They are internally consistent but were not
produced by the MetricsEngine, which arrives in step 5.

## Metric references (coaching)

The coach refers to numbers only by key, using these forms:
- `velocity_loss_pct`, `mpv_initial`, `mpv_final`, `mqs_score`, `symmetry_index`, `vl_cap_pct`, `set_index`, `reps_completed`, `load_kg`
- `fault_counts.<flag>`
- `mqs_breakdown.<name>`
- `per_rep.<n>.peak_depth_deg`, `per_rep.<n>.mean_velocity_m_s`

Only keys whose value is non-null in that set are offered to the model (the JSON-schema
enum is narrowed per request). The card's `metric_value` / `focus_value` are looked up
from the payload by key.

## Streams

`POST /sets/{id}/timeseries` and `/skeleton` take a batch with one clock `anchor`
(`{t_mono_ns, wall_time (timezone required)}`). Each sample or frame carries a phone-monotonic
`t_mono_ns`. The server stores `time = wall_time + (t_mono_ns − anchor.t_mono_ns)`
(microsecond resolution). The size limits come from `MAX_TIMESERIES_BATCH` and `MAX_SKELETON_BATCH`.
Resends are no-ops thanks to the primary keys plus `ON CONFLICT DO NOTHING`. The response is
`{received, inserted, duplicates}`.
