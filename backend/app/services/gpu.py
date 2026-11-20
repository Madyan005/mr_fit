"""Global GPU queue: at most ONE GPU job at a time in this process (GTX 1050 Ti, 4 GB).

Every GPU consumer — the Ollama coach today, a future server-side pose / forensic model
(the `GpuJob` slot) — must run through `GpuScheduler.run`. The job's `release` hook runs
after the job (success or failure) so VRAM is freed before the next job starts.

Requires a single API worker process (the entrypoint starts one uvicorn worker).
Ollama itself is also capped (OLLAMA_MAX_LOADED_MODELS=1, OLLAMA_NUM_PARALLEL=1).
"""
from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Generic, TypeVar

log = logging.getLogger(__name__)
T = TypeVar("T")


@dataclass
class GpuJob(Generic[T]):
    name: str
    run: Callable[[], Awaitable[T]]
    release: Callable[[], Awaitable[None]] | None = None  # e.g. unload model from VRAM


class GpuScheduler:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self.active_job: str | None = None
        self.completed_jobs = 0

    @property
    def busy(self) -> bool:
        return self._lock.locked()

    async def run(self, job: GpuJob[T]) -> T:
        async with self._lock:
            self.active_job = job.name
            try:
                return await job.run()
            finally:
                if job.release is not None:
                    try:
                        await job.release()
                    except Exception:  # never let a failed unload wedge the queue
                        log.warning("GPU release for %s failed", job.name, exc_info=True)
                self.active_job = None
                self.completed_jobs += 1


# ---- Placeholder slot for a future GPU model (e.g. server-side pose / forensic review) ----
async def run_future_gpu_model_placeholder(scheduler: GpuScheduler) -> None:  # pragma: no cover
    """REAL SLOT: wrap the future model's inference in a GpuJob and submit it here, so it
    can never overlap with Ollama. Nothing calls this yet."""
    raise NotImplementedError("no server-side GPU model besides the coach yet")
