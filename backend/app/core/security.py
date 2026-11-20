"""Passwords, access tokens (JWT) and rotating refresh tokens.

Password scheme is ported unchanged from v1 (archive/legacy_v1/auth_utils.py):
bcrypt(sha256_hex(password)) — so imported v1 hashes keep working.
"""
from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core.config import Settings
from app.models import RefreshToken, User

ALGORITHM = "HS256"
ACCESS_TYPE = "access"

# A real bcrypt hash, used to spend the same time on unknown emails (no user enumeration by timing).
_DUMMY_HASH = bcrypt.hashpw(b"timing-equaliser", bcrypt.gensalt()).decode()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _prehash(password: str) -> bytes:
    return hashlib.sha256(password.encode()).hexdigest().encode()


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prehash(password), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str | None) -> bool:
    try:
        return bcrypt.checkpw(_prehash(password), (hashed or _DUMMY_HASH).encode("utf-8")) and hashed is not None
    except ValueError:  # malformed hash in DB
        return False


# ---------------- access tokens ----------------

def create_access_token(user_id: int, settings: Settings) -> str:
    now = _now()
    payload = {
        "sub": str(user_id),
        "type": ACCESS_TYPE,
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_expire_minutes),
    }
    return jwt.encode(payload, settings.secret_key.get_secret_value(), algorithm=ALGORITHM)


def decode_access_token(token: str, settings: Settings) -> int:
    """Returns the user id. Raises jwt.InvalidTokenError on anything wrong."""
    payload = jwt.decode(
        token,
        settings.secret_key.get_secret_value(),
        algorithms=[ALGORITHM],
        options={"require": ["exp", "sub", "type"]},
    )
    if payload.get("type") != ACCESS_TYPE:
        raise jwt.InvalidTokenError("not an access token")
    try:
        return int(payload["sub"])
    except (TypeError, ValueError) as e:
        raise jwt.InvalidTokenError("bad subject") from e


# ---------------- refresh tokens (rotating, reuse detection) ----------------

class RefreshError(Exception):
    """Generic failure; the API answers 401 without saying why."""


def _hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def issue_refresh_token(db: Session, user_id: int, settings: Settings,
                        family_id: uuid.UUID | None = None) -> tuple[str, RefreshToken]:
    raw = secrets.token_urlsafe(48)
    row = RefreshToken(
        user_id=user_id,
        token_hash=_hash_token(raw),
        family_id=family_id or uuid.uuid4(),
        expires_at=_now() + timedelta(days=settings.refresh_token_expire_days),
    )
    db.add(row)
    db.flush()
    return raw, row


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)  # SQLite returns naive


def revoke_family(db: Session, family_id: uuid.UUID) -> None:
    db.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=_now())
    )


def rotate_refresh_token(db: Session, raw: str, settings: Settings) -> tuple[int, str]:
    """Consume `raw`, return (user_id, new_raw). A second use of the same token (theft
    or replay) revokes the whole family, logging out every device in that chain."""
    row = db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == _hash_token(raw)).with_for_update()
    ).scalar_one_or_none()
    if row is None:
        raise RefreshError
    if row.revoked_at is not None:
        revoke_family(db, row.family_id)
        db.commit()
        raise RefreshError
    if _aware(row.expires_at) <= _now():
        raise RefreshError
    if db.get(User, row.user_id) is None:
        raise RefreshError
    new_raw, new_row = issue_refresh_token(db, row.user_id, settings, family_id=row.family_id)
    row.revoked_at = _now()
    row.replaced_by_id = new_row.id
    db.commit()
    return row.user_id, new_raw


def revoke_refresh_token(db: Session, raw: str) -> None:
    row = db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == _hash_token(raw))
    ).scalar_one_or_none()
    if row is not None:
        revoke_family(db, row.family_id)
        db.commit()
