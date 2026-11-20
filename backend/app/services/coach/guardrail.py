"""Deterministic medical guardrail. Runs BEFORE the language model; a match bypasses the
model entirely and returns a canned referral. Also run on model OUTPUT (a model that
starts diagnosing is rejected -> fallback).

Design: conservative on purpose (false positives only cost a referral message).
English: lower-cased, word-boundary regexes. Arabic: normalised (diacritics, alef/ya/
ta-marbuta variants, tatweel, Arabic-Indic digits) and matched per token after stripping
common prefixes/suffixes, so short keywords like «ألم» don't match inside «العالم».
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

# ---------------- English ----------------
_EN_PATTERNS: list[tuple[str, str]] = [
    ("disc_injury", r"\b(herniat\w*|slipped|bulging|ruptured)\s+discs?\b|\bdisc\s+(herniation|bulge|prolapse)\b"),
    ("sciatica", r"\bsciatic\w*\b"),
    ("meniscus", r"\b(torn|tore|tear|tearing)\b.{0,20}\bmenisc\w*\b|\bmenisc\w*\b.{0,20}\b(torn|tear)\b"),
    ("ligament", r"\b(acl|mcl|pcl|lcl|ligament|tendon|rotator\s+cuff)\b.{0,25}\b(tear|torn|rupture\w*|strain\w*|sprain\w*)\b"
                 r"|\b(torn|tore|ruptured)\b.{0,25}\b(acl|mcl|pcl|lcl|ligament|tendon|rotator\s+cuff)\b"),
    ("sharp_pain", r"\b(sharp|stabbing|shooting|severe|intense|burning|sudden)\b.{0,25}\b(pain|ache)\b"),
    ("body_pain", r"\b(pain|painful|hurts?|hurting|aching|sore\s+joint)\b.{0,30}\b(knee|knees|back|spine|lumbar|hip|hips|shoulder|shoulders|neck|elbow|wrist|ankle|chest)\b"
                  r"|\b(knee|back|spine|lumbar|hip|shoulder|neck|elbow|wrist|ankle|chest)\b.{0,20}\b(pain|hurts?|hurting)\b"),
    ("pain_generic", r"\b(in\s+pain|it\s+hurts|hurts\s+(a\s+lot|badly)|pain\s+(when|during|after))\b"),
    ("neuro", r"\b(numb|numbness|tingling|pins\s+and\s+needles|radiating)\b"),
    ("trauma", r"\b(fractur\w*|broken\s+bone|dislocat\w*|popped|pop\s+in\s+my|swollen|swelling)\b"),
    ("red_flag", r"\b(chest\s+pain|dizz\w*|faint\w*|passed\s+out|short(ness)?\s+of\s+breath|blackout)\b"),
    ("diagnosis", r"\b(diagnos\w*|what\s+injury|is\s+it\s+(torn|broken|serious))\b"),
    ("rehab", r"\b(rehab\w*|physio\w*|physical\s+therap\w*|recover\w*\s+from\s+(an?\s+)?(injury|surgery)|post[-\s]?op\w*|surgery)\b"),
    ("injury", r"\b(injur\w*)\b"),
]
_EN = [(name, re.compile(p, re.I | re.S)) for name, p in _EN_PATTERNS]

# ---------------- Arabic ----------------
_AR_DIACRITICS = re.compile(r"[ؐ-ًؚ-ٰٟۖ-ۭ]")
_AR_MAP = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي", "ـ": ""})
_AR_PREFIXES = ("وال", "بال", "فال", "كال", "لل", "ال", "و", "ف", "ب", "ل")
_AR_SUFFIXES = ("هما", "كما", "ها", "هم", "كم", "نا", "ي", "ه", "ك")


def normalize_ar(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = _AR_DIACRITICS.sub("", text).translate(_AR_MAP)
    return text.lower()


def _variants(token: str) -> set[str]:
    out = {token}
    for p in _AR_PREFIXES:
        if token.startswith(p) and len(token) - len(p) >= 2:
            out.add(token[len(p):])
    for t in list(out):
        for s in _AR_SUFFIXES:
            if t.endswith(s) and len(t) - len(s) >= 2:
                out.add(t[: -len(s)])
    return out


# Single tokens (normalised form). Category -> words.
_AR_WORDS: dict[str, set[str]] = {
    "pain": {"الم", "اوجاع", "وجع", "توجعني", "يوجعني", "بتوجعني", "مؤلم", "موجع", "الام"},
    "disc_injury": {"ديسك", "انزلاق", "غضروف", "غضروفي", "فتق"},
    "meniscus": {"الهلالي", "هلالي"},
    # «شد» deliberately absent: gym slang for pulling exercises («شد ظهر» = lat pulldown).
    "ligament": {"رباط", "الرباط", "اربطه", "وتر", "تمزق", "قطع"},
    "neuro": {"تنميل", "خدر", "تخدير", "تنمل"},
    "trauma": {"كسر", "مكسور", "خلع", "التواء", "ورم", "تورم", "انتفاخ"},
    "red_flag": {"دوخه", "دوار", "اغماء", "اغمي"},
    "diagnosis": {"شخص", "شخصني", "تشخيص", "تشخص"},
    "rehab": {"تاهيل", "علاج", "طبيعي", "فيزيو", "جراحه", "عمليه"},
    "injury": {"اصابه", "اصابتي", "مصاب", "انصبت", "اتصبت"},
}
_AR_INDEX = {normalize_ar(w): cat for cat, ws in _AR_WORDS.items() for w in ws}
# Very generic words that only count next to a body part / intensity word.
_AR_WEAK = {normalize_ar(w) for w in ("قطع", "علاج", "طبيعي", "عمليه", "ورم")}
_AR_BODY = {normalize_ar(w) for w in ("ركبه", "ركبتي", "ظهر", "ظهري", "عمود", "فقري", "كتف", "كتفي",
                                      "رقبه", "رقبتي", "ورك", "حوض", "كاحل", "رسغ", "كوع", "صدر",
                                      "عضله", "مفصل", "حاد", "شديد", "طبيعي", "رباط", "غضروف")}
_AR_TOKEN = re.compile(r"[؀-ۿ]+")


@dataclass(frozen=True)
class GuardrailResult:
    triggered: bool
    categories: tuple[str, ...] = ()
    language: str = "en"  # language of the canned reply


CANNED_EN = (
    "This sounds like it may involve pain or an injury. MR-Fit can't assess or diagnose "
    "that. Please stop this exercise and see a licensed physical therapist or a sports "
    "medicine physician before training this movement again. If pain is severe, or you "
    "feel chest pain, dizziness or numbness, seek medical care now."
)
CANNED_AR = (
    "يبدو أن الأمر قد يتعلق بألم أو إصابة. لا يستطيع MR-Fit تقييم ذلك أو تشخيصه. "
    "من فضلك أوقف هذا التمرين وراجع أخصائي علاج طبيعي مرخّصًا أو طبيب طب رياضي قبل "
    "أداء هذه الحركة مرة أخرى. إذا كان الألم شديدًا أو شعرت بألم في الصدر أو دوخة أو تنميل، "
    "فاطلب الرعاية الطبية فورًا."
)


def has_arabic(text: str) -> bool:
    return bool(_AR_TOKEN.search(text))


def check(text: str | None) -> GuardrailResult:
    if not text or not text.strip():
        return GuardrailResult(False)
    cats: list[str] = [name for name, rx in _EN if rx.search(text)]
    tokens = _AR_TOKEN.findall(normalize_ar(text))
    near_body = any(v in _AR_BODY for t in tokens for v in _variants(t))
    for t in tokens:
        for v in _variants(t):
            cat = _AR_INDEX.get(v)
            if cat and (v not in _AR_WEAK or near_body):
                cats.append(cat)
                break
    lang = "ar" if has_arabic(text) else "en"
    uniq = tuple(dict.fromkeys(cats))
    return GuardrailResult(bool(uniq), uniq, lang)


# On MODEL OUTPUT we only reject medical content (diagnosing, injury types, rehab advice).
# Ordinary coaching like "keep your back neutral to avoid pain/injury" is allowed.
_OUTPUT_BLOCKING = {"disc_injury", "sciatica", "meniscus", "ligament", "neuro", "trauma",
                    "red_flag", "diagnosis", "rehab"}


def check_output(text: str) -> GuardrailResult:
    r = check(text)
    blocking = tuple(c for c in r.categories if c in _OUTPUT_BLOCKING)
    return GuardrailResult(bool(blocking), blocking, r.language)


def canned_message(result: GuardrailResult) -> str:
    return CANNED_AR if result.language == "ar" else CANNED_EN
