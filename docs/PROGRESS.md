# MR-Fit 2.0 — Progress

Updated after every step. Decisions and assumptions live in [DECISIONS.md](DECISIONS.md).
Branch: `feat/mr-fit-2`.

## Status: 6 of 7 steps done; step 7 (final summary) next

| # | Step | Status | Commit |
|---|---|---|---|
| 1 | Read report, inspect repo, plan | ✅ done | — (no repo changes) |
| 2 | Infrastructure: compose, requirements, Dockerfile, `.env.example`, archive cleanup | ✅ done | `9483e92` (+ `f316de1` v1 path fixes) |
| 3 | Database: Postgres/Timescale schema + Alembic migration of old tables | ✅ done | `58ebd17` |
| 4 | Backend: port routes, custom exercises, `/sets`, auth refresh, constrained coach, tests | ✅ done | `a18aae9` |
| 5a | Flutter skeleton, domain abstractions, Dart contract mirror | ✅ done | `7f11d79` |
| 5b | Seeded mocks (sensor, vision, time sync) + MetricsEngine + Isolate worker + golden tests | ✅ done | `73db396` |
| A | Phase A: install the Flutter/Android toolchain; analyze, test, build and run the 5a/5b code for real | ✅ done | `bdbc305` … `9a94364` (one commit per fix) |
| 5c | Data layer (API client, secure storage, drift+SQLCipher, retry queue) + ported screens (Auth, Track, Library+heatmap, Stats, Coach history) | ✅ done | `d0b6e26` … `4b838a6` (7 checkpoints + live test) |
| 5d | 7-phase screens (Device Connect → Rest audit), HUD + skeleton overlay, haptics/TTS, foreground task, SIMULATED banner, debug switch | ✅ done | `2aa9411` … `e68d608` |
| 6 | Integration + scripted ~7-minute demo runner | ✅ done (Docker stack not run: Docker not installed) | `0372333`, `2c00718` |
| 7 | Final summary: real vs simulated, how to plug in real sensor/vision | ⏭ next | |

## Exact next action

Step 7, the final summary (`docs/FINAL_SUMMARY.md`, no code changes):
- what is real and what is simulated, per component (sensor, vision, time sync, coach model, Gemini);
- how to plug in the real sensor and vision: the REAL SLOT files, the one binding to change
  (`mobile/lib/app/bindings.dart`), and what each slot must deliver;
- how to run the demo (backend with fake or real LLM, emulator, "Run scripted demo");
- verified vs not verified across all steps, and the open decisions.

