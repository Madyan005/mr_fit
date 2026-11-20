"""Contract tests: committed JSON Schemas == Pydantic models; fixtures valid; Dart mirror
(mobile/) checked against the same schema once it exists (step 5)."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from app.core.contracts import channel_names, contracts_dir, exercise_library
from app.schemas.set_summary import SetSummaryPayload
from scripts import export_contracts
from tests.conftest import FIXTURES

REPO = Path(__file__).resolve().parents[2]
DART_PAYLOAD = REPO / "mobile" / "lib" / "domain" / "contracts" / "set_summary_payload.dart"


@pytest.mark.parametrize("name", sorted(export_contracts.TARGETS))
def test_committed_schema_matches_pydantic(name):
    committed = (contracts_dir() / name).read_text(encoding="utf-8")
    assert committed == export_contracts.render(export_contracts.TARGETS[name]), \
        "run: cd backend && python -m scripts.export_contracts"


@pytest.mark.parametrize("fixture", sorted(p.name for p in FIXTURES.glob("set_summary_*.json")))
def test_fixtures_are_valid_and_roundtrip(fixture):
    raw = json.loads((FIXTURES / fixture).read_text(encoding="utf-8"))
    p = SetSummaryPayload.model_validate(raw)
    again = json.loads(p.model_dump_json())
    assert set(again) == set(raw)  # nothing added or dropped


def test_schema_requires_every_field_and_forbids_extras():
    s = json.loads((contracts_dir() / "set_summary.v1.schema.json").read_text(encoding="utf-8"))
    assert set(s["required"]) == set(SetSummaryPayload.model_fields)
    assert s["additionalProperties"] is False
    assert s["properties"]["schema_version"]["const"] == "1.0.0"


def test_channel_registry_has_no_hardware_names():
    names = channel_names()
    assert {"accel_x", "gyro_z", "bar_vel_z", "battery_pct"} <= names
    assert not any(re.search(r"esp32|ble|uuid|mac", n, re.I) for n in names)


def test_library_matches_v1():
    lib = exercise_library()
    assert len(lib["exercises"]) == 26 and lib["muscles"] == ["Chest", "Back", "Shoulders", "Legs", "Arms", "Core"]


DART_CHANNELS = REPO / "mobile" / "lib" / "domain" / "sensors" / "channels.dart"


@pytest.mark.skipif(not DART_CHANNELS.exists(), reason="Dart registry arrives in step 5")
def test_dart_channel_registry_matches_json():
    dart = DART_CHANNELS.read_text(encoding="utf-8")
    declared = set(re.findall(r"static const \w+ = '([a-z0-9_]+)';", dart))
    assert declared == set(channel_names())


@pytest.mark.skipif(not DART_PAYLOAD.exists(), reason="Dart mirror arrives in step 5")
def test_dart_payload_field_names_match_schema():
    """Text-level check (no Dart SDK needed): every JSON key in the schema appears as a
    quoted key in the Dart class, and the Dart file declares the same schema_version."""
    dart = DART_PAYLOAD.read_text(encoding="utf-8")
    s = json.loads((contracts_dir() / "set_summary.v1.schema.json").read_text(encoding="utf-8"))
    keys = set(s["properties"]) | {k for d in s["$defs"].values() for k in d.get("properties", {})}
    missing = sorted(k for k in keys if f"'{k}'" not in dart and f'"{k}"' not in dart)
    assert not missing, f"Dart payload is missing keys: {missing}"
    assert "1.0.0" in dart
