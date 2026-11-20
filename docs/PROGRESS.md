# MR-Fit 2.0 — Progress

Updated after every step. Decisions and assumptions live in [DECISIONS.md](DECISIONS.md).
Branch: `feat/mr-fit-2`.

## Status: 3 of 7 steps done

| # | Step | Status | Commit |
|---|---|---|---|
| 1 | Read report, inspect repo, plan | ✅ done | — (no repo changes) |
| 2 | Infrastructure: compose, requirements, Dockerfile, `.env.example`, archive cleanup | ✅ done | `9483e92` (+ `f316de1` v1 path fixes) |
| 3 | Database: Postgres/Timescale schema + Alembic migration of old tables | ✅ done | see `git log` ("Add Postgres/Timescale schema…") |
| 4 | Backend: port routes, custom exercises, `/sets`, auth refresh, constrained coach, tests | ⏭ next | |
| 5 | Flutter: skeleton, domain abstractions + mocks + MetricsEngine, ported screens, 7-phase screens | ⏳ | |
| 6 | Integration + scripted ~7-minute demo runner | ⏳ | |
| 7 | Final summary: real vs simulated, how to plug in real sensor/vision | ⏳ | |

## Exact next action

Step 4, first change: port auth to `backend/app/api/auth.py` (signup/login with v1's
bcrypt(sha256) hashing, PyJWT access tokens, rotating refresh tokens + `POST /auth/refresh`
with reuse detection), with tests on SQLite.

## Open questions / pending decisions

| Item | Default in use | Needed from |
|---|---|---|
| ROLE_BRIEFING not in the workspace; 7-phase timings unknown | D-017 placeholder timings (≈7 min) | User: paste briefing if exact timings matter |
| TimescaleDB 2.31 compression API fallback never run against a real server | D-023 dual-API PL/pgSQL fallback | User: run the opt-in online migration test (below), or allow running portable Postgres in the scratchpad |
| MQS formula and thresholds | Placeholder to be written in `docs/MQS.md` (step 5), weights in config | Team validation |
| Sensor source / vision task / pose model / transport | Mocks (O-1…O-4) | Hardware decision |
| Gemini key that was committed in v1 history | Untracked; history not rewritten (D-002) | User rotates the key (confirmed they will) |

## Verification log

### Step 3 — Database
Verified (Python 3.14, pinned requirements, SQLite + Alembic offline mode):
- 43 tests pass, 1 skipped (opt-in online test).
- ORM constraints on SQLite: CHECK (exercise/goal/data_source/coaching_source/vl_cap/reps/log type), case-insensitive unique custom exercise per user, cascade delete user → sets → timeseries/skeleton/logs, timeseries PK rejects duplicate rows, JSONB round-trip.
- `alembic upgrade head --sql` renders the full PostgreSQL DDL with no server; tests check it contains every ORM table, column and index, hypertable/compression/retention statements with the configured `TS_*` values, and the UTC conversion of v1 timestamps. A deliberate break (removing a column from 0003) was caught.
- Single linear Alembic head; non-Postgres dialects refused.
- `scripts/import_sqlite.py` dry-run on the real local v1 DBs: 9 users / 50 logs and 5 users / 18 logs, all accepted. The scratch target copy was deleted afterwards.

Not verified:
- Migrations against a real PostgreSQL/TimescaleDB server (no Docker; running downloaded portable Postgres binaries was blocked by the permission classifier). To verify:
  `docker compose up -d timescaledb`, then
  `MRFIT_TEST_PG_URL=postgresql+psycopg://mrfit:<pw>@127.0.0.1:5432/<scratch_db> pytest -k online`
  (upgrade → downgrade → upgrade, checks hypertables + compression, compares live schema to ORM).
- Postgres sequence reset in the import script (PG-only code path).

### Step 2 — Infrastructure
Verified: pinned requirements install on Python 3.14 and `pip check` passes; 14 settings/CORS/health tests pass; `uvicorn app.main:create_app --factory` serves `/health` and refuses to start with `OLLAMA_MODEL=qwen3:8b` or no `SECRET_KEY`; all Docker image tags exist on Docker Hub; `deepseek-r1:1.5b` = Q4_K_M (same digest `e0979632db5a`); compose file parses and all service/dependency/volume references resolve.

Not verified: `docker compose up`, image build, GPU passthrough, model pull, Compose `depends_on.required: false` behaviour (needs Compose ≥ 2.20).

### Step 1 — Plan
Read `mrfit_reverse_engineer.md` and every v1 source file. Report/code mismatches recorded in the step-1 summary (13 routes not 9, `mr_fit.env.md` missing, tracked secret + DB files, unused `/ai-coach`, unverifiable library versions).

## Files changed per step

### Step 3
- `backend/app/core/config.py` (split `DatabaseSettings` so Alembic needs no `SECRET_KEY`)
- `backend/app/db/{__init__,base,session,timescale}.py`
- `backend/app/models/{__init__,constants,core,biomech,food}.py`
- `backend/alembic.ini`, `backend/alembic/{env.py,script.py.mako}`
- `backend/alembic/versions/{0001_v1_baseline,0002_v2_core,0003_timescale}.py`
- `backend/docker-entrypoint.sh` (policy sync after migrations)
- `backend/scripts/{__init__,import_sqlite}.py`
- `backend/tests/{conftest,test_models,test_migrations,test_timescale_sql,test_import_sqlite}.py`
- `docs/DECISIONS.md` (D-021…D-027), `docs/PROGRESS.md` (new), `README.md` (Database section)

### Step 2
- Added: `.env.example`, `.gitattributes`, `docker-compose.yml`, `README.md`, `archive/README.md`, `docs/DECISIONS.md`, `backend/{Dockerfile,.dockerignore,docker-entrypoint.sh,pytest.ini,requirements*.txt}`, `backend/app/{__init__,main}.py`, `backend/app/core/{__init__,config}.py`, `backend/tests/test_config.py`
- Changed: `.gitignore`
- Moved: v1 backend + `static/` → `archive/legacy_v1/`; `New folder/` code → `archive/new_folder_snapshot/`
- Untracked (kept on disk): `New folder/mr_fit.env`, `mrfit.db`, `New folder/mrfit.db`, `__pycache__/`
