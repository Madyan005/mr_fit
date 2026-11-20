import os
import datetime
import hashlib
import bcrypt
from dotenv import load_dotenv
from fastapi import Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session
from jose import jwt, JWTError

from database import get_db
from models import UserDB

# =======================
# CONFIG
# =======================
load_dotenv("mr_fit.env")

SECRET_KEY = os.getenv("SECRET_KEY", "DEV_SECRET_ONLY_CHANGE_ME")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 7

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="auth/login")

# =======================
# PASSWORD HELPERS
# =======================

def hash_password(password: str) -> str:
    # Pre-hash with SHA-256 to bypass bcrypt's 72-byte limit
    sha_pw = hashlib.sha256(password.encode()).hexdigest().encode()
    salt = bcrypt.gensalt()
    return bcrypt.hashpw(sha_pw, salt).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    sha_pw = hashlib.sha256(password.encode()).hexdigest().encode()
    return bcrypt.checkpw(sha_pw, hashed.encode("utf-8"))


# =======================
# JWT HELPERS
# =======================

def create_token(email: str) -> str:
    payload = {
        "sub": email,
        "exp": datetime.datetime.utcnow() + datetime.timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email = payload.get("sub")
        if not email:
            raise HTTPException(status_code=401, detail="Invalid token")
        user = db.query(UserDB).filter(UserDB.email == email).first()
        if not user:
            raise HTTPException(status_code=401, detail="User not found")
        return user
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
