# MR-Fit 2.0 — Progress

Updated after every step. Decisions and assumptions live in [DECISIONS.md](DECISIONS.md).
Branch: `feat/mr-fit-2`.

## Status: 4 of 7 steps done; step 5 in progress (5a ✅, 5b ✅, Phase A toolchain ✅, 5c ⏭, 5d ⏳)

| # | Step | Status | Commit |
|---|---|---|---|
| 1 | Read report, inspect repo, plan | ✅ done | — (no repo changes) |
| 2 | Infrastructure: compose, requirements, Dockerfile, `.env.example`, archive cleanup | ✅ done | `9483e92` (+ `f316de1` v1 path fixes) |
| 3 | Database: Postgres/Timescale schema + Alembic migration of old tables | ✅ done | `58ebd17` |
| 4 | Backend: port routes, custom exercises, `/sets`, auth refresh, constrained coach, tests | ✅ done | `a18aae9` |
| 5a | Flutter skeleton, domain abstractions, Dart contract mirror | ✅ done | `7f11d79` |
| 5b | Seeded mocks (sensor, vision, time sync) + MetricsEngine + Isolate worker + golden tests | ✅ done | `73db396` |
| A | Phase A: install the Flutter/Android toolchain; analyze, test, build and run the 5a/5b code for real | ✅ done | `bdbc305` … `9a94364` (one commit per fix) |
| 5c | Data layer (API client, secure storage, drift+SQLCipher, retry queue) + ported screens (Auth, Track, Library+heatmap, Stats, Coach history) | ⏭ next | |
| 5d | 7-phase screens (Device Connect → Rest audit), HUD + skeleton overlay, haptics/TTS, foreground task, SIMULATED banner, debug switch | ⏳ | |
| 6 | Integration + scripted ~7-minute demo runner | ⏳ | |
| 7 | Final summary: real vs simulated, how to plug in real sensor/vision | ⏳ | |

## Exact next action

Step 5c (Phase B), first change: `mobile/lib/data/api/api_client.dart`. It's a dio client with a
Bearer interceptor and one refresh-on-401 retry, with tokens in `flutter_secure_storage` and the
backend URL from Settings. After that:
- the drift database (opened with a SQLCipher key from secure storage) with the sets retry queue
- the ported screens (Auth, Track, Library + heatmap, Stats, Coach history)

Run `flutter analyze` and `flutter test` after every checkpoint, and don't move on while either fails.
The app already runs on the emulator, as a placeholder home screen with the SIMULATED banner.

## Open questions / pending decisions

| Item | Default in use | Needed from |
|---|---|---|
| ROLE_BRIEFING not in the workspace; 7-phase timings unknown | D-017 placeholder timings (≈7 min) | User: paste briefing if exact timings matter |
| TimescaleDB 2.31 compression API fallback never run against a real server | D-023 dual-API PL/pgSQL fallback | User: run the opt-in online migration test, or allow running portable Postgres in the scratchpad |
| Next-set rule thresholds (rest, load changes) | D-036 placeholders | Coach / team validation |
| Medical guardrail keyword lists (EN + AR) | D-043 conservative lists | Review by a clinician (Arabic-speaking for the AR list) |
| MQS formula and thresholds | Placeholder `docs/MQS.md` in step 5, weights in config | Team validation |
| Sensor source / vision task / pose model / transport | Mocks (O-1…O-4) | Hardware decision |
| Gemini key committed in v1 history | Untracked; history not rewritten (D-002) | User rotates the key (confirmed) |
| Real deepseek-r1:1.5b output quality | Unknown; fallback covers failures | Run with Ollama and log the fallback rate |
| `flutter_tts` 4.2.5 applies the Kotlin Gradle Plugin; Flutter warns that future versions will refuse to build it | Builds today; already the latest version | Upstream plugin fix; re-check on each Flutter upgrade |
| Project lives in OneDrive: syncing `build/` briefly locked `build/unit_test_assets` (one `flutter test` failed with "failed to delete a directory"; it passed on re-run) | Re-run works | User: move the repo out of OneDrive, or pause sync while building |
| Second Flutter 3.50.1 SDK at `C:\Users\ASUS\flutter` (1.5 GB, installed by the VS Code extension); VS Code's Dart language server runs from it | Left alone; `C:\src\flutter` comes first on PATH | User: delete it, or point VS Code's `dart.flutterSdkPath` at `C:\src\flutter` |
| Memory: 15 GB RAM; emulator (≈4 GB) + Gradle + Chrome nearly used up the commit limit | D-057 heap sizes; the emulator was stopped during the first build | Close heavy apps while building, or enlarge the page file (user choice) |

## Verification log

