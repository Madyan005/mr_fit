from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel


class SetOut(BaseModel):
    set_id: uuid.UUID
    created_at: datetime
    log_id: int | None
    payload: dict[str, Any]
    coaching: dict[str, Any] | None
    coaching_source: str | None


class SetListOut(BaseModel):
    items: list[SetOut]
    next_before: datetime | None  # pass as ?before= for the next page
