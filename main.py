import datetime
import time
from collections import defaultdict
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from database import engine, get_db
from models import Base, UserDB, LogDB
from schemas import AuthRequest, ParseRequest, LogCreate, LogUpdate, CoachChatRequest
from auth_utils import hash_password, verify_password, create_token, get_current_user
from ai_logic import parse_magic_input, build_user_context, get_coach_advice, ask_coach

# =======================
# SIMPLE RATE LIMITER
# =======================
# In-memory store: { user_email: { endpoint: last_call_timestamp } }
_rate_store: dict[str, dict[str, float]] = defaultdict(dict)
AI_COOLDOWN_SECONDS = 10  # minimum seconds between AI calls per user per endpoint

def _check_rate_limit(user_email: str, endpoint: str):
    """Raise 429 if the user called this AI endpoint too recently."""
    now = time.time()
    last = _rate_store[user_email].get(endpoint, 0)
    remaining = AI_COOLDOWN_SECONDS - (now - last)
    if remaining > 0:
        raise HTTPException(
            status_code=429,
            detail=f"Too many AI requests. Please wait {remaining:.0f}s before trying again.",
        )
    _rate_store[user_email][endpoint] = now

# =======================
# CREATE TABLES
# =======================
Base.metadata.create_all(bind=engine)

