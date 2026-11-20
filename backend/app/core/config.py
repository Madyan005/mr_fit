"""Central settings. Every value comes from environment variables (or the
repo-root `.env` when running outside Docker). The app refuses to start on
insecure or banned configuration instead of silently falling back.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# backend/app/core/config.py -> parents[3] is the repo root (where .env lives).
# Inside the container this path does not exist, which pydantic-settings ignores.
_REPO_ROOT_ENV = Path(__file__).resolve().parents[3] / ".env"

# The coach must only ever run deepseek-r1:1.5b at Q4_K_M (GTX 1050 Ti, 4 GB VRAM).
# Verified 2026-11-20 on ollama.com: both tags share digest e0979632db5a (1.1 GB).
ALLOWED_OLLAMA_MODELS: frozenset[str] = frozenset(
    {"deepseek-r1:1.5b", "deepseek-r1:1.5b-qwen-distill-q4_K_M"}
)
# Explicitly named so the startup error is unambiguous.
BANNED_OLLAMA_MODELS: frozenset[str] = frozenset({"qwen3:8b", "llama3:8b"})

# Values that must never be used as a signing key (v1 shipped the first one as a default).
_INSECURE_SECRETS = {"DEV_SECRET_ONLY_CHANGE_ME", "changeme", "change-me", "secret", "dev"}
MIN_SECRET_LEN = 32


_MODEL_CONFIG = SettingsConfigDict(
    env_file=_REPO_ROOT_ENV,
    env_file_encoding="utf-8",
    extra="ignore",
    case_sensitive=False,
)


class DatabaseSettings(BaseSettings):
    """Subset needed by Alembic and scripts (no SECRET_KEY required)."""

    model_config = _MODEL_CONFIG

    database_url: str  # REQUIRED, no default (contains a password)
    ts_compress_after_days: int = Field(default=7, ge=1)
    ts_sensor_retention_days: int = Field(default=90, ge=1)
    ts_skeleton_retention_days: int = Field(default=30, ge=1)
    max_timeseries_batch: int = Field(default=5000, ge=1, le=50_000)
    max_skeleton_batch: int = Field(default=1000, ge=1, le=10_000)


class Settings(DatabaseSettings):
    model_config = _MODEL_CONFIG

    app_env: Literal["dev", "test", "prod"] = "dev"

    # ---- auth ----
    secret_key: SecretStr  # REQUIRED, no default
    access_token_expire_minutes: int = Field(default=30, ge=1, le=24 * 60)
    refresh_token_expire_days: int = Field(default=30, ge=1, le=365)

    # ---- http ----
    cors_origins: str = ""  # comma-separated allowlist; empty = CORS disabled
    ai_cooldown_seconds: int = Field(default=10, ge=0)

    # ---- coach LLM ----
    llm_backend: Literal["ollama", "fake"] = "ollama"
    ollama_base_url: str = "http://ollama:11434"
    ollama_model: str = "deepseek-r1:1.5b"
    ollama_keep_alive: str = "0"
    ollama_timeout_seconds: float = Field(default=120, gt=0)

    # ---- optional Gemini text parsing (default OFF) ----
    gemini_enabled: bool = False
    gemini_api_key: SecretStr | None = None
    gemini_model: str = "gemini-2.5-flash"

    @field_validator("secret_key")
    @classmethod
    def _secret_key_strong(cls, v: SecretStr) -> SecretStr:
        raw = v.get_secret_value()
        if raw.strip().lower() in {s.lower() for s in _INSECURE_SECRETS}:
            raise ValueError("SECRET_KEY is a known placeholder; generate a random one")
        if len(raw) < MIN_SECRET_LEN:
            raise ValueError(f"SECRET_KEY must be at least {MIN_SECRET_LEN} characters")
        return v

    @field_validator("ollama_model")
    @classmethod
    def _model_allowed(cls, v: str) -> str:
        name = v.strip()
        if name.lower() in BANNED_OLLAMA_MODELS:
            raise ValueError(f"OLLAMA_MODEL={name!r} is banned (exceeds 4 GB VRAM budget)")
        if name not in ALLOWED_OLLAMA_MODELS:
            raise ValueError(
                f"OLLAMA_MODEL={name!r} is not allowed; use one of {sorted(ALLOWED_OLLAMA_MODELS)}"
            )
        return name

    @field_validator("cors_origins")
    @classmethod
    def _no_wildcard(cls, v: str) -> str:
        if "*" in v:
            raise ValueError("CORS_ORIGINS must be an explicit allowlist; '*' is not allowed")
        return v

    @model_validator(mode="after")
    def _gemini_needs_key(self) -> "Settings":
        if self.gemini_enabled and not (
            self.gemini_api_key and self.gemini_api_key.get_secret_value().strip()
        ):
            raise ValueError("GEMINI_ENABLED=true requires GEMINI_API_KEY")
        return self

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip().rstrip("/") for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]  # required fields come from env


@lru_cache
def get_db_settings() -> DatabaseSettings:
    return DatabaseSettings()  # type: ignore[call-arg]
