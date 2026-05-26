import datetime
from sqlalchemy import Column, Integer, String, Float, DateTime, ForeignKey
from database import Base

# =======================
# DATABASE MODELS
# =======================

class UserDB(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True)
    hashed_password = Column(String)


class LogDB(Base):
    __tablename__ = "logs"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    type = Column(String)       # EXERCISE or NUTRITION
    name = Column(String)
    sets = Column(Integer, nullable=True)
    reps = Column(Integer, nullable=True)
    weight = Column(Float, nullable=True)
    calories = Column(Integer, nullable=True)
    volume = Column(Float, nullable=True)
    raw_text = Column(String)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
