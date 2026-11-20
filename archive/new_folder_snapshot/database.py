import os
from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

# =======================
# CONFIG  (load .env FIRST so os.getenv picks values up)
# =======================
load_dotenv("mr_fit.env")

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./mrfit.db")

# =======================
# DB SETUP
# =======================
engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