### Phase A — Toolchain, first real analyze/test/build/run (2026-11-20)
Versions: Flutter 3.50.1 (stable, 2026-11-18) · Dart 3.14.0 · DevTools 2.61.0 · Android Studio 2026.2.2.10 ·
JBR (OpenJDK) 25.0.4 · SDK platform 36 + 37.0, build-tools 36.1.0, platform-tools 37.0.3, emulator 37.3.10,
NDK 28.2.13676358, CMake 3.22.1 · AGP 9.3.1 · Kotlin 2.4.20 · Gradle 9.5.0. Install details: D-055.

Verified (run here):
- **`flutter doctor -v`:** "No issues found!" Android toolchain ✓, all licenses accepted, emulator listed.
- **`flutter pub get`:** OK. 5 transitive packages have newer versions outside the constraints.
- **`dart run build_runner build`:** OK.
- **`flutter analyze`:** first run gave 1 error and 7 infos. Fixed (`2365182`, `54af0b2`, `af34e2d`, `6706715`, `6dbc3ce`). Now "No issues found!" No lints were disabled.
- **`flutter test`:** first run 34 passed, 2 failed (unknown enum values raised `FormatException`, not `ContractError`). The parser was fixed, not the tests (`d18b367`). Now **+36: All tests passed!**, including every MetricsEngine golden test with **unchanged tolerances** (D-062).
- **`flutter build apk --debug`:**
  - Failure 1: the Gradle wrapper download hung (D-058).
  - Failure 2: "Could not reserve virtual memory" during `compileFlutterBuildDebug` (D-057). There was also a compileSdk 37 warning (D-056).
  - After the fixes: **`√ Built build\app\outputs\flutter-apk\app-debug.apk`** (191 MB, 340 s).
- **On the emulator** (`mrfit_api36`, Android 16 / API 36, WHPX): `adb install` succeeded and the app launched in 9.4 s with no FATAL or Flutter errors in logcat. The screen shows "MR-Fit 2.0" and the amber **SIMULATED** banner.
- **Backend unchanged:** 167 passed, 1 skipped.

Not verified:
- Physical Android device (none connected); release build and signing.
- Runtime behaviour beyond the placeholder screen: the sensor/vision mocks, the Isolate worker and SQLCipher on a device. These get exercised once the 5c/5d screens use them.
- Exact numeric match with `engine_reference.py` (different RNGs; covered by the tolerances).

### Step 5a + 5b — Flutter domain, mocks, MetricsEngine
Verified (here, without Flutter):
- **Python tests on the Dart code:** 167 backend tests pass, 1 skipped. Python now checks the Dart `SetSummaryPayload` against the JSON Schema (every key present) and the Dart channel registry against `contracts/channels.v1.json`.
- **Package choices:** every pubspec version was checked against pub.dev (2026-11-20). The SQLCipher route follows the current `sqlite3` package docs (`sqlcipher_flutter_libs` is end-of-life). The `flutter_foreground_task` service class name was checked against its README.
- **Numerical design**, via `docs/validation/engine_reference.py`, a Python mirror of the mock and engine core:
  - IMU, 4 seeds × 3 scenarios: rep counts always right, faults always right, MPV ≤ 0.014 m/s, depth ≤ 3.1°, VL ≤ 2.6 points.
  - Push-up and deadlift (including the lumbar fault): correct.
  - Vision-only: rep counts and faults always right, MPV ≤ 0.045 m/s. VL is unreliable: the fatigue cap was crossed in only 4 of 6 seeds.
  - The mirror exposed a 13–25 % low bias in vision velocity, which led to the window-shrink fix (D-050).
- No hardware names outside `// REAL SLOT` files (grep).

Not verified:
- ~~No Dart code has been compiled, analyzed or run.~~ **Superseded by Phase A:** analyze is clean, 36/36 tests pass (golden tests included), and the debug APK builds and runs on the emulator.
- Dart's seeded `Random` sequence differs from Python's, so exact Dart outputs are unknown. The tolerances cover the spread seen across seeds.
- Isolate behaviour of `MetricsWorker` (written, not run).

### Step 4 — Backend
Verified (Python 3.14, pinned requirements, SQLite, FakeLLMClient, mocked HTTP for Ollama):
- **165 tests pass, 2 skipped** (the opt-in online Postgres test, and the Dart mirror test that waits for step 5).
- **Auth.** Signup and login, v1 password hashes still verify, refresh rotation, reuse detection revokes only the affected family, expiry and logout. Forged, expired, wrong-type and refresh-as-bearer tokens are all rejected, and only the SHA-256 of refresh tokens is stored.
- **Ported routes.** `/logs` CRUD with server-side volume, the v1 validators, per-user isolation, the v1 heatmap session-count rule, `/stats` totals and averages, and the 26-exercise library plus case-insensitive custom exercises per user.
- **`/sets`.**
  - Idempotent: 201 on create, 200 on replay, 409 on conflicting content; the mirror log row is not duplicated.
  - Contract violations get a 422.
  - Timeseries: duplicates are ignored within and across batches, phone-monotonic time is converted correctly (10 ms steps), and over-size batches get a 413.
  - Unknown channels (e.g. `esp32_raw_byte`), NaN values and timestamps without a timezone get a 422.
  - Skeleton batches work.
