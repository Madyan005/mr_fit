"""LLM client interface + implementations.

* OllamaClient   — real: Ollama /api/chat with `format=<JSON schema>` (structured output),
                   temperature 0, keep_alive from config (default "0" = unload right away),
                   plus an explicit unload as the GPU job's release hook.
* FakeLLMClient  — deterministic, no GPU / no Ollama (tests, LLM_BACKEND=fake, CI).

deepseek-r1 is a reasoning model and may emit <think>...</think> before the JSON (or put
it in message.thinking on newer Ollama). `extract_json_text` strips it before parsing.
"""
from __future__ import annotations

import json
import re
from collections.abc import Sequence
from typing import Any, Protocol

import httpx

_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S | re.I)


class LLMError(Exception):
    """Transport/timeout/HTTP failure (not a content failure)."""


class LLMClient(Protocol):
    model_name: str

    async def generate_json(self, system: str, user: str, schema: dict[str, Any]) -> str:
        """Return the raw text of the model's answer (may contain <think> blocks)."""

    async def unload(self) -> None:
        """Free VRAM. No-op for clients without a GPU."""


def extract_json_text(raw: str) -> str:
    """Strip reasoning blocks / code fences and return the outermost JSON object text."""
    text = _THINK_BLOCK.sub("", raw)
    if "</think>" in text.lower():  # opening tag missing or truncated
        text = text[text.lower().rfind("</think>") + len("</think>"):]
    if "<think>" in text.lower():  # unterminated think block: keep what follows the first '{' after it
        text = text[text.lower().find("<think>") + len("<think>"):]
    text = text.replace("```json", "").replace("```", "")
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in model output")
    return text[start : end + 1]


class OllamaClient:
    def __init__(self, base_url: str, model: str, keep_alive: str = "0", timeout_s: float = 120.0,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.model_name = model
        self._keep_alive = keep_alive
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout_s, transport=transport)

    async def generate_json(self, system: str, user: str, schema: dict[str, Any]) -> str:
        body = {
            "model": self.model_name,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "format": schema,
            "stream": False,
            "keep_alive": self._keep_alive,
            "options": {"temperature": 0, "num_ctx": 4096},
        }
        try:
            r = await self._client.post("/api/chat", json=body)
            r.raise_for_status()
            data = r.json()
        except (httpx.HTTPError, json.JSONDecodeError) as e:
            raise LLMError(f"ollama request failed: {type(e).__name__}") from e
        msg = data.get("message") or {}
        return str(msg.get("content") or "")  # message.thinking (if any) is ignored on purpose

    async def unload(self) -> None:
        try:
            await self._client.post("/api/generate", json={"model": self.model_name, "keep_alive": 0})
        except httpx.HTTPError:
            pass

    async def aclose(self) -> None:
        await self._client.aclose()


class FakeLLMClient:
    """Deterministic stand-in. With `responses`, returns them in order (cycling the last);
    otherwise writes a digit-free prescription using the first allowed metric key."""

    model_name = "fake-llm"

    def __init__(self, responses: Sequence[str] | None = None, fail_with: Exception | None = None):
        self._responses = list(responses or [])
        self._fail_with = fail_with
        self.calls: list[dict[str, Any]] = []
        self.unloads = 0

    async def generate_json(self, system: str, user: str, schema: dict[str, Any]) -> str:
        self.calls.append({"system": system, "user": user, "schema": schema})
        if self._fail_with is not None:
            raise self._fail_with
        if self._responses:
            i = min(len(self.calls) - 1, len(self._responses) - 1)
            return self._responses[i]
        keys = schema["properties"]["focus_metric"]["anyOf"][0]["enum"]
        focus = "velocity_loss_pct" if "velocity_loss_pct" in keys else (keys[0] if keys else None)
        return json.dumps({
            "summary": "Solid set. Keep the same tempo and stay tight through every rep.",
            "focus_metric": focus,
            "cues": [{"text": "Drive up hard out of the bottom of each rep.", "metric_ref": focus}],
        })

    async def unload(self) -> None:
        self.unloads += 1
