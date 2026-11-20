import pytest

from app.services.coach.numbers import check_numbers, extract_numbers

ALLOWED = [11.3, 0.62, 0.55, 5.0, 88.5, 30.0]


def test_no_numbers_is_ok():
    assert check_numbers(["Drive up hard out of the hole."], ALLOWED).ok


@pytest.mark.parametrize("text", [
    "Velocity loss was 11.3%.",
    "Velocity loss was about 11%.",        # rounded to the precision written
    "Start speed 0.62 m/s, end 0.55 m/s.",
    "You did 5 reps.",
    "You did five reps.",                  # number words
    "Velocity loss ١١٫٣ ٪",                 # Arabic-Indic digits + Arabic decimal sep
    "MQS 88.5, cap 30",
])
def test_payload_numbers_accepted(text):
    assert check_numbers([text], ALLOWED).ok, text


@pytest.mark.parametrize("text,bad", [
    ("Velocity loss was 12%.", "12"),
    ("Add 5kg and rest 90 seconds.", "90"),
    ("Your 1RM is about 140.", "140"),
    ("Speed 0.7 m/s", "0.7"),
    ("Do three more sets.", "3"),
    ("Velocity loss 11.30001", "11.30001"),
])
def test_invented_numbers_rejected(text, bad):
    r = check_numbers([text], ALLOWED)
    assert not r.ok
    assert bad in r.unmatched


def test_extract_handles_comma_decimal_and_words():
    assert extract_numbers("0,62 and twelve") == ["0,62", "12"]
