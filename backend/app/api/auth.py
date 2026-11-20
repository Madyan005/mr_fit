from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_db, get_settings_dep
from app.core.config import Settings
from app.core.security import (
    RefreshError,
    create_access_token,
    hash_password,
    issue_refresh_token,
    revoke_refresh_token,
    rotate_refresh_token,
    verify_password,
)
from app.models import User
from app.schemas.auth import AuthRequest, RefreshRequest, TokenPair

router = APIRouter(prefix="/auth", tags=["auth"])


def _pair(db: Session, user_id: int, settings: Settings) -> TokenPair:
    raw, _ = issue_refresh_token(db, user_id, settings)
    db.commit()
    return TokenPair(
        access_token=create_access_token(user_id, settings),
        refresh_token=raw,
        expires_in=settings.access_token_expire_minutes * 60,
    )


@router.post("/signup", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
def signup(req: AuthRequest, db: Session = Depends(get_db),
           settings: Settings = Depends(get_settings_dep)) -> TokenPair:
    if db.scalar(select(User.id).where(User.email == req.email)) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
    user = User(email=req.email, hashed_password=hash_password(req.password))
    db.add(user)
    try:
        db.flush()
    except IntegrityError:  # concurrent signup with the same email
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered") from None
    return _pair(db, user.id, settings)


@router.post("/login", response_model=TokenPair)
def login(req: AuthRequest, db: Session = Depends(get_db),
          settings: Settings = Depends(get_settings_dep)) -> TokenPair:
    user = db.scalars(select(User).where(User.email == req.email)).first()
    # verify_password runs bcrypt even for unknown emails (constant-ish timing).
    if not verify_password(req.password, user.hashed_password if user else None) or user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    return _pair(db, user.id, settings)


@router.post("/refresh", response_model=TokenPair)
def refresh(req: RefreshRequest, db: Session = Depends(get_db),
            settings: Settings = Depends(get_settings_dep)) -> TokenPair:
    try:
        user_id, new_raw = rotate_refresh_token(db, req.refresh_token, settings)
    except RefreshError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token") from None
    return TokenPair(
        access_token=create_access_token(user_id, settings),
        refresh_token=new_raw,
        expires_in=settings.access_token_expire_minutes * 60,
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(req: RefreshRequest, db: Session = Depends(get_db)) -> None:
    """Revokes the refresh-token family (this device chain). Access tokens expire on their own."""
    revoke_refresh_token(db, req.refresh_token)
