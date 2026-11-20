def exercise_volume(sets: int | None, reps: int | None, weight: float | None) -> float:
    """v1 rule (single source of truth): max(sets,1) * max(reps,0) * max(weight,0)."""
    return round(max(sets or 1, 1) * max(reps or 0, 0) * max(weight or 0.0, 0.0), 2)
