"""Guess an author's gender from the given name, to pick a TTS voice.

A heuristic only: exact match against a small common-name table first, then name-ending
rules for Italian/Spanish-style names. Returns ``None`` when unsure, so callers keep the
configured voice instead of risking a confidently wrong gender.
"""
from __future__ import annotations

_MALE = {
    "alex", "sam", "marco", "luca", "matteo", "alessandro", "giuseppe", "antonio",
    "giovanni", "francesco", "carlo", "paolo", "davide", "giacomo", "riccardo",
    "edoardo", "tommaso", "michael", "john", "james", "robert", "william", "david",
    "daniel", "mark", "paul", "peter", "george", "leo", "mario", "luigi", "nicola",
    "vincenzo", "samuel", "thomas", "chris", "kyle", "ryan", "eric", "nathan",
    "brandon", "justin", "kevin", "andrea", "andrew", "joshua", "alan", "albert",
    "adam", "allen", "oscar", "victor",
}
_FEMALE = {
    "alexa", "maria", "giulia", "sofia", "elena", "anna", "lucia", "chiara", "sara",
    "francesca", "valentina", "ilaria", "silvia", "alessia", "martina", "giorgia",
    "marta", "beatrice", "emma", "olivia", "isabella", "mia", "charlotte", "amelia",
    "harper", "evelyn", "hannah", "zoe", "lina", "maya", "sandra", "melissa",
    "jennifer", "jessica", "rebecca", "laura", "fatima",
}

# ponytail: name table is small and biased (English/Italian); a proper given-name DB
# would replace it. Conservative: any ambiguous name keeps the configured voice.
def guess_gender(name: str) -> str | None:
    if not name:
        return None
    given = re_first_name(name)
    if not given:
        return None
    first = given.lower()
    if first in _MALE:
        return "male"
    if first in _FEMALE:
        return "female"
    if first.endswith("a"):
        return "female"
    if first.endswith(("o", "io")):
        return "male"
    return None


def re_first_name(full: str) -> str:
    token = full.replace(",", " ").split()[0].strip().strip(".") if full.split() else ""
    return token if len(token) > 1 else ""


# Kokoro voice codes are <lang><gender>_<name>. Per language, a voice of each gender.
_FEMALE_VOICES = {"a": "af_heart", "b": "bf_emma", "i": "if_sara"}
_MALE_VOICES = {"a": "am_michael", "b": "bm_george", "i": "im_nicola"}


def voice_for(gender: str, current_voice: str) -> str:
    lang = current_voice[:1] if current_voice else "a"
    table = _FEMALE_VOICES if gender == "female" else _MALE_VOICES
    return table.get(lang) or current_voice