# =======================
# APP & CORS
# =======================
app = FastAPI(title="MrFit API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve static frontend files (style.css, app.js)
app.mount("/static", StaticFiles(directory="static"), name="static")


# =======================
# FRONTEND ROUTE
# =======================
@app.get("/", summary="Serve frontend")
def serve_frontend():
    return FileResponse("static/index.html")


# =======================
# AUTH ROUTES
# =======================
@app.post("/auth/signup", summary="Create account")
def signup(req: AuthRequest, db: Session = Depends(get_db)):
    if db.query(UserDB).filter(UserDB.email == req.email).first():
        raise HTTPException(status_code=400, detail="Email already registered")
    user = UserDB(email=req.email, hashed_password=hash_password(req.password))
    db.add(user)
    db.commit()
    return {"access_token": create_token(user.email)}


@app.post("/auth/login", summary="Login")
def login(req: AuthRequest, db: Session = Depends(get_db)):
    user = db.query(UserDB).filter(UserDB.email == req.email).first()
    if not user or not verify_password(req.password, user.hashed_password):
        raise HTTPException(status_code=400, detail="Invalid credentials")
    return {"access_token": create_token(user.email)}


# =======================
# PARSE ROUTE  (auth-protected to prevent API abuse)
# =======================
@app.post("/parse-entry", summary="Parse natural-language fitness entry")
def parse_entry(
    req: ParseRequest,
    user=Depends(get_current_user),
):
    _check_rate_limit(user.email, "parse-entry")
    return parse_magic_input(req.text, req.prefill_exercise)


# =======================
# LOG ROUTES
# =======================
@app.post("/logs", summary="Save a log entry")
def create_log(
    log: LogCreate,
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # Always recompute volume server-side for exercises
    volume = log.volume
    if log.type == "EXERCISE":
        s = max(log.sets or 1, 1)
        r = max(log.reps or 0, 0)
        w = max(log.weight or 0.0, 0.0)
        volume = round(s * r * w, 2)

    db_log = LogDB(
        user_id=user.id,
        session_id=log.session_id,
        type=log.type,
        name=log.name,
        sets=log.sets,
        reps=log.reps,
        weight=log.weight,
        calories=log.calories,
        volume=volume,
        raw_text=log.raw_text,
    )
    db.add(db_log)
    db.commit()
    db.refresh(db_log)
    return {
        "id": db_log.id,
        "user_id": db_log.user_id,
        "session_id": db_log.session_id,
        "type": db_log.type,
        "name": db_log.name,
        "sets": db_log.sets,
        "reps": db_log.reps,
        "weight": db_log.weight,
        "calories": db_log.calories,
        "volume": db_log.volume,
        "raw_text": db_log.raw_text,
        "created_at": db_log.created_at.isoformat() if db_log.created_at else None,
    }


@app.get("/logs", summary="Get log entries")
def get_logs(
    date: Optional[str] = None,
    limit: int = Query(default=200, le=500, ge=1),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    q = db.query(LogDB).filter(LogDB.user_id == user.id)
    if date:
        try:
            start = datetime.datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")
        end = start + datetime.timedelta(days=1)
        q = q.filter(LogDB.created_at >= start, LogDB.created_at < end)
    return q.order_by(LogDB.created_at.desc()).limit(limit).all()


# NOTE: /logs/heatmap MUST be defined before /logs/{log_id} — FastAPI matches
# literal path segments before parameterised ones only when ordered correctly.
@app.get("/logs/heatmap", summary="Get heatmap data for the user")
def get_heatmap(
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    logs = db.query(LogDB).filter(LogDB.user_id == user.id).all()

    heatmap_data = {}
    for log in logs:
        date_str = log.created_at.date().isoformat()
        if date_str not in heatmap_data:
            heatmap_data[date_str] = {"count": 0, "details": []}
        heatmap_data[date_str]["details"].append({
            "id": log.id,
            "type": log.type,
            "name": log.name,
            "sets": log.sets,
            "reps": log.reps,
            "weight": log.weight,
            "calories": log.calories,
            "volume": log.volume,
            "session_id": log.session_id,
            "created_at": log.created_at.isoformat(),
        })

    for date_str, data in heatmap_data.items():
        session_ids = set()
        ungrouped_count = 0
        for d in data["details"]:
            if d.get("session_id"):
                session_ids.add(d["session_id"])
            else:
                ungrouped_count += 1
        data["count"] = len(session_ids) + ungrouped_count

    return heatmap_data


@app.delete("/logs/{log_id}", summary="Delete a log entry")
def delete_log(
    log_id: int,
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    log = db.query(LogDB).filter(LogDB.id == log_id, LogDB.user_id == user.id).first()
    if not log:
        raise HTTPException(status_code=404, detail="Log not found")
    db.delete(log)
    db.commit()
    return {"status": "deleted"}


@app.put("/logs/{log_id}", summary="Update a log entry")
def update_log(
    log_id: int,
    log_update: LogUpdate,
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    log = db.query(LogDB).filter(LogDB.id == log_id, LogDB.user_id == user.id).first()
    if not log:
        raise HTTPException(status_code=404, detail="Log not found")

    update_data = log_update.model_dump(exclude_unset=True)
    for key, value in update_data.items():
        setattr(log, key, value)

    if log.type == "EXERCISE":
        s = max(log.sets or 1, 1)
        r = max(log.reps or 0, 0)
        w = max(log.weight or 0.0, 0.0)
        log.volume = round(s * r * w, 2)

    db.commit()
    db.refresh(log)
    return {
        "id": log.id,
        "user_id": log.user_id,
        "session_id": log.session_id,
        "type": log.type,
        "name": log.name,
        "sets": log.sets,
        "reps": log.reps,
        "weight": log.weight,
        "calories": log.calories,
        "volume": log.volume,
        "raw_text": log.raw_text,
        "created_at": log.created_at.isoformat() if log.created_at else None,
    }


# =======================
# STATS ROUTE
# =======================
@app.get("/stats", summary="Aggregated stats for the last N days")
def stats(
    days: int = Query(default=7, ge=1, le=90),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # Use date boundaries in UTC to match how logs are stored
    today = datetime.datetime.utcnow().date()
    start_date = datetime.datetime.combine(
        today - datetime.timedelta(days=days - 1),
        datetime.time.min,
    )
    logs = (
        db.query(LogDB)
        .filter(LogDB.user_id == user.id, LogDB.created_at >= start_date)
        .all()
    )

    stats_map = {
        (today - datetime.timedelta(days=i)).isoformat(): {"volume": 0, "calories": 0}
        for i in range(days - 1, -1, -1)   # chronological order
    }
    total_v = total_c = workouts = meals = 0

    for entry in logs:
        d_str = entry.created_at.date().isoformat()
        if d_str not in stats_map:
            continue
        if entry.type == "EXERCISE":
            v = entry.volume or 0
            stats_map[d_str]["volume"] += v
            total_v += v
            workouts += 1
        else:
            c = entry.calories or 0
            stats_map[d_str]["calories"] += c
            total_c += c
            meals += 1

    return {
        "avg_volume": round(total_v / days),
        "avg_calories": round(total_c / days),
        "total_workouts": workouts,
        "total_meals": meals,
        "days": [{"date": k, **v} for k, v in stats_map.items()],
    }


# =======================
# AI COACH ROUTE
# =======================
@app.get("/ai-coach", summary="Get AI coaching advice based on user analytics")
def ai_coach(
    days: int = Query(default=14, ge=7, le=90),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _check_rate_limit(user.email, "ai-coach")
    context = build_user_context(user, db, days=days)
    if not context.get("has_data"):
        return {
            "summary": "No workout or nutrition data found in the selected period. Start logging to get personalized coaching!",
            "strengths": [],
            "weaknesses": [],
            "recommendations": ["Begin logging your workouts and meals to unlock AI coaching insights."],
            "next_workout": [],
        }
    return get_coach_advice(context)


# =======================
# CONVERSATIONAL COACH CHAT ROUTE
# =======================
@app.post("/coach-chat", summary="Ask the AI coach a question")
def coach_chat(
    req: CoachChatRequest,
    days: int = Query(default=14, ge=7, le=90),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _check_rate_limit(user.email, "coach-chat")
    context = build_user_context(user, db, days=days)
    if not context.get("has_data"):
        return {
            "answer": "I don't have enough data to answer yet. Start logging your workouts and meals so I can give you personalized advice!",
            "workout_plan": [],
        }
    return ask_coach(req.message, context, history=req.history)


# =======================
# HEALTH CHECK
# =======================
@app.get("/health")
def health():
    return {"status": "ok", "version": "2.0.0"}


# =======================
# ENTRY POINT
# =======================
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)