Separately, if the user wants the Docker stack checked: install Docker Desktop (administrator
rights and WSL2; the user's decision), then `docker compose up`, the online migration test
and the opt-in live client test against port 8000.

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
| Memory: 15 GB RAM; emulator (≈4 GB) + Gradle + Chrome nearly used up the commit limit. In 5c a full `flutter test` run crashed test VMs with "Out of memory" while idle Gradle/Kotlin daemons and the emulator were still up | D-057 heap sizes; stop daemons (`gradlew --stop`) and the emulator when not needed | Close heavy apps while building, or enlarge the page file (user choice) |
| OneDrive also interfered in 5c: build_runner could not delete `.dart_tool/build/generated`, and `flutter test` once failed copying its cache, then hung | Clear the folder and re-run | Same as above: move the repo out of OneDrive |
| Fake-LLM card text ("Solid set…") contradicts a set over its VL cap; the deterministic next-set rule is right | Only the fake client; the card now names its model ("local model · fake-llm"); real model output goes through the number checker and rules | Check with real Ollama |
| Docker is not installed on this PC, so the compose stack (API + TimescaleDB + Ollama) has never been run | Throwaway SQLite API with fake LLM for the integration checks | User: install Docker Desktop (needs admin + WSL2) if the stack should be verified here |
| Demo timeline: D-017 assumes ~45 s live sets; the mock sets run 16–20 s, so rests are ~70 s | D-083: same 6:40 total, longer rests | Briefing timings, if they matter |
| Track/heatmap/stats days are UTC (D-067), so near midnight "Today" can differ from the local date | Labelled "(UTC day)" | Decide if a server-side timezone parameter is wanted |
| Session thresholds (framing 0.8 held 1 s, tap spike > g + 15 m/s², 600 ms match window) | D-074, tuned on the mock | Validate with the real sensor and camera |
| Spoken cues and vibration were not heard/felt: the emulator has no vibrator and audio was not checked | Calls verified in tests; plugin errors are ignored by design | Check on a physical phone |
| Android logged once "Foreground service start … does not have any types" although dumpsys shows type dataSync | Service runs in the foreground | Re-check on a physical Android 14+ phone |

## Verification log

### Step 6 — Scripted demo and integration (2026-11-21)
Verified (run here):
- **Gate:** `flutter analyze` "No issues found!" and `flutter test` exit 0: **120 pass, 1 skipped** (opt-in live test). Backend unchanged: **167 passed, 1 skipped** (`pytest`).
- **Demo runner tests (fake time, mock sensor and vision, real metrics engine inline):**
  - full run: all 7 phases seen, three sets saved in order (squat, bench, squat), set 2 over its cap, set 3 with valgus faults, long buzz and "Knees out." cues, finished at exactly the planned 6:40;
  - End session mid-demo stops it with nothing saved; "Take over" stops it and the buttons still work; Real mode refuses to start; a sensor that never feels the taps stops the demo with the reason instead of hanging.
- **Widget test:** the Session tab button (hidden in Real mode), the narration bar with the clock, the runner pressing Continue at 0:30, and Take over.
- **On the emulator** (debug APK, Android 16, throwaway API with fake LLM, real time, engine in its isolate), marks from logcat:
  - connect 0:00 → goal 0:30 → positioning 0:50 → calibration 0:54.6 → calibrated 1:38.5;
  - set 1 live 1:38.5, saved 1:57.3; set 2 setup 3:10.0, saved 3:34.9; set 3 setup 4:40.0, saved 5:01.5; closing 6:10.0; **done 6:40.0**;
  - set 1 clean squat VL 10.7 %; set 2 bench **25.1 % of a 20 % cap, cap exceeded**, card −5 % / 240 s; set 3 squat **red skeleton, "Knees out."**, valgus ×2, card −5 % / 180 s; all three "Uploaded." with cards (rules `vl_well_below_cap`, `vl_cap_exceeded`, `valgus_repeated`, read back through `GET /sets`);
  - no FATAL or Flutter errors in logcat.
- **Opt-in live client test** (`MRFIT_LIVE_API=http://127.0.0.1:8765`) against the same throwaway API: passed.
- **Bug found and fixed:** cards written by the backend's fake LLM were labelled "AI coach (local model)" like a real model. The badge now names the model (`2c00718`).

Not verified:
- **docker compose stack** (Docker not installed), so TimescaleDB migrations, real Ollama output and GPU are still unrun.
- Physical phone (audio, vibration, screen-off, battery) and real hardware, as in 5d.


### Step 5d — 7-phase session (2026-11-21)
Verified (run here):
- **Gate at every checkpoint:** `flutter analyze` "No issues found!" and `flutter test` exit 0. Final: **113 tests pass, 1 skipped** (opt-in live test). Backend unchanged.
- **Session controller tests (fake time, mock sensor and vision, real metrics engine inline):**
  - all three demo sets run through all 7 phases: clean squat (5 reps, set 1), fatigue bench (cap exceeded, long buzz and "Rack the bar"), valgus squat ("Knees out.", at most one fault cue per rep);
  - positioning auto-advances only after framing; TapTimeSync measures the mock's 37 ms clock lead (37–47 ms);
  - a tap the sensor never feels is dropped with a message; Real mode without hardware shows a clear error instead of crashing.
- **UI flow test:** every phase screen in order through the real widgets, the real upload queue with a fake backend, the card in the rest view with its rest time, the next demo scenario preselected, and End session.
- **Developer switch test:** Mock ↔ Real rebuilds the providers, keeps the sign-in, persists the choice, and hides or shows the SIMULATED banner.
- **On the emulator** (debug APK, Android 16, live API with fake LLM, real time, engine in its isolate):
  - **Phases 1–4:** connect (MockSensorSource, battery 87 %, −55 dBm); demo set list; positioning (framing 45 % → auto-advance); calibration measured **41 ms offset, 2 ms spread**.
  - **Set 1, clean squat:** 5 reps, velocity loss 12.1 % of a 30 % cap, MQS 94.3; uploaded; card: +2.5 % load, rest 90 s.
  - **Set 2, fatigue bench:** 6 reps, **24.2 % of a 20 % cap, cap exceeded**, incomplete ROM ×1; card: −5 %, rest 240 s.
  - **Set 3, valgus squat:** HUD skeleton **red** with **"Knees out."**; 4 reps, valgus ×2; card: −5 %, rest 180 s.
  - **Foreground service:** `isForeground=true`, type dataSync while the session ran; no service after "End session".
  - **Coach** lists the three sets; no FATAL or Flutter errors in logcat.
- **Bugs found and fixed:**
  - Switching the demo scenario raced with "Start set": the old mock sensor could be used. Found by tests.
  - A set saved during an in-flight sync pass waited for the 30 s timer. Seen on the emulator, reproduced by a failing test, fixed (D-082).

Not verified:
- A physical phone: audible TTS, felt vibration, real notification-permission dialog (granted with `adb` for the run), screen-off/background streaming over minutes, battery use.
- Real sensor, camera preview and pose model (REAL SLOTs, hardware undecided).
- The ≈7-minute scripted demo timeline (step 6).


### Step 5c — Data layer and ported screens (2026-11-21)
Verified (run here):
- **Gate at every checkpoint:** `flutter analyze` "No issues found!" and `flutter test` exit 0. Final: **103 tests pass, 1 skipped** (the opt-in live test). The backend is unchanged.
- **API client** (18 tests against an in-process fake backend):
  - The Bearer token, base URL and error mapping work.
  - Three concurrent 401s cause exactly **one** `/auth/refresh`.
  - A rejected refresh signs out; an offline refresh keeps the session; a still-401 retry does not loop.
  - Created vs replayed vs conflicting `POST /sets` are told apart.
- **Encrypted DB** (real SQLCipher on the host):
  - `cipher_version` is non-empty, and the file has no SQLite header and no plaintext marker.
  - The wrong key fails; a lost key moves the file aside.
- **Retry queue:**
  - Offline backoff timing and a lost response (200 replay) both work, and coaching waits for its set.
  - 422 is permanent, 401 pauses without consuming items, and concurrent passes share one upload.
- **Screens:** widget tests for Auth/session (9), Track (8), Library + heatmap (8), Stats (3) and Coach (8).
- **Live end-to-end** (`test/e2e/live_backend_test.dart`, real dio + real SQLCipher file) against the real FastAPI app (SQLite, fake LLM, Gemini off). It covers:
  - signup and duplicate (409), login, server-side volume;
  - heatmap and stats, the 26-exercise library and a custom exercise with its 409;
  - parse-entry 503, and a forced 401 → refresh with rotation;
  - a set through DB → queue → `POST /sets` → coaching → `GET /sets`, an idempotent resend, and logout revoking the refresh family.

  The server DB was checked afterwards (rows and revoked tokens as expected).
- **On the emulator** (debug APK, Android 16, against the same live API at `10.0.2.2:8765`):
  - The app starts, which shows SQLCipher opens on Android.
  - Sign up works, and Track shows the parse-disabled message.
  - A manual entry is saved (server volume 1537.5 kg, shown as 1538).
  - Coach shows two fixture sets uploaded with curl. "Get coaching" fetched a card. Cards show the source, focus, cues and the next-set rule.
  - The Library list is right, and the heatmap shows today at level 2 (3 activities).
  - Stats shows 328 kg/day and 3 workouts.
  - No FATAL or Flutter errors in logcat.
- Bugs found and fixed by tests:
  - 503 was treated as permanent. A server restart would have dropped sets.
  - `TrackScreen.dispose()` used `ref`.

Not verified:
- A physical phone; real Ollama coaching on device; voice input (fake in tests, not tried on the emulator); Gemini parsing on (server side only).
- Background sync while the app is closed (only while it runs; the foreground task is 5d).
- Long-running queue behaviour across app restarts on a device (covered by DB tests only).

Process notes:
- Commit `00d80fe` (checkpoint 3) was made after a run that had 2 failures. My command chained the commit after a grep, not after the test exit code. The cause was test VMs running out of memory, not the code: re-run 3× with free memory, all green. The gate now checks exit codes (D-073).
- While driving the emulator with adb input, one tap on "Add manually" ended on the Stats tab. It was not reproducible, and the next tap opened the sheet. Gboard's stylus tutorial also captured typed text once. Both were emulator input issues during manual checks; no app error was logged.

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

### Step 6
- **Demo runner:** `mobile/lib/app/session/demo_runner.dart` (new)
- **Screens:** `mobile/lib/presentation/session/{session_page,session_tab}.dart` (narration bar, "Run scripted demo"), `mobile/lib/presentation/coach/coach_screen.dart` (model name on the badge)
- **Tests:** `mobile/test/session/demo_runner_test.dart` (new), `mobile/test/presentation/{session_flow,coach_screen}_test.dart`
- **Docs:** `mobile/README.md`, `docs/DECISIONS.md` (D-083), `docs/PROGRESS.md`

### Step 5d
- **Session:** `mobile/lib/app/session/{session_controller,session_providers}.dart`, `mobile/lib/domain/session/session_ports.dart`, `mobile/lib/domain/metrics/metrics_session.dart`, `mobile/lib/domain/metrics/metrics_worker.dart` (implements `LiveMetricsSession`)
- **Devices:** `mobile/lib/data/feedback/{device_cue_output,foreground_keep_alive}.dart`
- **Mocks and binding:** `mobile/lib/data/sensors/mock/{mock_world,mock_sensor_source}.dart` (ports), `mobile/lib/app/bindings.dart` (clock, simulation hooks, TapTimeSync in Mock mode)
- **App and screens:** `mobile/lib/app/{app,app_root}.dart`, `mobile/lib/main.dart`, `mobile/lib/presentation/session/{session_tab,session_page,skeleton_painter}.dart`, `mobile/lib/presentation/settings/settings_page.dart`, `mobile/lib/presentation/shell/home_shell.dart`, `mobile/lib/presentation/coach/coach_screen.dart` (shared card view)
- **Data:** `mobile/lib/data/sync/{set_repository,sync_service}.dart`
- **Tests:** `mobile/test/session/session_controller_test.dart`, `mobile/test/presentation/{session_flow,settings_switch}_test.dart`, `mobile/test/support/{session_fakes,app_harness,fake_http}.dart`, `mobile/test/data/sync_queue_test.dart`
- **Config and docs:** `mobile/pubspec.yaml` and `pubspec.lock` (`fake_async`), `mobile/README.md`, `docs/DECISIONS.md` (D-074…D-082), `docs/PROGRESS.md`

### Step 5c
- **Data:** `mobile/lib/data/{storage/secret_store,auth/token_store,api/api_client,api/api_exception,api/api_models,api/mrfit_api,local/app_database,local/encrypted_db,sync/sync_service,sync/set_repository,voice/voice_input}.dart`
- **App:** `mobile/lib/app/{providers,session,app}.dart`, `mobile/lib/main.dart`
- **Screens:** `mobile/lib/presentation/{auth/auth_screen,shell/home_shell,logs/log_providers,logs/log_format,logs/log_list,logs/log_sheets,track/track_screen,library/library_screen,library/quick_log_sheet,library/activity_heatmap,stats/stats_screen,coach/coach_providers,coach/coach_screen,widgets/async_view}.dart`
- **Tests:** `mobile/test/{flutter_test_config,widget_test}.dart`, `mobile/test/support/{fake_http,app_harness}.dart`, `mobile/test/data/{api_client,encrypted_db,sync_queue}_test.dart`, `mobile/test/presentation/{auth_flow,track_screen,library_screen,stats_screen,coach_screen}_test.dart`, `mobile/test/e2e/live_backend_test.dart`
- **Android/config:** `mobile/android/app/src/main/AndroidManifest.xml` (`allowBackup=false`), `mobile/.gitignore` (`*.g.dart`)
- **Docs:** `mobile/README.md`, `docs/DECISIONS.md` (D-064…D-073), `docs/PROGRESS.md`

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
