"""All prompt text lives here so it can be tuned without touching pipeline logic."""
from __future__ import annotations

from .config import Speaker

# Section titles that carry the paper's theoretical/approach content. These are delivered as a
# faithful single-speaker monologue so that summarizing them into a discussion cannot hallucinate.
METHODOLOGY_TITLES = {
    "method", "methods", "methodology", "approach", "model", "models", "the model",
    "our method", "our approach", "proposed method", "proposed approach", "method",
    "methods and materials", "materials and methods", "experimental setup",
    "preliminaries", "problem setup", "methods and experiments", "algorithm",
}

STYLE_GUIDES = {
    "host_expert": (
        "FORMAT: an in-depth podcast episode. {a} is the host and drives the conversation: "
        "asks precise questions, requests intuition and concrete examples, paraphrases to check "
        "understanding, and signposts transitions. {b} is the expert and carries most of the technical "
        "content, explaining methods, equations, experimental design and results with exact figures. "
        "The host is curious and smart, never a straw man; the expert is clear, never condescending."
    ),
    "peers": (
        "FORMAT: a journal-club style discussion between two researchers of equal standing. "
        "{a} presents and explains the paper in depth; {b} interrogates it — assumptions, baselines, "
        "statistics, ablations, reproducibility, alternative explanations, relation to prior work. "
        "They genuinely build on, challenge and occasionally correct each other, and reach a balanced "
        "verdict. Both are technical; neither simplifies for a lay audience, but both stay clear."
    ),
}

SPOKEN_RULES = """\
WRITE FOR THE EAR — the text will be read by a text-to-speech engine:
- Plain sentences only. No markdown, bullets, headings, emojis, stage directions, or sound effects.
- No citation markers like [12] or (Smith et al., 2020); say "earlier work by Smith and colleagues" if needed.
- Verbalise math: "x squared", "the sum over all tokens of the log probability", "sigma of W x plus b".
  Explain what an equation means rather than reading long formulas symbol by symbol.
- Say numbers as they would be spoken: "about ninety-two point four percent", "ten to the minus three".
- Expand abbreviations the first time they appear.
- Mostly 1–5 sentences per turn; vary rhythm with occasional short reactions ("Right.", "Wait, so...").
- Stay faithful to the source. Never invent results, numbers or claims. If the paper does not say
  something, a speaker says so explicitly rather than guessing.
"""


def system_prompt(style: str, speakers: list[Speaker], language: str) -> str:
    a, b = speakers
    guide = STYLE_GUIDES.get(style, STYLE_GUIDES["host_expert"]).format(a=a.name, b=b.name)
    return (
        "You are a scriptwriter producing a faithful, detailed spoken discussion of a scientific paper.\n\n"
        f"SPEAKERS:\n- {a.name} ({a.role}): {a.persona}\n- {b.name} ({b.role}): {b.persona}\n\n"
        f"{guide}\n\n{SPOKEN_RULES}\n"
        f"Write all dialogue in {language}."
    )


NOTES_PROMPT = """\
Below is part of a scientific paper ("{title}"). Write dense technical NOTES on it that will later be
used — instead of the original text — to script a detailed discussion. Preserve:
- every claim and contribution, with the authors' reasoning;
- method details: architecture/procedure steps, definitions, key equations (in words AND symbols),
  hyperparameters, datasets, sample sizes, baselines, metrics;
- ALL quantitative results (exact numbers, units, comparisons, significance, error bars);
- figure/table takeaways, limitations, assumptions, and stated future work.
Organise by the section headings given. Be compact (no prose padding) but do not drop details.
Target at most ~{target_words} words.

=== PAPER PART ===
{text}
"""

REDUCE_PROMPT = """\
These are notes on consecutive parts of the paper "{title}". Merge them into a single, more compact set
of notes, keeping section structure, all quantitative results, method details and limitations.
Remove only redundancy. Target at most ~{target_words} words.

=== NOTES ===
{text}
"""

