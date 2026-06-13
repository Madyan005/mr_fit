import os
import json
import logging
import warnings

logger = logging.getLogger(__name__)
from typing import Optional
from dotenv import load_dotenv
from google import genai
from fastapi import HTTPException

# =======================
# CONFIG
# =======================
load_dotenv("mr_fit.env")

GEMINI_KEY = os.getenv("GEMINI_API_KEY")

if not GEMINI_KEY:
    warnings.warn("GEMINI_API_KEY not set — /parse-entry will fail")

gemini_client = genai.Client(api_key=GEMINI_KEY)


# =======================
# AI PARSE FUNCTION
# =======================

def parse_magic_input(text: str, prefill_exercise: Optional[str] = None) -> list[dict]:
    """
    Send text to Gemini and get back a LIST of parsed fitness/nutrition items.
    Each item has: type, name, calories, sets, reps, weight, volume.
    """
    prompt = f"""
User input: "{text}"
Prefilled Exercise: "{prefill_exercise or 'None'}"

Task: Extract EVERY fitness or nutrition item mentioned from the user input.
- If the user mentions food (e.g. 'foul', 'taameya', 'chicken', 'salad'), set type to NUTRITION and estimate calories if not explicitly mentioned.
- If it describes a workout / exercise, set type to EXERCISE and map to a standard exercise name.
- If a Prefilled Exercise name is provided, use that as the exercise name.
- If a user specifies multiple sets for an exercise (e.g., 'bench press 30kg for 10 and 50kg for 8' or '3 sets of 10 at 50kg'), return an array of objects, one for each individual set. For '3 sets of 10 at 50kg', return 3 objects with reps=10 and weight=50. Each object represents one set, so the 'sets' value should be 1 or omitted.
- Return ONLY a valid JSON LIST of objects (even if there is only one item) with these fields (omit fields that don't apply):
  [{{"type": "EXERCISE" | "NUTRITION", "name": "<string>", "calories": <int|null>, "sets": <int|null>, "reps": <int|null>, "weight": <float|null>}}]
- No markdown, no explanation, just the JSON list.
"""
    try:
        response = gemini_client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
            config=genai.types.GenerateContentConfig(
                response_mime_type="application/json",
            )
        )
        data_list = json.loads(response.text)
    except Exception as e:
        logger.exception("AI parse error")
        raise HTTPException(status_code=502, detail=f"AI parse error: {str(e)}")

    if not isinstance(data_list, list):
        # Fallback in case the AI returns a single object instead of a list
        data_list = [data_list]

    parsed_items = []
    for data in data_list:
        # Validate response has required fields
        if "type" not in data or data["type"] not in ("EXERCISE", "NUTRITION"):
            continue  # skip invalid format instead of throwing error for entire list

        # Compute volume server-side (single source of truth)
        if data.get("type") == "EXERCISE":
            s = max(data.get("sets") or 1, 1)
            r = max(data.get("reps") or 0, 0)
            w = max(data.get("weight") or 0.0, 0.0)
            data["volume"] = round(s * r * w, 2)
        else:
            data["volume"] = None

        parsed_items.append(data)

    if not parsed_items:
        raise HTTPException(status_code=502, detail="AI returned unexpected format")

    return parsed_items


