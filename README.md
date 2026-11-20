# MR-Fit 2.0

Flutter (Android) strength-training app with velocity-based biomechanics, a
PostgreSQL + TimescaleDB backend, and a constrained local coach
(Ollama, `deepseek-r1:1.5b`).

> **Status: prototype, under construction.** Sensors and vision are simulated
> (Mock implementations) until hardware is chosen. A full "real vs simulated"
> table and architecture diagram land at the end of the build.

## Layout

```
backend/    FastAPI API, Alembic migrations, tests
mobile/     Flutter app (added in a later step)
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

## Backend tests (no Docker, GPU, or Ollama needed)

```bash
cd backend
python -m venv .venv && .venv/Scripts/activate   # Windows; use bin/activate on Linux/macOS
pip install -r requirements-dev.txt
pytest
```
