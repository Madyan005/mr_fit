from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.api.deps import enforce_cooldown, get_current_user
from app.models import User
from app.schemas.logs import ParseRequest
from app.services.gemini_optional.parser import ParseFailed, parse_text

router = APIRouter(tags=["optional: text parsing"])


@router.post("/parse-entry")
def parse_entry(req: ParseRequest, request: Request, user: User = Depends(get_current_user)) -> list[dict]:
    """OPTIONAL (GEMINI_ENABLED). Returns parsed items; the client then POSTs /logs per item (as in v1)."""
    parser = request.app.state.text_parser
    if parser is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                            "Natural-language parsing is disabled on this server (GEMINI_ENABLED=false)")
    enforce_cooldown(request, user, "parse-entry")
    try:
        return parse_text(parser, req.text, req.prefill_exercise)
    except ParseFailed as e:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(e)) from None
