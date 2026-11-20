"""Regenerate the JSON Schemas in contracts/ from the Pydantic models (source of truth).

    cd backend && python -m scripts.export_contracts          # write
    cd backend && python -m scripts.export_contracts --check  # exit 1 if out of date (CI)
"""
from __future__ import annotations

import json
import sys

from app.core.contracts import contracts_dir
from app.schemas.coaching import CoachingCard, CoachingPrescription
from app.schemas.set_summary import SetSummaryPayload

TARGETS = {
    "set_summary.v1.schema.json": SetSummaryPayload,
    "coaching_card.v1.schema.json": CoachingCard,
    "coaching_prescription.v1.schema.json": CoachingPrescription,
}


def render(model) -> str:
    schema = model.model_json_schema(mode="validation")
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    return json.dumps(schema, indent=2, sort_keys=True) + "\n"


def main(argv: list[str]) -> int:
    check = "--check" in argv
    stale = []
    for name, model in TARGETS.items():
        path = contracts_dir() / name
        text = render(model)
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(name)
        else:
            path.write_text(text, encoding="utf-8", newline="\n")
            print("wrote", path)
    if stale:
        print("out of date:", ", ".join(stale), "- run: python -m scripts.export_contracts")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
