"""v2 core: harden v1 tables, add auth/library/biomechanics/food tables.

- users: NOT NULL email/password, created_at; drop redundant ix_users_id
- logs : created_at -> timestamptz (naive values interpreted as UTC), NOT NULL
         user_id/type/name, FK ON DELETE CASCADE, CHECK type, (user_id, created_at) index
- new  : refresh_tokens, custom_exercises, biomechanical_sets, athlete_baselines,
         meals, food_items, nutrition_reference (optional food feature)

PostgreSQL only. Every statement is guarded (IF [NOT] EXISTS) so a partial run can be retried.

Revision ID: 0002_v2_core
Revises: 0001_v1_baseline
Create Date: 2026-11-20
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

from app.models.constants import (
    BIOMECH_EXERCISES,
    COACHING_SOURCES,
    DATA_SOURCES,
    GOALS,
    LOG_TYPES,
    MEAL_SOURCES,
    sql_in,
)

revision = "0002_v2_core"
down_revision = "0001_v1_baseline"
branch_labels = None
depends_on = None

TZ = sa.DateTime(timezone=True)
NOW = sa.text("now()")


def _require_postgres() -> None:
    name = op.get_context().dialect.name  # works online and in offline (--sql) mode
    if name != "postgresql":
        raise RuntimeError(f"MR-Fit migrations target PostgreSQL/TimescaleDB, not {name!r}")


def upgrade() -> None:
    _require_postgres()

    # ---------- users ----------
    op.execute("DROP INDEX IF EXISTS ix_users_id")
    op.execute(
        """
        ALTER TABLE users
          ALTER COLUMN email SET NOT NULL,
          ALTER COLUMN hashed_password SET NOT NULL,
          ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now()
        """
    )

    # ---------- logs ----------
    op.execute("DROP INDEX IF EXISTS ix_logs_id")
    op.execute(
        """
        DO $mrfit$
        BEGIN
          IF (SELECT data_type FROM information_schema.columns
              WHERE table_name = 'logs' AND column_name = 'created_at') = 'timestamp without time zone'
          THEN
            ALTER TABLE logs ALTER COLUMN created_at TYPE TIMESTAMPTZ
              USING created_at AT TIME ZONE 'UTC';
          END IF;
        END
        $mrfit$
        """
    )
    op.execute("UPDATE logs SET created_at = now() WHERE created_at IS NULL")
    op.execute(
        f"""
        ALTER TABLE logs
          ALTER COLUMN created_at SET DEFAULT now(),
          ALTER COLUMN created_at SET NOT NULL,
          ALTER COLUMN user_id SET NOT NULL,
          ALTER COLUMN type SET NOT NULL,
          ALTER COLUMN name SET NOT NULL,
          DROP CONSTRAINT IF EXISTS logs_user_id_fkey,
          DROP CONSTRAINT IF EXISTS fk_logs_user_id_users,
          ADD CONSTRAINT fk_logs_user_id_users FOREIGN KEY (user_id)
              REFERENCES users (id) ON DELETE CASCADE,
          DROP CONSTRAINT IF EXISTS ck_logs_type,
          ADD CONSTRAINT ck_logs_type CHECK ({sql_in("type", LOG_TYPES)})
        """
    )
    op.create_index(
        "ix_logs_user_id_created_at", "logs", ["user_id", "created_at"], if_not_exists=True
    )

    # ---------- refresh_tokens ----------
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("created_at", TZ, nullable=False, server_default=NOW),
        sa.Column("revoked_at", TZ),
        sa.Column("replaced_by_id", sa.Integer()),
        sa.PrimaryKeyConstraint("id", name="pk_refresh_tokens"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_refresh_tokens_user_id_users"),
        sa.ForeignKeyConstraint(["replaced_by_id"], ["refresh_tokens.id"], ondelete="SET NULL",
                                name="fk_refresh_tokens_replaced_by_id_refresh_tokens"),
        if_not_exists=True,
    )
    op.create_index("ix_refresh_tokens_token_hash", "refresh_tokens", ["token_hash"],
                    unique=True, if_not_exists=True)
    op.create_index("ix_refresh_tokens_family_id", "refresh_tokens", ["family_id"],
                    if_not_exists=True)
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"],
                    if_not_exists=True)

    # ---------- custom_exercises ----------
    op.create_table(
        "custom_exercises",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("muscle", sa.String(32), nullable=False),
        sa.Column("equipment_type", sa.String(32), nullable=False),
        sa.Column("created_at", TZ, nullable=False, server_default=NOW),
        sa.PrimaryKeyConstraint("id", name="pk_custom_exercises"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_custom_exercises_user_id_users"),
        if_not_exists=True,
    )
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_custom_exercises_user_id_lower_name "
        "ON custom_exercises (user_id, lower(name))"
    )

    # ---------- biomechanical_sets ----------
    op.create_table(
        "biomechanical_sets",
        sa.Column("set_id", sa.Uuid(), nullable=False),
        sa.Column("athlete_id", sa.Integer(), nullable=False),
        sa.Column("schema_version", sa.String(16), nullable=False),
        sa.Column("exercise", sa.String(32), nullable=False),
        sa.Column("goal", sa.String(32), nullable=False),
        sa.Column("vl_cap_pct", sa.Float(), nullable=False),
        sa.Column("set_index", sa.Integer(), nullable=False),
        sa.Column("reps_completed", sa.Integer(), nullable=False),
        sa.Column("load_kg", sa.Float()),
        sa.Column("mpv_initial", sa.Float()),
        sa.Column("mpv_final", sa.Float()),
        sa.Column("velocity_loss_pct", sa.Float()),
        sa.Column("vl_cap_exceeded", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("mqs_score", sa.Float()),
        sa.Column("mqs_breakdown", JSONB()),
        sa.Column("symmetry_index", sa.Float()),
        sa.Column("fault_counts", JSONB(), nullable=False),
        sa.Column("per_rep", JSONB(), nullable=False),
        sa.Column("device_labels", JSONB(), nullable=False),
        sa.Column("data_source", sa.String(16), nullable=False),
        sa.Column("payload", JSONB(), nullable=False),
        sa.Column("slm_coaching_json", JSONB()),
        sa.Column("coaching_source", sa.String(16)),
        sa.Column("coached_at", TZ),
        sa.Column("started_at", TZ),
        sa.Column("ended_at", TZ),
        sa.Column("created_at", TZ, nullable=False, server_default=NOW),
        sa.Column("log_id", sa.Integer()),
        sa.PrimaryKeyConstraint("set_id", name="pk_biomechanical_sets"),
        sa.ForeignKeyConstraint(["athlete_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_biomechanical_sets_athlete_id_users"),
        sa.ForeignKeyConstraint(["log_id"], ["logs.id"], ondelete="SET NULL",
                                name="fk_biomechanical_sets_log_id_logs"),
        sa.CheckConstraint(sql_in("exercise", BIOMECH_EXERCISES), name="ck_biomechanical_sets_exercise"),
        sa.CheckConstraint(sql_in("goal", GOALS), name="ck_biomechanical_sets_goal"),
        sa.CheckConstraint(sql_in("data_source", DATA_SOURCES), name="ck_biomechanical_sets_data_source"),
        sa.CheckConstraint("coaching_source IS NULL OR " + sql_in("coaching_source", COACHING_SOURCES),
                           name="ck_biomechanical_sets_coaching_source"),
        sa.CheckConstraint("vl_cap_pct > 0 AND vl_cap_pct <= 100", name="ck_biomechanical_sets_vl_cap_pct"),
        sa.CheckConstraint("reps_completed >= 0", name="ck_biomechanical_sets_reps_completed"),
        if_not_exists=True,
    )
    op.create_index("ix_biomechanical_sets_athlete_id_created_at", "biomechanical_sets",
                    ["athlete_id", "created_at"], if_not_exists=True)
    op.create_index("ix_biomechanical_sets_athlete_id_exercise_created_at", "biomechanical_sets",
                    ["athlete_id", "exercise", "created_at"], if_not_exists=True)

    # ---------- athlete_baselines ----------
    op.create_table(
        "athlete_baselines",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("athlete_id", sa.Integer(), nullable=False),
        sa.Column("exercise", sa.String(32), nullable=False),
        sa.Column("load_kg", sa.Float()),
        sa.Column("mpv_reference_m_s", sa.Float()),
        sa.Column("peak_depth_reference_deg", sa.Float()),
        sa.Column("symmetry_reference", sa.Float()),
        sa.Column("sets_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("source_set_id", sa.Uuid()),
        sa.Column("meta", JSONB()),
        sa.Column("created_at", TZ, nullable=False, server_default=NOW),
        sa.Column("updated_at", TZ, nullable=False, server_default=NOW),
        sa.PrimaryKeyConstraint("id", name="pk_athlete_baselines"),
        sa.ForeignKeyConstraint(["athlete_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_athlete_baselines_athlete_id_users"),
        sa.ForeignKeyConstraint(["source_set_id"], ["biomechanical_sets.set_id"], ondelete="SET NULL",
                                name="fk_athlete_baselines_source_set_id_biomechanical_sets"),
        sa.CheckConstraint(sql_in("exercise", BIOMECH_EXERCISES), name="ck_athlete_baselines_exercise"),
        if_not_exists=True,
    )
    op.create_index("uq_athlete_baselines_athlete_id_exercise", "athlete_baselines",
                    ["athlete_id", "exercise"], unique=True, if_not_exists=True)

    # ---------- optional food feature ----------
    op.create_table(
        "nutrition_reference",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("kcal_per_100g", sa.Float(), nullable=False),
        sa.Column("protein_g_per_100g", sa.Float()),
        sa.Column("carbs_g_per_100g", sa.Float()),
        sa.Column("fat_g_per_100g", sa.Float()),
        sa.Column("source", sa.String(100)),
        sa.PrimaryKeyConstraint("id", name="pk_nutrition_reference"),
        if_not_exists=True,
    )
    op.create_index("uq_nutrition_reference_name", "nutrition_reference", ["name"],
                    unique=True, if_not_exists=True)

    op.create_table(
        "meals",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("eaten_at", TZ, nullable=False),
        sa.Column("name", sa.String(200)),
        sa.Column("total_kcal", sa.Float()),
        sa.Column("source", sa.String(16), nullable=False, server_default="manual"),
        sa.Column("created_at", TZ, nullable=False, server_default=NOW),
        sa.PrimaryKeyConstraint("id", name="pk_meals"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_meals_user_id_users"),
        sa.CheckConstraint(sql_in("source", MEAL_SOURCES), name="ck_meals_source"),
        if_not_exists=True,
    )
    op.create_index("ix_meals_user_id_eaten_at", "meals", ["user_id", "eaten_at"], if_not_exists=True)

    op.create_table(
        "food_items",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("meal_id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("grams", sa.Float()),
        sa.Column("kcal", sa.Float()),
        sa.Column("protein_g", sa.Float()),
        sa.Column("carbs_g", sa.Float()),
        sa.Column("fat_g", sa.Float()),
        sa.Column("reference_id", sa.Integer()),
        sa.Column("confidence", sa.Float()),
        sa.PrimaryKeyConstraint("id", name="pk_food_items"),
        sa.ForeignKeyConstraint(["meal_id"], ["meals.id"], ondelete="CASCADE",
                                name="fk_food_items_meal_id_meals"),
        sa.ForeignKeyConstraint(["reference_id"], ["nutrition_reference.id"], ondelete="SET NULL",
                                name="fk_food_items_reference_id_nutrition_reference"),
        sa.CheckConstraint("confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
                           name="ck_food_items_confidence"),
        if_not_exists=True,
    )
    op.create_index("ix_food_items_meal_id", "food_items", ["meal_id"], if_not_exists=True)


def downgrade() -> None:
    _require_postgres()
    for t in ("food_items", "meals", "nutrition_reference", "athlete_baselines",
              "biomechanical_sets", "custom_exercises", "refresh_tokens"):
        op.drop_table(t, if_exists=True)
    op.execute("DROP INDEX IF EXISTS ix_logs_user_id_created_at")
    op.execute("ALTER TABLE logs DROP CONSTRAINT IF EXISTS ck_logs_type")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS created_at")
    # Not reverted on purpose: logs.created_at stays TIMESTAMPTZ and NOT NULL
    # constraints stay (reverting would lose timezone information).