OUTLINE_PROMPT = """\
Plan a spoken discussion of the paper below, lasting about {minutes:.0f} minutes, that covers the paper
in ALL of its details: motivation and problem setting, background needed to follow it, each
contribution, the method component by component (including the intuition behind key equations),
experimental setup (data, baselines, metrics), every main result with its numbers, ablations and
analyses, limitations and threats to validity, relation to prior work, and implications/open questions.

Return ONLY a JSON object, no commentary, in exactly this shape:
{{"tags": ["topic1", "topic2", "..."],
  "segments": [
  {{"title": "short title",
    "goal": "what the listener should understand by the end of this segment",
    "sections": [list of section numbers from the SECTION INDEX that this segment draws on],
    "key_points": ["specific point to cover, with concrete numbers/terms", "..."],
    "weight": relative length as a number (1.0 = average),
    "monologue": true}}  <!-- set true ONLY if this segment's content is primarily a methodology /
                            approach / theoretical section that should be read through faithfully
                            as one speaker's monologue rather than summarized into a discussion -->
]}}

"tags" is 2-3 BROAD, high-level topical tags for this paper (lowercase, 1-3 words each, e.g.
["deep learning"], ["neural compression", "language modeling"]). Prefer coarse subject areas over narrow
specifics so papers cluster into a small set of topics.

Rules: {min_seg}-{max_seg} segments in listening order. The first segment introduces the paper
(title, what problem it tackles, why it matters); the last wraps up with the verdict and takeaways.
Every section in the index (except references) must be used by at least one segment. key_points must
be specific to THIS paper (e.g. "LoRA rank 8 matches full fine-tuning on GLUE at 0.1% parameters"),
not generic ("discuss results").

{depth_guide}
SECTION INDEX:
{index}

=== PAPER {kind} ===
{text}
"""

SEGMENT_PROMPT = """\
You are writing segment {seg_no} of {n_segs} of the discussion of "{title}".

FULL EPISODE PLAN (for orientation — cover ONLY the current segment now):
{plan}

CURRENT SEGMENT: "{seg_title}"
Goal: {goal}
Key points that MUST all be covered, accurately and in depth:
{key_points}
{part_note}
ALREADY COVERED in earlier segments (do not repeat, but you may briefly refer back):
{covered}

{recent}
SOURCE MATERIAL for this segment ({source_kind}):
{source}

{position_rules}
Length: about {words} words of dialogue.
Output ONLY dialogue lines, each starting with the speaker name and a colon, e.g.
{a}: ...
{b}: ...
"""

POSITION_RULES = {
    "first": "This is the OPENING: {a} welcomes listeners, introduces the paper (title, authors if "
             "given, field) and why it matters, then the discussion begins.",
    "middle": "This is a MIDDLE segment: no greetings or sign-offs. Continue naturally from the "
              "last lines above and transition smoothly into this topic.",
    "last": "This is the CLOSING segment: continue naturally, give the overall assessment and key "
            "takeaways, then {a} thanks {b} and signs off.",
    "only": "This is the whole episode: open with a welcome and introduction, and close with "
            "takeaways and a sign-off.",
}

# --- monologue (methodology / approach sections) ---------------------------
# The methodology is read through faithfully rather than summarized, so the podcast cannot
# hallucinate the paper's theoretical/technical content when it is shortened or reformatted.
MONOLOGUE_PROMPT = """\
You are writing segment {seg_no} of {n_segs} of the discussion of "{title}".

This segment is a MONOLOGUE. It presents a methodology / approach section and its technical content
must be carried over FAITHFULLY from the source, not paraphrased away.

FULL EPISODE PLAN (for orientation — cover ONLY the current segment now):
{plan}

CURRENT SEGMENT: "{seg_title}"
Goal: {goal}

{recent}
BEGINNING: {a} briefly introduces why this methodological part matters, then hands over. Optionally
{a} can interject once with a genuinely clarifying question, but the bulk is carried by {b}.
DELIVERY: {b} presents the section as a continuous, faithful monologue. Reproduce every method detail
as it is in the source: the full procedure/architecture, every step, definitions, assumptions, the
precise equations (explained in words AND symbols), and all hyperparameters, datasets, baselines and
settings. Keep the numbers and choices exactly as the paper states them. Explain what each piece does
and why it was chosen, in the authors' own framing. Do not collapse or compress the technical content;
the listener should be able to re-derive the method from what {b} says. Never invent anything not in
the source — if a detail is missing, {b} says so rather than guessing.

SOURCE MATERIAL ({source_kind}):
{source}

{position_rules}
Length: about {words} words of dialogue.
Output ONLY dialogue lines, each starting with the speaker name and a colon, e.g.
{a}: ...
{b}: ...
"""

FIX_FORMAT = (
    "Your previous answer could not be parsed. Output ONLY dialogue lines, each beginning with "
    "exactly '{a}:' or '{b}:'. No headings, no markdown, no notes."
)

FIX_JSON = "That was not valid JSON matching the requested shape. Output ONLY the JSON object."
