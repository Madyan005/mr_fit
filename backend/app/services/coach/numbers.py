"""Deterministic number checker: every number in model text must exist in the input
SetSummaryPayload. The model is told not to write numbers at all; this enforces it.

A number in the text "matches" a payload value if the value, rounded to the number of
decimals written, equals it (e.g. text "31" or "31.4" for 31.42; "0.62" for 0.618).
Handles ASCII and Arabic-Indic digits, "." / "," / "٫" decimal separators, and English
number words zero..twenty. Rep numbers 1..reps_completed count as payload values.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass

_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
# Any digit run counts (also inside words like "set2"): strict on purpose.
_NUM_SIMPLE = re.compile(r"\d+(?:[.,٫]\d+)?")
_WORDS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen twenty".split())}
_WORD_RX = re.compile(r"\b(" + "|".join(_WORDS) + r")\b", re.I)


@dataclass(frozen=True)
class NumberCheck:
    ok: bool
    found: tuple[str, ...]
    unmatched: tuple[str, ...]


def extract_numbers(text: str) -> list[str]:
    t = text.translate(_DIGITS)
    nums = [m.group(0) for m in _NUM_SIMPLE.finditer(t)]
    nums += [str(_WORDS[m.group(1).lower()]) for m in _WORD_RX.finditer(t)]
    return nums


def _matches(token: str, value: float) -> bool:
    norm = token.replace(",", ".").replace("٫", ".")
    decimals = len(norm.split(".")[1]) if "." in norm else 0
    try:
        written = float(norm)
    except ValueError:
        return False
    return math.isclose(round(value, decimals), written, abs_tol=10 ** -(decimals + 6)) or \
        math.isclose(round(abs(value), decimals), written, abs_tol=10 ** -(decimals + 6))


def check_numbers(texts: list[str], allowed_values: list[float]) -> NumberCheck:
    found: list[str] = []
    unmatched: list[str] = []
    for text in texts:
        for tok in extract_numbers(text):
            found.append(tok)
            if not any(_matches(tok, v) for v in allowed_values):
                unmatched.append(tok)
    return NumberCheck(not unmatched, tuple(found), tuple(unmatched))
