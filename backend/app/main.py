"""MR-Fit 2.0 API application factory.

Run: uvicorn app.main:create_app --factory
Routers (auth, logs, stats, sets, coach) are added in later steps.
"""
from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import Settings, get_settings

API_VERSION = "2.0.0-dev"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()  # raises on insecure/banned config

    app = FastAPI(title="MR-Fit API", version=API_VERSION)
    app.state.settings = settings

    origins = settings.cors_origin_list
    if origins:
        # Bearer tokens in headers, no cookies -> credentials are not needed.
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )

    @app.get("/health", tags=["meta"])
    def health() -> dict:
        return {"status": "ok", "version": API_VERSION}

    return app
