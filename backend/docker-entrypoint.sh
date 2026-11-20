#!/bin/sh
# Container entrypoint: apply DB migrations, then start the API.
set -eu

if [ -f /app/alembic.ini ]; then
  echo "[entrypoint] applying migrations (alembic upgrade head)"
  alembic upgrade head
  # Re-apply compression/retention policies so TS_* env changes take effect.
  python -m app.db.timescale
else
  echo "[entrypoint] no alembic.ini yet - skipping migrations"
fi

# create_app() validates settings (SECRET_KEY, model allowlist, ...) and fails fast.
exec uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000 --proxy-headers
