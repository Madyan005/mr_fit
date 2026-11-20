from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from sqlalchemy.orm import Session

from app.models import RefreshToken, User
from tests.conftest import auth_headers, signup


def test_signup_login_and_me(client):
    t = signup(client, "A@Test.dev ")
    assert t["token_type"] == "bearer" and t["expires_in"] == 30 * 60
    assert client.get("/logs", headers=auth_headers(t)).status_code == 200
    r = client.post("/auth/login", json={"email": "a@test.dev", "password": "secret123"})
    assert r.status_code == 200 and r.json()["refresh_token"] != t["refresh_token"]


def test_duplicate_signup_and_bad_login(client):
    signup(client)
    assert client.post("/auth/signup", json={"email": "athlete@test.dev", "password": "secret123"}).status_code == 409
    assert client.post("/auth/login", json={"email": "athlete@test.dev", "password": "wrong-pw"}).status_code == 401
    assert client.post("/auth/login", json={"email": "nobody@test.dev", "password": "secret123"}).status_code == 401
    assert client.post("/auth/signup", json={"email": "x@test.dev", "password": "123"}).status_code == 422


def test_v1_password_hash_still_verifies(client, engine):
    """v1 stored bcrypt(sha256_hex(pw)); imported users must be able to log in."""
    v1_hash = bcrypt.hashpw(hashlib.sha256(b"oldpass1").hexdigest().encode(), bcrypt.gensalt()).decode()
    with Session(engine) as s:
        s.add(User(email="v1@test.dev", hashed_password=v1_hash))
        s.commit()
    assert client.post("/auth/login", json={"email": "v1@test.dev", "password": "oldpass1"}).status_code == 200


def test_refresh_rotates_and_detects_reuse(client):
    t1 = signup(client)
    r = client.post("/auth/refresh", json={"refresh_token": t1["refresh_token"]})
    assert r.status_code == 200
    t2 = r.json()
    assert t2["refresh_token"] != t1["refresh_token"]
    assert client.get("/logs", headers=auth_headers(t2)).status_code == 200

    # Replaying the already-rotated token = theft signal: whole family revoked.
    assert client.post("/auth/refresh", json={"refresh_token": t1["refresh_token"]}).status_code == 401
    assert client.post("/auth/refresh", json={"refresh_token": t2["refresh_token"]}).status_code == 401


def test_other_login_family_survives_reuse_revocation(client):
    a = signup(client)
    b = client.post("/auth/login", json={"email": "athlete@test.dev", "password": "secret123"}).json()
    client.post("/auth/refresh", json={"refresh_token": a["refresh_token"]})
    client.post("/auth/refresh", json={"refresh_token": a["refresh_token"]})  # reuse -> family A revoked
    assert client.post("/auth/refresh", json={"refresh_token": b["refresh_token"]}).status_code == 200


def test_expired_refresh_token_rejected(client, engine):
    t = signup(client)
    with Session(engine) as s:
        for row in s.query(RefreshToken):
            row.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
        s.commit()
    assert client.post("/auth/refresh", json={"refresh_token": t["refresh_token"]}).status_code == 401


def test_logout_revokes(client):
    t = signup(client)
    assert client.post("/auth/logout", json={"refresh_token": t["refresh_token"]}).status_code == 204
    assert client.post("/auth/refresh", json={"refresh_token": t["refresh_token"]}).status_code == 401


def test_bad_tokens_rejected(client):
    t = signup(client)
    assert client.get("/logs").status_code == 401
    assert client.get("/logs", headers={"Authorization": f"Bearer {t['refresh_token']}"}).status_code == 401
    forged = jwt.encode({"sub": "1", "type": "access", "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
                        "a-different-secret-key-that-is-long-enough", algorithm="HS256")
    assert client.get("/logs", headers={"Authorization": f"Bearer {forged}"}).status_code == 401
    wrong_type = jwt.encode({"sub": "1", "type": "refresh", "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
                            "s" * 40, algorithm="HS256")
    assert client.get("/logs", headers={"Authorization": f"Bearer {wrong_type}"}).status_code == 401
    expired = jwt.encode({"sub": "1", "type": "access", "exp": datetime.now(timezone.utc) - timedelta(seconds=5)},
                         "s" * 40, algorithm="HS256")
    assert client.get("/logs", headers={"Authorization": f"Bearer {expired}"}).status_code == 401


def test_refresh_token_stored_hashed_only(client, engine):
    t = signup(client)
    with Session(engine) as s:
        hashes = [r.token_hash for r in s.query(RefreshToken)]
    assert t["refresh_token"] not in hashes
    assert hashlib.sha256(t["refresh_token"].encode()).hexdigest() in hashes
