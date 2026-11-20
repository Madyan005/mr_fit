# Archive (out of scope for MR-Fit 2.0 — kept for reference, not deleted)

| Folder | What it is | Why archived |
|---|---|---|
| `legacy_v1/` | The v1 web app: FastAPI backend (`main.py`, `ai_logic.py`, `auth_utils.py`, `database.py`, `models.py`, `schemas.py`) + vanilla-JS SPA (`static/`). Includes the final local path-fix edits. | Replaced by `backend/` (Postgres/Timescale, constrained local coach) and `mobile/` (Flutter). Reused logic (auth hashing, logs/stats/heatmap, `build_user_context`, rate limiter, exercise library) is ported from here. Free-form `/coach-chat` and `/ai-coach` (cloud Gemini) are intentionally **not** ported. |
| `new_folder_snapshot/` | Code from the older `New folder/` copy (no `session_id`, no heatmap/PUT/coach routes). | Superseded by `legacy_v1/`. |

Not archived on purpose: `mr_fit.env` and `*.db` files. They contain a secret and
user data, so they were untracked (`git rm --cached`) and remain only on the
original developer's disk. See `docs/DECISIONS.md` D-002.

To run v1 for comparison (from `archive/legacy_v1/`): create `mr_fit.env` next to
`main.py` with the variables named in `.env.example` (`GEMINI_API_KEY`,
`SECRET_KEY`), then `python main.py`.