- **Coach.**
  - The guardrail fires on 12 English and 11 Arabic medical phrases and passes 8 normal notes (including «شد ظهر» and «العالم»).
  - The number checker accepts payload numbers at the precision written (including Arabic-Indic digits and number words) and rejects invented ones.
  - The `metric_ref` enum is narrowed to the set's own metrics, `<think>` blocks are stripped, and there is exactly one retry before the fallback.
  - Ollama-down goes straight to the fallback, and the guardrail bypasses the model completely.
  - The fallback template passes all checks for all three fixtures.
  - Rules give deterministic results for the three fixtures.
  - GPU jobs never overlap, the release hook runs even when a job fails, the model is unloaded after each call, coaching is idempotent, and the cooldown never blocks a safety referral.
- **Ollama client (mocked HTTP).**
  - The request uses `/api/chat` with `format` = the narrowed `CoachingPrescription` schema, `keep_alive "0"`, `temperature 0` and `stream false`.
  - The unload goes through `/api/generate` with `keep_alive 0`, and the `message.thinking` field is ignored.
  - HTTP and transport errors become `LLMError`.
- **Contracts.**
  - The committed JSON Schemas match the Pydantic models, and all three fixtures validate and round-trip.
  - The schema requires every field and forbids extras.
  - The channel registry contains no hardware names.
- **Live-server smoke test.** Ran real `uvicorn --factory` with `LLM_BACKEND=fake` and SQLite, then via curl: signup → `POST /sets` (201, replay 200) → coaching (`source: llm`, rule `valgus_repeated`) → a NaN upload returns 422. The server log had no errors.
- **Bug found and fixed.** FastAPI's default 422 handler crashed with a 500 on `NaN` input (D-040).

Not verified:
- Anything against real PostgreSQL/TimescaleDB (same as step 3): JSONB behaviour, `ON CONFLICT` on hypertables, `SELECT … FOR UPDATE` in refresh rotation.
- Real Ollama with `deepseek-r1:1.5b` (no Ollama/GPU here): whether the model follows the narrowed schema, how often it writes digits (which triggers the fallback), and latency on a GTX 1050 Ti.
- Real Gemini calls (module off by default; tested with an injected fake parser only).
- `docker compose up` with the new repo-root build context.

### Step 3 — Database
Verified: 43 tests (ORM constraints on SQLite; `alembic upgrade head --sql` DDL checked against the ORM for every table, column and index; Timescale statements use `TS_*` values; a mutation test was caught); `import_sqlite.py` dry-run on the real v1 DBs (9 users / 50 logs, 5 users / 18 logs).
Not verified: migrations on a real PostgreSQL/TimescaleDB server (running portable Postgres binaries was blocked). To verify:
`docker compose up -d timescaledb`, then `MRFIT_TEST_PG_URL=postgresql+psycopg://mrfit:<pw>@127.0.0.1:5432/<scratch_db> pytest -k online`.

### Step 2 — Infrastructure
Verified: requirements install on Python 3.14 and `pip check` passes; settings refuse an insecure `SECRET_KEY`, banned or unlisted models and a CORS wildcard; uvicorn factory boots; Docker image tags exist; `deepseek-r1:1.5b` = Q4_K_M digest; compose references resolve.
Not verified: `docker compose up`, image build, GPU passthrough, model pull.

### Step 1 — Plan
Read `mrfit_reverse_engineer.md` and every v1 source file. Report and code mismatches were recorded (13 routes, not 9; `mr_fit.env.md` missing; tracked secret and DB files; `/ai-coach` unused; library versions unverifiable).

## Files changed per step