# =======================
# MUSCLE GROUP MAPPING
# =======================
# Maps common exercise names to primary muscle groups for balance analysis
EXERCISE_MUSCLE_MAP = {
    # Chest
    "bench press": "chest", "incline bench press": "chest", "decline bench press": "chest",
    "dumbbell press": "chest", "chest press": "chest", "push up": "chest", "pushup": "chest",
    "chest fly": "chest", "dumbbell fly": "chest", "cable fly": "chest", "pec deck": "chest",
    # Back
    "pull up": "back", "pullup": "back", "chin up": "back", "lat pulldown": "back",
    "barbell row": "back", "bent over row": "back", "dumbbell row": "back", "cable row": "back",
    "seated row": "back", "t-bar row": "back", "deadlift": "back",
    # Shoulders
    "overhead press": "shoulders", "shoulder press": "shoulders", "military press": "shoulders",
    "lateral raise": "shoulders", "front raise": "shoulders", "rear delt fly": "shoulders",
    "arnold press": "shoulders", "face pull": "shoulders", "upright row": "shoulders",
    # Legs
    "squat": "legs", "back squat": "legs", "front squat": "legs", "leg press": "legs",
    "lunge": "legs", "lunges": "legs", "leg extension": "legs", "leg curl": "legs",
    "hamstring curl": "legs", "calf raise": "legs", "romanian deadlift": "legs",
    "hip thrust": "legs", "bulgarian split squat": "legs", "goblet squat": "legs",
    # Arms
    "bicep curl": "arms", "hammer curl": "arms", "preacher curl": "arms",
    "tricep pushdown": "arms", "tricep extension": "arms", "skull crusher": "arms",
    "concentration curl": "arms", "dips": "arms", "cable curl": "arms",
    # Core
    "plank": "core", "crunch": "core", "sit up": "core", "leg raise": "core",
    "russian twist": "core", "ab wheel": "core", "cable crunch": "core",
    "hanging leg raise": "core", "mountain climber": "core",
}


def _classify_muscle_group(exercise_name: str) -> str:
    """Map an exercise name to its primary muscle group."""
    name_lower = exercise_name.lower().strip()
    for pattern, group in EXERCISE_MUSCLE_MAP.items():
        if pattern in name_lower:
            return group
    return "other"


# =======================
# BUILD USER CONTEXT (Analytics Summary)
# =======================

