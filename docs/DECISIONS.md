# MR-Fit 2.0 — Decisions & Assumptions Log

Every decision lists the **default chosen** and **how to change it**.
`ASSUMPTION` = not verified against hardware, data, or the team; revisit before relying on it.
`OPEN` = deliberately left swappable (prototype).

## Open decisions (kept swappable by design)

| ID | Topic | Default for now | How to change |
|---|---|---|---|
| O-1 | Sensor source (ESP32 / smartwatch / phone IMU, maybe several) | `MockSensorSource` | Implement `SensorSource` in `mobile/lib/data/sensors/real/`, switch the single binding in the provider-override file (see `docs/INTEGRATION_GUIDE.md`) |
| O-2 | Vision task (exercise pose vs food recognition, or both) | Pose via `MockVisionPipeline`; food is an optional isolated feature | Implement `VisionPipeline` / `FoodRecognizer` in `mobile/lib/data/vision/real/` |
| O-3 | Pose model/runtime (TFLite MoveNet, MediaPipe, …) | none (mock, COCO-17 keypoints) | Real slot + capabilities declare the keypoint set |
| O-4 | Transport (BLE, WebSocket, platform sensors) | none (in-process mock) | Inside the Real slot only |
| O-5 | MQS formula & thresholds | Placeholder in `docs/MQS.md` (ASSUMPTION, needs validation), weights in config | Edit config weights; formula versioned |

## Decisions

