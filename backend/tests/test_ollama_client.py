"""OllamaClient against a mocked HTTP transport (no Ollama needed): request shape,
structured-output schema, keep_alive/unload, error mapping, and the full coach path."""
from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from app.schemas.coaching import CoachingPrescription
from app.schemas.set_summary import SetSummaryPayload
from app.services.coach.llm import LLMError, OllamaClient
from app.services.coach.service import CoachService
from app.services.gpu import GpuScheduler
from tests.conftest import fixture_payload


def _client(handler) -> tuple[OllamaClient, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def record(req: httpx.Request) -> httpx.Response:
        seen.append(req)
        return handler(req)

    return OllamaClient("http://ollama:11434", "deepseek-r1:1.5b", keep_alive="0",
                        transport=httpx.MockTransport(record)), seen


def _answer(content: str, thinking: str | None = None) -> httpx.Response:
    msg = {"role": "assistant", "content": content}
    if thinking is not None:
        msg["thinking"] = thinking
    return httpx.Response(200, json={"model": "deepseek-r1:1.5b", "message": msg, "done": True})


def test_request_body_uses_structured_output_and_unloads():
    good = json.dumps({"summary": "Nice set.", "focus_metric": "mqs_score",
                       "cues": [{"text": "Stay tight.", "metric_ref": "mqs_score"}]})
    client, seen = _client(lambda req: _answer(good, thinking="I computed 1234"))
    p = SetSummaryPayload.model_validate(fixture_payload("clean"))
    card = asyncio.run(CoachService(client, GpuScheduler()).coach(p, None, {}))
    assert card.source == "llm" and card.focus_value == 88.5  # 'thinking' field ignored

    chat, unload = seen
    assert chat.url.path == "/api/chat"
    body = json.loads(chat.content)
    assert body["model"] == "deepseek-r1:1.5b" and body["stream"] is False
    assert body["keep_alive"] == "0" and body["options"]["temperature"] == 0
    assert body["format"]["title"] == CoachingPrescription.__name__
    assert "mqs_score" in body["format"]["properties"]["focus_metric"]["anyOf"][0]["enum"]
    assert [m["role"] for m in body["messages"]] == ["system", "user"]
    assert unload.url.path == "/api/generate" and json.loads(unload.content)["keep_alive"] == 0


@pytest.mark.parametrize("handler", [
    lambda req: httpx.Response(500, text="model crashed"),
    lambda req: httpx.Response(200, text="not json"),
    lambda req: (_ for _ in ()).throw(httpx.ConnectError("refused")),
])
def test_transport_errors_become_llm_error(handler):
    client, _ = _client(handler)
    with pytest.raises(LLMError):
        asyncio.run(client.generate_json("s", "u", {}))
