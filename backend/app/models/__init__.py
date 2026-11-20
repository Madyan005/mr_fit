"""Import every model so `Base.metadata` is complete (Alembic autogenerate, tests)."""
from app.models.biomech import AthleteBaseline, BiomechanicalSet, SensorTimeseries, SkeletonFrame
from app.models.core import CustomExercise, Log, RefreshToken, User
from app.models.food import FoodItem, Meal, NutritionReference

__all__ = [
    "AthleteBaseline",
    "BiomechanicalSet",
    "CustomExercise",
    "FoodItem",
    "Log",
    "Meal",
    "NutritionReference",
    "RefreshToken",
    "SensorTimeseries",
    "SkeletonFrame",
    "User",
]
