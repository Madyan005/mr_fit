"""OPTIONAL food feature tables (isolated). Created by migrations but nothing in the
core biomechanics flow depends on them. v1 NUTRITION rows stay in `logs`."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import CheckConstraint, Float, ForeignKey, Index, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TZDateTime
from app.models.constants import MEAL_SOURCES, sql_in


class NutritionReference(Base):
    """Per-100 g reference values (e.g. imported from a food composition table)."""

    __tablename__ = "nutrition_reference"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    kcal_per_100g: Mapped[float] = mapped_column(Float, nullable=False)
    protein_g_per_100g: Mapped[float | None] = mapped_column(Float)
    carbs_g_per_100g: Mapped[float | None] = mapped_column(Float)
    fat_g_per_100g: Mapped[float | None] = mapped_column(Float)
    source: Mapped[str | None] = mapped_column(String(100))  # dataset name/version

    __table_args__ = (Index("uq_nutrition_reference_name", "name", unique=True),)


class Meal(Base):
    __tablename__ = "meals"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    eaten_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    name: Mapped[str | None] = mapped_column(String(200))
    total_kcal: Mapped[float | None] = mapped_column(Float)
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="manual")
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime, nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint(sql_in("source", MEAL_SOURCES), name="source"),
        Index("ix_meals_user_id_eaten_at", "user_id", "eaten_at"),
    )


class FoodItem(Base):
    __tablename__ = "food_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    meal_id: Mapped[int] = mapped_column(
        ForeignKey("meals.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    grams: Mapped[float | None] = mapped_column(Float)
    kcal: Mapped[float | None] = mapped_column(Float)
    protein_g: Mapped[float | None] = mapped_column(Float)
    carbs_g: Mapped[float | None] = mapped_column(Float)
    fat_g: Mapped[float | None] = mapped_column(Float)
    reference_id: Mapped[int | None] = mapped_column(
        ForeignKey("nutrition_reference.id", ondelete="SET NULL")
    )
    confidence: Mapped[float | None] = mapped_column(Float)  # recognizer confidence 0..1

    __table_args__ = (
        CheckConstraint("confidence IS NULL OR (confidence >= 0 AND confidence <= 1)", name="confidence"),
        Index("ix_food_items_meal_id", "meal_id"),
    )