| ID | Decision | Default chosen | How to change |
|---|---|---|---|
| D-001 | Repository layout | Monorepo in the existing repo on branch `feat/mr-fit-2`: `backend/`, `mobile/`, `contracts/`, `docs/`, `archive/` | — |
| D-002 | v1 secrets / databases that were tracked in git (`New folder/mr_fit.env`, `mrfit.db`, `New folder/mrfit.db`) | **Untracked** with `git rm --cached` (files stay on disk), **not** archived, because archiving would keep committing a secret and user PII. Git history is **not** rewritten. The owner must rotate the Gemini key. | To purge history: `git filter-repo` / BFG, then force-push (owner decision) |
| D-003 | Archive layout | `archive/legacy_v1/` = the v1 app (backend + `static/`, still runnable together); `archive/new_folder_snapshot/` = code from the older `New folder/` copy | — |
| D-004 | API container runtime | `python:3.14-slim` — same interpreter the pinned requirements were installed and tested with on the dev machine | `backend/Dockerfile` `FROM` |
| D-005 | Image pins | `timescale/timescaledb:2.31.0-pg17` (non-`-oss`: compression needs the community build), `ollama/ollama:0.40.15`, `dpage/pgadmin4:9.18`. Tags verified to exist on Docker Hub 2026-11-20 | `TIMESCALEDB_IMAGE_TAG`, `OLLAMA_IMAGE_TAG`, `PGADMIN_IMAGE_TAG` in `.env` |
| D-006 | Compose profiles | `COMPOSE_PROFILES=gpu` in `.env` so plain `docker compose up` starts DB + API + GPU Ollama + model pull. `cpu` = Ollama on CPU. Empty profile + `LLM_BACKEND=fake` = no Ollama. `tools` = pgAdmin | `COMPOSE_PROFILES` in `.env` |
| D-007 | VRAM discipline in Ollama | `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=0` (unload after each request). App-side `asyncio.Lock` GPU queue added in step 4 | `OLLAMA_KEEP_ALIVE` (e.g. `5m` trades VRAM for latency) |
| D-008 | Coach model | **Allowlist**, not just a denylist: only `deepseek-r1:1.5b` or `deepseek-r1:1.5b-qwen-distill-q4_K_M`. Both share digest `e0979632db5a` (1.1 GB) on ollama.com = Q4_K_M (verified 2026-11-20). `qwen3:8b`, `llama3:8b` named explicitly as banned. API refuses to start otherwise | `ALLOWED_OLLAMA_MODELS` in `backend/app/core/config.py` (code change on purpose) |
| D-009 | JWT signing key | `SECRET_KEY` required, ≥ 32 chars, known placeholders (incl. v1's `DEV_SECRET_ONLY_CHANGE_ME`) rejected at startup | — |
| D-010 | CORS | Explicit allowlist from `CORS_ORIGINS`; `*` refused; empty = CORS middleware off (the Flutter app is a native client and sends no `Origin`). `allow_credentials=False` since auth is a Bearer header, not cookies | `CORS_ORIGINS` |
| D-011 | JWT library | `PyJWT` replaces `python-jose` (v1, `archive/legacy_v1/auth_utils.py`); same HS256 tokens, actively maintained | — |
| D-012 | Token lifetimes | Access 30 min, rotating refresh 30 days (refresh flow implemented in step 4). **ASSUMPTION** — v1 used one 7-day token | `ACCESS_TOKEN_EXPIRE_MINUTES`, `REFRESH_TOKEN_EXPIRE_DAYS` |
| D-013 | Gemini | Optional module, **off** by default. `google-genai` lives in `requirements-gemini.txt` and is installed only when `GEMINI_ENABLED=true` (build arg). Startup fails if enabled without `GEMINI_API_KEY` | `GEMINI_ENABLED`, `GEMINI_API_KEY` |
| D-014 | Network exposure | API bound to `0.0.0.0:8000` so a phone on the LAN can reach it; DB and pgAdmin bound to `127.0.0.1` only. No TLS in the stack — **ASSUMPTION** trusted home/lab LAN; put Caddy/Nginx in front for anything else | `API_HOST_BIND`, `API_HOST_PORT` |
| D-015 | Migrations | Container entrypoint runs `alembic upgrade head` before starting uvicorn | `backend/docker-entrypoint.sh` |
| D-016 | Existing v1 SQLite data (local `mrfit.db`: 9 users / 50 logs) | Not migrated automatically. An optional one-shot `backend/scripts/import_sqlite.py` is added in step 3 | Run the script manually |
| D-017 | 7-phase demo timings | Pair 30 s · Goal 20 s · Positioning 30 s · Calibration 20 s · 3 sets (clean, fatigue past VL cap, valgus fault) × (~45 s live + 5 s conclusion + ~40 s rest card) · closing 30 s ≈ 7 min. **ASSUMPTION** — ROLE_BRIEFING timings were not available | Demo scenario config (step 6) |
| D-018 | Prescription numbers vs number checker | Numeric prescriptions (rest time, load change) come from a deterministic rules table keyed by goal + velocity loss; the LLM only writes wording that references metrics by key, so every number in the text can be checked against the payload | Rules table (step 4) |
| D-019 | Racked detection when no sensor reports it | `DeviceStatus.restingDwell` from the sensor if available, else vision zero-motion > 2.0 s, flagged lower confidence | MetricsEngine config (step 5) |
| D-020 | Food recognizer input type | `FoodImage` (bytes + mime) instead of `Image`, which is ambiguous in Flutter (`dart:ui` vs widgets) | — |
| D-021 | Sensor-tracked sets in v1 Stats/heatmap | `POST /sets` also writes one mirror row in `logs` (`biomechanical_sets.log_id`), so old Stats/heatmap include them | Drop the mirror write in the sets service (step 4) |
| D-022 | Migration chain | `0001_v1_baseline` reproduces v1's `create_all` with IF NOT EXISTS (adopts an existing v1 Postgres DB); `0002_v2_core` hardens v1 tables (naive `logs.created_at` → `timestamptz` read as UTC, NOT NULL, FK `ON DELETE CASCADE`, CHECK type) and adds the new tables; `0003_timescale` adds the hypertables. Migrations are PostgreSQL-only and refuse other dialects; unit tests use SQLite via `metadata.create_all` | — |
| D-023 | TimescaleDB API rename (2.18: compression → columnstore) | Every compression call tries the new API and falls back to the legacy one inside a PL/pgSQL `EXCEPTION` block. **ASSUMPTION: not yet run against the pinned 2.31 image** (see the opt-in online test in `backend/tests/test_migrations.py`) | `backend/app/db/timescale.py` |
| D-024 | Hypertable layout | 1-day chunks; `sensor_timeseries` PK `(set_id, source, channel, time)`, `skeleton_frames` PK `(set_id, time)` — both include `time` and make batch re-sends detectable (`ON CONFLICT DO NOTHING` in step 4). Compression segmentby `set_id, channel` / `set_id`, orderby `time DESC` | `backend/app/db/timescale.py` |
| D-025 | Policy sync | Compression/retention policies are re-applied from `TS_*` env on every container start (`python -m app.db.timescale`), not only at migration time | Change `TS_*` in `.env`, restart `api` |
| D-026 | `athlete_baselines` shape | One row per (athlete, exercise) with reference MPV / depth / symmetry at a stated `load_kg`. **ASSUMPTION** (briefing table idea only, no field list available) | New migration |
| D-027 | v1 data import | `backend/scripts/import_sqlite.py`: preserves ids, lower-cases emails, copies bcrypt hashes verbatim, skips (never overwrites) conflicting users, idempotent re-runs, `--dry-run`, resets Postgres sequences. Dry-run on the real local v1 files: 9 users / 50 logs and 5 users / 18 logs, all accepted | — |
