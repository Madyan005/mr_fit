import datetime
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from database import engine, get_db
from models import Base, UserDB, LogDB
from schemas import AuthRequest, ParseRequest, LogCreate
from auth_utils import hash_password, verify_password, create_token, get_current_user
from ai_logic import parse_magic_input

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
    return db_log


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