### Phase A
- `mobile/android/**` (new: `flutter create` scaffold), `mobile/.gitignore`, `mobile/.metadata`, `mobile/pubspec.lock`, `mobile/analysis_options.yaml` (excludes from `flutter create`)
- `mobile/android/app/build.gradle.kts` (minSdk 26, compileSdk 37), `mobile/android/gradle.properties` (heap), `mobile/android/gradle/wrapper/gradle-wrapper.properties` (SHA-256 pin)
- `mobile/pubspec.yaml` (`material_ui`, SDK floor), `mobile/README.md`
- `mobile/lib/main.dart` (new), `mobile/lib/presentation/widgets/simulated_banner.dart` (new), `mobile/test/widget_test.dart` (new)
- Fixes: `mobile/lib/app/bindings.dart`, `mobile/lib/data/sensors/mock/mock_sensor_source.dart`, `mobile/lib/domain/metrics/metrics_worker.dart`, `mobile/lib/domain/contracts/set_summary_payload.dart`, `mobile/test/contract/set_summary_payload_test.dart`
- `docs/DECISIONS.md` (D-055…D-063), `docs/PROGRESS.md`

### Step 5b
- `mobile/lib/core/{clock,seeded_random}.dart`
- `mobile/lib/data/sensors/mock/{scenarios,mock_body,scenario_timeline,mock_world,mock_sensor_source}.dart`
- `mobile/lib/data/vision/mock/mock_vision_pipeline.dart`
- `mobile/lib/data/timesync/{mock_time_sync,tap_time_sync}.dart`
- `mobile/lib/domain/metrics/{metrics_config,pose_geometry,live_metrics,mqs,metrics_engine,metrics_worker}.dart`
- `mobile/lib/app/bindings.dart` (the single Mock/Real binding file)
- `mobile/test/data/mock_generators_test.dart`, `mobile/test/domain/metrics_engine_golden_test.dart`
- `docs/MQS.md` (new), `docs/validation/engine_reference.py` (new), `docs/DECISIONS.md` (D-044…D-054), `docs/PROGRESS.md`

### Step 5a
- `mobile/{pubspec.yaml,analysis_options.yaml,README.md}`, `mobile/android/app/src/main/AndroidManifest.xml`
- `mobile/lib/domain/{workout/workout_models,sensors/channels,sensors/sensor_models,sensors/sensor_source,vision/vision_models,vision/vision_pipeline,timesync/time_sync,contracts/set_summary_payload}.dart`
- `mobile/lib/features/food/domain/food_recognizer.dart`
- `mobile/lib/data/{sensors/real/real_sensor_source,vision/real/real_vision_pipeline}.dart` (REAL SLOT stubs)
- `mobile/test/contract/set_summary_payload_test.dart`, `backend/tests/test_contract.py` (Dart checks)
- `docs/ANDROID_PERMISSIONS.md` (new)

### Step 4
- **API:** `backend/app/api/{__init__,deps,auth,logs,exercises,sets,parse}.py`
- **Core:** `backend/app/core/{security,contracts}.py`
- **Schemas:** `backend/app/schemas/{__init__,auth,logs,exercises,set_summary,streams,coaching,sets}.py`
- **Services:** `backend/app/services/{__init__,gpu,rate_limit,context,sets_service,volume}.py`
- **Coach:** `backend/app/services/coach/{__init__,guardrail,numbers,rules,llm,service}.py`
- **Gemini (optional):** `backend/app/services/gemini_optional/{__init__,parser}.py`
- **Changed:** `backend/app/main.py` (routers, validation handler, DI), `backend/app/models/constants.py` (fault flags, VL caps)
- **Scripts:** `backend/scripts/export_contracts.py`
- **Contracts:** `contracts/{channels.v1,exercise_library.v1,set_summary.v1.schema,coaching_card.v1.schema,coaching_prescription.v1.schema}.json`, `contracts/fixtures/set_summary_{clean,fatigue,valgus}.json`
- **Tests:** `backend/tests/{__init__,conftest,test_guardrail,test_numbers,test_coach_service,test_ollama_client,test_api_auth,test_api_logs,test_api_sets,test_contract}.py`
- **Infrastructure:** `docker-compose.yml` (build context = repo root), `backend/Dockerfile`, `backend/.dockerignore` → `backend/Dockerfile.dockerignore`, `backend/pytest.ini`
- **Docs:** `docs/CONTRACT.md` (new), `docs/DECISIONS.md` (D-028…D-043), `docs/PROGRESS.md`, `README.md` (API section)

### Step 3
- `backend/app/core/config.py`, `backend/app/db/*`, `backend/app/models/*`, `backend/alembic*`, migrations 0001–0003, `backend/docker-entrypoint.sh`, `backend/scripts/import_sqlite.py`, tests for models/migrations/timescale/import, `docs/DECISIONS.md` (D-021…D-027), `docs/PROGRESS.md`, `README.md`

### Step 2
- Added the compose, Docker, requirements, `.env.example`, settings, health, `archive/README.md` and `docs/DECISIONS.md` files; moved v1 code to `archive/`; untracked `New folder/mr_fit.env`, the `.db` files and `__pycache__/`
