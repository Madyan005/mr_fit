"""Loads the shared JSON contracts (repo-root `contracts/`, or MRFIT_CONTRACTS_DIR in Docker).
These files are the single source of truth shared with the Flutter app."""
from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any


def contracts_dir() -> Path:
    env = os.getenv("MRFIT_CONTRACTS_DIR")
    return Path(env) if env else Path(__file__).resolve().parents[3] / "contracts"


@lru_cache
def load(name: str) -> dict[str, Any]:
    with open(contracts_dir() / name, encoding="utf-8") as f:
        return json.load(f)


def channel_names() -> frozenset[str]:
    return frozenset(c["name"] for c in load("channels.v1.json")["channels"])


def exercise_library() -> dict[str, Any]:
    return load("exercise_library.v1.json")
