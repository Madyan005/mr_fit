"""Closed vocabularies shared by ORM CHECK constraints, Pydantic schemas and migrations.
Changing any of these requires a migration (CHECK constraints) and a contract bump.
"""

BIOMECH_EXERCISES: tuple[str, ...] = ("squat", "deadlift", "bench_press", "push_up")
GOALS: tuple[str, ...] = ("max_strength", "hypertrophy")
DATA_SOURCES: tuple[str, ...] = ("simulated", "real")
COACHING_SOURCES: tuple[str, ...] = ("llm", "fallback", "guardrail")
LOG_TYPES: tuple[str, ...] = ("EXERCISE", "NUTRITION")
MEAL_SOURCES: tuple[str, ...] = ("manual", "gemini_text", "vision")
FAULT_FLAGS: tuple[str, ...] = ("valgus", "lumbar_flexion", "incomplete_rom")
VELOCITY_SOURCES: tuple[str, ...] = ("imu", "vision", "fused")
# Velocity-loss caps by goal (ROLE_BRIEFING: Max Strength 20 %, Hypertrophy 30 %).
GOAL_VL_CAP_PCT: dict[str, float] = {"max_strength": 20.0, "hypertrophy": 30.0}


def sql_in(column: str, values: tuple[str, ...]) -> str:
    """Render `column IN ('a','b')` for CHECK constraints (values are code constants)."""
    quoted = ", ".join(f"'{v}'" for v in values)
    return f"{column} IN ({quoted})"
