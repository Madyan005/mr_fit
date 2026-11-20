"""MR-Fit 2.0 API application factory.

Run: uvicorn app.main:create_app --factory   (ONE worker: the GPU lock is per process)
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session, sessionmaker

from app.api import auth, exercises, logs, parse, sets
from app.core.config import Settings, get_settings
from app.services.coach.llm import FakeLLMClient, LLMClient, OllamaClient
from app.services.coach.service import CoachService
from app.services.gpu import GpuScheduler
from app.services.rate_limit import CooldownLimiter

API_VERSION = "2.0.0-dev"


def _default_llm(settings: Settings) -> LLMClient:
    if settings.llm_backend == "fake":
        return FakeLLMClient()
    return OllamaClient(settings.ollama_base_url, settings.ollama_model,
                        keep_alive=settings.ollama_keep_alive, timeout_s=settings.ollama_timeout_seconds)


def _default_text_parser(settings: Settings) -> Any:
    if not settings.gemini_enabled:
        return None
    from app.services.gemini_optional.parser import GeminiTextParser

    return GeminiTextParser(settings.gemini_api_key.get_secret_value(), settings.gemini_model)


def create_app(
    settings: Settings | None = None,
    *,
    session_factory: sessionmaker[Session] | None = None,
    llm: LLMClient | None = None,
    text_parser: Any = "default",
) -> FastAPI:
    settings = settings or get_settings()  # raises on insecure/banned config
    if session_factory is None:
        from app.db.session import make_engine

        session_factory = sessionmaker(bind=make_engine(settings.database_url),
                                       autoflush=False, expire_on_commit=False)
    llm = llm or _default_llm(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        close = getattr(llm, "aclose", None)
        if close is not None:
            await close()

    app = FastAPI(title="MR-Fit API", version=API_VERSION, lifespan=lifespan)
    app.state.settings = settings
    app.state.sessionmaker = session_factory
    app.state.gpu = GpuScheduler()
    app.state.coach = CoachService(llm, app.state.gpu)
    app.state.ai_limiter = CooldownLimiter(settings.ai_cooldown_seconds)
    app.state.text_parser = _default_text_parser(settings) if text_parser == "default" else text_parser

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

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        # The default handler echoes the offending input, which (a) crashes on NaN/Infinity
        # (not JSON-serialisable) and (b) reflects client data back. Return loc/msg/type only.
        errors = [{"loc": list(e.get("loc", ())), "msg": str(e.get("msg", "")), "type": e.get("type")}
                  for e in exc.errors()]
        return JSONResponse(status_code=422, content={"detail": errors})

    for r in (auth.router, logs.router, exercises.router, sets.router, parse.router):
        app.include_router(r)

    @app.get("/health", tags=["meta"])
    def health() -> dict:
        return {
            "status": "ok",
            "version": API_VERSION,
            "llm_backend": settings.llm_backend,
            "gemini_enabled": settings.gemini_enabled,
        }

    return app