def build_user_context(user, db, days: int = 14) -> dict:
    """
    Compute an analytics summary from the user's logs.
    This summary — NOT raw DB rows — is what gets sent to the coach model.
    """
    import datetime
    from collections import defaultdict
    from models import LogDB

    now = datetime.datetime.utcnow()
    cutoff = now - datetime.timedelta(days=days)

    logs = (
        db.query(LogDB)
        .filter(LogDB.user_id == user.id, LogDB.created_at >= cutoff)
        .order_by(LogDB.created_at.asc())
        .all()
    )

    if not logs:
        return {
            "period_days": days,
            "has_data": False,
            "message": "No logs found in the selected period.",
        }

    # ---- Separate exercise & nutrition logs ----
    exercise_logs = [l for l in logs if l.type == "EXERCISE"]
    nutrition_logs = [l for l in logs if l.type == "NUTRITION"]

    # ---- Workout days & weekly frequency ----
    workout_dates = sorted(set(l.created_at.date() for l in exercise_logs))
    num_workout_days = len(workout_dates)
    weeks = max(days / 7, 1)
    weekly_workout_frequency = round(num_workout_days / weeks, 1)

    # ---- Total training volume ----
    total_volume = round(sum(l.volume or 0 for l in exercise_logs), 2)

    # ---- Average daily calories ----
    cal_by_day: dict[str, int] = defaultdict(int)
    for l in nutrition_logs:
        cal_by_day[l.created_at.date().isoformat()] += (l.calories or 0)
    nutrition_days = len(cal_by_day)
    avg_daily_calories = round(sum(cal_by_day.values()) / nutrition_days) if nutrition_days else 0

    # ---- Top exercises (by total volume) ----
    vol_by_exercise: dict[str, float] = defaultdict(float)
    count_by_exercise: dict[str, int] = defaultdict(int)
    for l in exercise_logs:
        vol_by_exercise[l.name] += (l.volume or 0)
        count_by_exercise[l.name] += 1
    top_exercises = sorted(vol_by_exercise.items(), key=lambda x: x[1], reverse=True)[:8]
    top_exercises_list = [
        {"name": name, "total_volume": round(vol, 2), "total_sets": count_by_exercise[name]}
        for name, vol in top_exercises
    ]

    # ---- Exercise progression history (weight over time per exercise) ----
    progression: dict[str, list] = defaultdict(list)
    for l in exercise_logs:
        if l.weight and l.weight > 0:
            progression[l.name].append({
                "date": l.created_at.date().isoformat(),
                "weight": l.weight,
                "reps": l.reps,
            })
    # Keep only the top 6 exercises by frequency to avoid bloat
    top_prog_names = sorted(progression.keys(), key=lambda n: len(progression[n]), reverse=True)[:6]
    progression_summary = {name: progression[name] for name in top_prog_names}

    # ---- Personal records (max weight per exercise) ----
    pr_map: dict[str, dict] = {}
    for l in exercise_logs:
        w = l.weight or 0
        if w > 0:
            if l.name not in pr_map or w > pr_map[l.name]["weight"]:
                pr_map[l.name] = {
                    "weight": w,
                    "reps": l.reps,
                    "date": l.created_at.date().isoformat(),
                }
    personal_records = [{"exercise": k, **v} for k, v in pr_map.items()]
    personal_records.sort(key=lambda x: x["weight"], reverse=True)

    # ---- Last workout date ----
    last_workout_date = workout_dates[-1].isoformat() if workout_dates else None

    # ---- Workout consistency (% of days with a workout) ----
    workout_consistency_pct = round((num_workout_days / days) * 100, 1)

    # ---- Muscle balance summary ----
    vol_by_muscle: dict[str, float] = defaultdict(float)
    for l in exercise_logs:
        group = _classify_muscle_group(l.name)
        vol_by_muscle[group] += (l.volume or 0)
    total_muscle_vol = sum(vol_by_muscle.values()) or 1
    muscle_balance = {
        group: {
            "volume": round(vol, 2),
            "pct": round((vol / total_muscle_vol) * 100, 1),
        }
        for group, vol in sorted(vol_by_muscle.items(), key=lambda x: x[1], reverse=True)
    }

    return {
        "period_days": days,
        "has_data": True,
        "weekly_workout_frequency": weekly_workout_frequency,
        "total_training_volume": total_volume,
        "avg_daily_calories": avg_daily_calories,
        "nutrition_days_logged": nutrition_days,
        "top_exercises": top_exercises_list,
        "exercise_progression": progression_summary,
        "personal_records": personal_records,
        "last_workout_date": last_workout_date,
        "workout_consistency_pct": workout_consistency_pct,
        "muscle_balance": muscle_balance,
        "num_workout_days": num_workout_days,
        "num_exercise_entries": len(exercise_logs),
        "num_nutrition_entries": len(nutrition_logs),
    }


# =======================
# COACH AI  (separate from Parser AI)
# =======================

def get_coach_advice(user_context: dict) -> dict:
    """
    Send a pre-built analytics SUMMARY (never raw DB rows) to the coach model.
    Returns structured coaching advice.
    """
    prompt = f"""
You are an expert fitness coach AI. Analyze the following user analytics summary
and provide personalized coaching advice.

User Analytics (last {user_context.get("period_days", 14)} days):
{json.dumps(user_context, indent=2, default=str)}

Respond ONLY with a valid JSON object using this exact schema:
{{
  "summary": "<2-3 sentence overview of the user's current fitness status>",
  "strengths": ["<strength 1>", "<strength 2>", ...],
  "weaknesses": ["<weakness 1>", "<weakness 2>", ...],
  "recommendations": ["<actionable recommendation 1>", "<actionable recommendation 2>", ...],
  "next_workout": [
    {{"exercise": "<name>", "sets": <int>, "reps": <int>, "weight": <float or null>, "notes": "<brief note>"}}
  ]
}}

Guidelines:
- Be specific and actionable, reference the user's actual numbers.
- If muscle balance data shows imbalances, address them.
- Recommend progressive overload based on their PR history.
- If nutrition data is sparse, mention the importance of tracking.
- Suggest a concrete next workout (4-6 exercises) that addresses weaknesses.
- No markdown, no explanation outside the JSON.
"""
    try:
        response = gemini_client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
            config=genai.types.GenerateContentConfig(
                response_mime_type="application/json",
            ),
        )
        result = json.loads(response.text)
    except Exception as e:
        logger.exception("Coach AI error")
        raise HTTPException(status_code=502, detail=f"Coach AI error: {str(e)}")

    # Ensure required keys exist with sensible defaults
    return {
        "summary": result.get("summary", ""),
        "strengths": result.get("strengths", []),
        "weaknesses": result.get("weaknesses", []),
        "recommendations": result.get("recommendations", []),
        "next_workout": result.get("next_workout", []),
    }


