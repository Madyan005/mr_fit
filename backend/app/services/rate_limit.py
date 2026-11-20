"""Per-user, per-endpoint cooldown. Ported from v1 main.py `_check_rate_limit`
(in-memory, single process; resets on restart — fine for one self-hosted instance)."""
from __future__ import annotations

import threading
import time
from collections import defaultdict
from collections.abc import Callable


class RateLimited(Exception):
    def __init__(self, retry_after: float):
        self.retry_after = retry_after
        super().__init__(f"retry after {retry_after:.0f}s")


class CooldownLimiter:
    def __init__(self, cooldown_seconds: float, clock: Callable[[], float] = time.monotonic):
        self.cooldown = cooldown_seconds
        self._clock = clock
        self._last: dict[str, dict[str, float]] = defaultdict(dict)
        self._lock = threading.Lock()

    def check(self, key: str, endpoint: str) -> None:
        """Raise RateLimited if `key` called `endpoint` less than `cooldown` seconds ago."""
        if self.cooldown <= 0:
            return
        with self._lock:
            now = self._clock()
            last = self._last[key].get(endpoint)
            if last is not None and (remaining := self.cooldown - (now - last)) > 0:
                raise RateLimited(remaining)
            self._last[key][endpoint] = now
