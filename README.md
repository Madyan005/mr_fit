# MR-Fit 2.0

Flutter (Android) strength-training app with velocity-based biomechanics, a
PostgreSQL + TimescaleDB backend, and a constrained local coach
(Ollama, `deepseek-r1:1.5b`).

> **Status: prototype.** Sensors and vision are simulated (Mock implementations,
> labelled SIMULATED) until hardware is chosen. What is real and what is simulated,
> the architecture, how to run the demo and what was verified:
> [docs/FINAL_SUMMARY.md](docs/FINAL_SUMMARY.md). Replacing the mocks with hardware:
> [docs/INTEGRATION_GUIDE.md](docs/INTEGRATION_GUIDE.md).

## Layout

```
backend/    FastAPI API, Alembic migrations, tests
mobile/     Flutter Android app (see mobile/README.md)
contracts/  Shared JSON schemas + fixtures (SetSummaryPayload)
docs/       DECISIONS.md and design docs
archive/    v1 web app, kept for reference
```

## Run the backend stack

```bash
cp .env.example .env
# fill SECRET_KEY and POSTGRES_PASSWORD (see comments in .env.example)
docker compose up
```

| Want | Set in `.env` |
|---|---|
| GPU Ollama (default) | `COMPOSE_PROFILES=gpu` — needs NVIDIA Container Toolkit (Linux) or Docker Desktop with WSL2 GPU support (Windows) |
| No GPU, real model on CPU | `COMPOSE_PROFILES=cpu` |
| No Ollama at all (fake coach) | `COMPOSE_PROFILES=` and `LLM_BACKEND=fake` |
| pgAdmin on http://127.0.0.1:5050 | add `tools`, e.g. `COMPOSE_PROFILES=gpu,tools` |

API: `http://<host-LAN-IP>:8000` (health: `/health`). From the Android emulator use `http://10.0.2.2:8000`.

## API

Interactive docs at `/docs` once the stack is up. Contract details: [docs/CONTRACT.md](docs/CONTRACT.md).

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/signup`, `/auth/login`, `/auth/refresh` (rotating), `/auth/logout` |
| Logs (v1, ported) | `GET/POST /logs`, `PUT/DELETE /logs/{id}`, `GET /logs/heatmap`, `GET /stats` |
| Exercise library | `GET /exercises`, `POST /exercises/custom`, `DELETE /exercises/custom/{id}` |
| Biomechanics sets | `POST /sets` (idempotent by `set_id`), `GET /sets`, `GET /sets/{id}`, `POST /sets/{id}/timeseries`, `POST /sets/{id}/skeleton` |
| Coaching | `POST /sets/{id}/coaching`: medical guardrail → local SLM (`deepseek-r1:1.5b`) → schema + number checks → deterministic fallback |
| Optional | `POST /parse-entry` (Gemini text parsing; `503` unless `GEMINI_ENABLED=true`) |
| Meta | `GET /health` |

## Database

Migrations run automatically when the `api` container starts (`alembic upgrade head`,
then compression/retention policies are re-synced from `TS_*` env vars).

| Table | Kind |
|---|---|
| `users`, `logs` | v1 tables, migrated (`users.id` stays INTEGER) |
| `refresh_tokens`, `custom_exercises` | auth + per-user exercise library |
| `biomechanical_sets`, `athlete_baselines` | set summaries (MQS, velocity loss, faults, coaching JSON, `data_source`) |
| `sensor_timeseries`, `skeleton_frames` | TimescaleDB hypertables (generic channels; compressed after 7 d; kept 90 d / 30 d) |
| `meals`, `food_items`, `nutrition_reference` | optional food feature |

Import v1 data (optional, manual):

```bash
cd backend
python -m scripts.import_sqlite --sqlite ../mrfit.db --dry-run   # then without --dry-run
```

## Backend tests (no Docker, GPU, or Ollama needed)

```bash
cd backend
python -m venv .venv && .venv/Scripts/activate   # Windows; use bin/activate on Linux/macOS
pip install -r requirements-dev.txt
pytest
```
