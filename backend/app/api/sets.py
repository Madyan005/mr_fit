from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.orm import Session

from app.api.deps import enforce_cooldown, get_current_user, get_db, get_settings_dep
from app.core.config import Settings
from app.core.contracts import channel_names
from app.models import BiomechanicalSet, User
from app.schemas.coaching import CoachingCard, CoachingRequest
from app.schemas.set_summary import SetSummaryPayload
from app.schemas.sets import SetListOut, SetOut
from app.schemas.streams import BatchResult, SkeletonBatch, TimeseriesBatch
from app.services import sets_service as svc
from app.services.coach import guardrail
from app.services.context import biomech_history_labels

router = APIRouter(prefix="/sets", tags=["sets"])


def _out(row: BiomechanicalSet) -> SetOut:
    return SetOut(set_id=row.set_id, created_at=row.created_at, log_id=row.log_id,
                  payload=row.payload, coaching=row.slm_coaching_json,
                  coaching_source=row.coaching_source)


def _owned_or_404(db: Session, user: User, set_id: uuid.UUID) -> BiomechanicalSet:
    row = svc.get_owned_set(db, user.id, set_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Set not found")
    return row


@router.post("", response_model=SetOut, status_code=status.HTTP_201_CREATED,
             responses={200: {"description": "Identical replay of an existing set"},
                        409: {"description": "set_id exists with a different payload"}})
def create_set(payload: SetSummaryPayload, response: Response, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> SetOut:
    try:
        row, created = svc.create_or_get_set(db, user.id, payload)
    except svc.SetConflict:
        raise HTTPException(status.HTTP_409_CONFLICT, "set_id already used with different data") from None
    if not created:
        response.status_code = status.HTTP_200_OK
    return _out(row)


@router.get("", response_model=SetListOut)
def list_sets(
    exercise: Literal["squat", "deadlift", "bench_press", "push_up"] | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    before: datetime | None = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SetListOut:
    rows = svc.recent_sets(db, user.id, exercise, limit, before)
    return SetListOut(items=[_out(r) for r in rows],
                      next_before=rows[-1].created_at if len(rows) == limit else None)


@router.get("/{set_id}", response_model=SetOut)
def get_set(set_id: uuid.UUID, user: User = Depends(get_current_user),
            db: Session = Depends(get_db)) -> SetOut:
    return _out(_owned_or_404(db, user, set_id))


@router.post("/{set_id}/timeseries", response_model=BatchResult)
def upload_timeseries(set_id: uuid.UUID, batch: TimeseriesBatch, user: User = Depends(get_current_user),
                      db: Session = Depends(get_db), settings: Settings = Depends(get_settings_dep)) -> BatchResult:
    if len(batch.samples) > settings.max_timeseries_batch:
        raise HTTPException(413,
                            f"max {settings.max_timeseries_batch} samples per batch")
    unknown = sorted({s.channel for s in batch.samples} - channel_names())
    if unknown:
        raise HTTPException(422,
                            f"unknown channel(s) {unknown}; see contracts/channels.v1.json")
    _owned_or_404(db, user, set_id)
    received, inserted = svc.add_timeseries(db, set_id, batch)
    return BatchResult(received=received, inserted=inserted, duplicates=received - inserted)


@router.post("/{set_id}/skeleton", response_model=BatchResult)
def upload_skeleton(set_id: uuid.UUID, batch: SkeletonBatch, user: User = Depends(get_current_user),
                    db: Session = Depends(get_db), settings: Settings = Depends(get_settings_dep)) -> BatchResult:
    if len(batch.frames) > settings.max_skeleton_batch:
        raise HTTPException(413,
                            f"max {settings.max_skeleton_batch} frames per batch")
    _owned_or_404(db, user, set_id)
    received, inserted = svc.add_skeleton(db, set_id, batch)
    return BatchResult(received=received, inserted=inserted, duplicates=received - inserted)


@router.post("/{set_id}/coaching", response_model=CoachingCard)
async def coach_set(set_id: uuid.UUID, body: CoachingRequest, request: Request,
                    user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> CoachingCard:
    """guardrail -> SLM -> checks -> fallback. Idempotent: returns the stored card unless
    force_regenerate is true (so the mobile retry queue never triggers a second LLM run)."""
    row = await run_in_threadpool(_owned_or_404, db, user, set_id)
    if row.slm_coaching_json and not body.force_regenerate:
        return CoachingCard.model_validate(row.slm_coaching_json)
    if not guardrail.check(body.athlete_note).triggered:  # never rate-limit a safety referral
        enforce_cooldown(request, user, "coaching")

    payload = SetSummaryPayload.model_validate(row.payload)
    history = await run_in_threadpool(biomech_history_labels, user.id, payload.exercise, db, set_id)
    card = await request.app.state.coach.coach(payload, body.athlete_note, history)

    def _save() -> None:
        row.slm_coaching_json = card.model_dump(mode="json")
        row.coaching_source = card.source
        row.coached_at = datetime.now(timezone.utc)
        db.commit()

    await run_in_threadpool(_save)
    return card