# =======================
# CONVERSATIONAL COACH AI  (separate from Parser & Report Coach)
# =======================

def ask_coach(question: str, user_context: dict, history: list = None) -> dict:
    """
    Conversational coach: answer a free-form user question using their
    pre-built analytics summary.  Never sees raw DB rows.

    history: optional list of previous turns [{\"role\": \"user\"|\"coach\", \"text\": \"...\"}]
             injected into the prompt for multi-turn context.
    """
    # Guard: never call Gemini if there is no data (avoids hallucinated coaching)
    if not user_context.get("has_data"):
        return {
            "answer": "You don't have enough workout history yet. Start logging workouts for personalized coaching.",
            "workout_plan": [],
        }

    # Build conversation history block (capped upstream at 10 turns by schema validator)
    history_block = ""
    if history:
        turns = []
        for turn in history:
            role = turn.get("role", "user").capitalize()
            text = str(turn.get("text", "")).strip()
            if text:
                turns.append(f"{role}: {text}")
        if turns:
            history_block = "\n=== CONVERSATION HISTORY (most recent last) ===\n" + "\n".join(turns) + "\n"

    prompt = f"""
You are a conversational fitness coach AI. The user is asking you a question
about their training. Use the analytics summary below to give a helpful,
data-driven answer.

=== USER ANALYTICS (last {user_context.get("period_days", 14)} days) ===
{json.dumps(user_context, indent=2, default=str)}
{history_block}
=== CURRENT USER QUESTION ===
"{question}"

=== RESPONSE RULES ===
1. Answer the user's question directly and concisely. Use prior conversation history for context if relevant.
2. Reference their actual numbers (PRs, volume, frequency, muscle balance, etc.) when relevant.
3. If the user asks "what should I train today" or similar:
   - Check their last_workout_date and muscle_balance to decide which muscle groups need work.
   - Consider recovery time (avoid training the same group two days in a row).
   - Prioritize weak/under-trained muscle groups from the muscle_balance data.
   - Populate the workout_plan array with 4-6 exercises.
4. If the user asks about progression, analyze personal_records and exercise_progression history.
5. If nutrition_days_logged is low or avg_daily_calories is 0, mention the importance of nutrition tracking.
6. Keep the answer practical, specific, and under 200 words.
7. No markdown formatting in the answer text.

Respond ONLY with a valid JSON object using this exact schema:
{{
  "answer": "<direct answer to the user's question>",
  "workout_plan": [
    {{"exercise": "<name>", "sets": <int>, "reps": <int>, "weight": <float or null>, "notes": "<brief note>"}}
  ]
}}

If the question does not warrant a workout plan, return an empty array for workout_plan.
No markdown, no explanation outside the JSON.
"""
    try:
        response = gemini_client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
            config=genai.types.GenerateContentConfig(
                response_mime_type="application/json",
            ),
        )
        result = json.loads(response.text)
    except Exception as e:
        logger.exception("Coach chat error")
        raise HTTPException(status_code=502, detail=f"Coach chat error: {str(e)}")

    return {
        "answer": result.get("answer", ""),
        "workout_plan": result.get("workout_plan", []),
    }
