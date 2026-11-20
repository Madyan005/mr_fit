# syntax=docker/dockerfile:1
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first for layer caching.
COPY requirements.txt requirements-gemini.txt ./
ARG INSTALL_GEMINI=false
RUN pip install -r requirements.txt \
 && if [ "$INSTALL_GEMINI" = "true" ]; then pip install -r requirements-gemini.txt; fi

COPY . .

RUN useradd --system --uid 10001 --no-create-home mrfit \
 && chmod +x /app/docker-entrypoint.sh
USER mrfit

EXPOSE 8000
ENTRYPOINT ["/app/docker-entrypoint.sh"]
