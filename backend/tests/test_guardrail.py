"""Medical guardrail: English + Arabic, positives and (important) negatives."""
import pytest

from app.services.coach import guardrail

EN_POSITIVE = [
    "I think I have a herniated disc",
    "sharp knee pain on the way up",
    "felt a sharp pain in my lower back",
    "my knee hurts when I squat",
    "torn meniscus last year, is squatting ok?",
    "can you diagnose what's wrong with my shoulder",
    "what rehab should I do after ACL surgery",
    "I tore my ACL",
    "numbness in my left leg",
    "felt dizzy and almost fainted",
    "pain during the descent",
    "I got injured last week",
]
AR_POSITIVE = [
    "عندي انزلاق غضروفي",
    "ألم حاد في الركبة",
    "عندي ألم في ظهري",
    "الألم في ركبتي",
    "ركبتي بتوجعني",
    "تمزق في الغضروف الهلالي",
    "ممكن تشخص حالتي؟",
    "محتاج برنامج إعادة تأهيل",
    "عندي تنميل في رجلي",
    "عندي إصابة في الكتف",
    "عملت عملية في الرباط الصليبي",
]
NEGATIVE = [
    "felt strong today, last rep was slow",
    "should I add weight next set?",
    "bar path felt off on rep three",
    "",
    None,
    "تمرين شد ظهر اليوم",  # «شد ظهر» = lat pulldown (gym slang), not an injury
    "أفضل تمرين في العالم",  # «العالم» contains «الم» as a substring
    "التمرين كان ممتاز",
]


@pytest.mark.parametrize("text", EN_POSITIVE)
def test_english_triggers(text):
    r = guardrail.check(text)
    assert r.triggered, text
    assert r.language == "en"


@pytest.mark.parametrize("text", AR_POSITIVE)
def test_arabic_triggers(text):
    r = guardrail.check(text)
    assert r.triggered, text
    assert r.language == "ar"


@pytest.mark.parametrize("text", NEGATIVE)
def test_normal_notes_pass(text):
    assert not guardrail.check(text).triggered, text


def test_arabic_diacritics_and_tatweel_normalised():
    assert guardrail.check("ألـــمٌ شديد").triggered


def test_canned_message_language_and_referral():
    en = guardrail.canned_message(guardrail.check("sharp knee pain"))
    ar = guardrail.canned_message(guardrail.check("ألم حاد"))
    assert "physical therapist" in en and "sports medicine physician" in en
    assert "علاج طبيعي" in ar and "طب رياضي" in ar


def test_output_check_allows_normal_coaching_but_blocks_diagnosis():
    assert not guardrail.check_output("Keep your back neutral to avoid injury and pain.").triggered
    assert guardrail.check_output("This looks like a torn meniscus; see rehab.").triggered
    assert guardrail.check_output("You may have sciatica.").triggered
