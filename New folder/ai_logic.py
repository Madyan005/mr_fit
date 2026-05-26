import os
import json
import warnings
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
