"""Context-aware dialogue script generation.

Pipeline (each call is sized against the discovered context window):
  1. Knowledge:  if the whole paper fits the input budget it is used verbatim; otherwise
                 it is chunked (map) into dense notes, reduced recursively if needed.
  2. Outline:    one call -> JSON plan of segments with section refs + key points.
  3. Segments:   one (or more, if output budget is small) call per segment with the
                 original section text when it fits, else the notes for those sections,
                 plus a rolling memory (covered points + last N turns verbatim).
"""
from __future__ import annotations

import json
import logging
import math
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import prompts as P
from .config import Config, Speaker, speakers_for
from .gender import guess_gender, re_first_name, voice_for
from .llm import Budget, LLMClient
from .pdf_extract import Paper, Section

log = logging.getLogger(__name__)
NOTE_SYS = "You are a meticulous scientific note-taker."
OUTLINE_SYS = "You are an expert science editor. You output strict JSON."
MIN_ROOM = 400  # below this many tokens for source text, the window is unusable


# ---------------------------------------------------------------- data model
@dataclass
class Turn:
    speaker: str
    text: str


@dataclass
class Segment:
    title: str
    goal: str = ""
    sections: list[int] = field(default_factory=list)
    key_points: list[str] = field(default_factory=list)
    weight: float = 1.0
    target_words: int = 0
    turns: list[Turn] = field(default_factory=list)
    monologue: bool = False  # methodology/approach section delivered as one speaker's monologue


@dataclass
class Script:
    paper_title: str
    style: str
    language: str
    speakers: list[dict]
    segments: list[Segment]
    meta: dict = field(default_factory=dict)

    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False))

    @classmethod
    def load(cls, path: str | Path) -> "Script":
        d = json.loads(Path(path).read_text())
        segs = [Segment(**{**s, "turns": [Turn(**t) for t in s["turns"]]}) for s in d.pop("segments")]
        return cls(segments=segs, **d)

    def to_markdown(self) -> str:
        out = [f"# {self.paper_title}", ""]
        for i, s in enumerate(self.segments, 1):
            out += [f"## {i}. {s.title}", ""]
            out += [f"**{t.speaker}:** {t.text}\n" for t in s.turns]
        return "\n".join(out)

    @property
    def word_count(self) -> int:
        return sum(len(t.text.split()) for s in self.segments for t in s.turns)


# ------------------------------------------------------------------- helpers
def extract_json(text: str) -> dict:
    text = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object found")
    raw = text[start:end + 1]
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # common local-model slips: trailing commas, smart quotes
        raw = re.sub(r",\s*([}\]])", r"\1", raw).replace("“", '"').replace("”", '"')
        return json.loads(raw)


def parse_dialogue(text: str, names: list[str]) -> list[Turn]:
    alt = "|".join(re.escape(n) for n in names)
    head = re.compile(rf"^\s*(?:[*_#>\-\s]*)\b({alt})\b\s*(?:\([^)]*\))?\s*[*_]*\s*:\s*[*_]*\s*(.*)$", re.I)
    canon = {n.lower(): n for n in names}
    turns: list[Turn] = []
    for line in text.splitlines():
        m = head.match(line)
        if m:
            turns.append(Turn(canon[m.group(1).lower()], m.group(2).strip()))
        elif line.strip() and turns:
            turns[-1].text += " " + line.strip()
    # merge consecutive turns by the same speaker, drop empties
    merged: list[Turn] = []
    for t in turns:
        t.text = re.sub(r"\s+", " ", t.text).strip()
        if not t.text:
            continue
        if merged and merged[-1].speaker == t.speaker:
            merged[-1].text += " " + t.text
        else:
            merged.append(t)
    return merged


def _caption_referenced(caption: str, text: str) -> bool:
    m = re.match(r"\s*(fig(?:ure)?\.?|table|tab\.)\s*(\d+)", caption, re.I)
    if not m:
        return False
    kind = r"(?:Fig\.?|Figure)" if m.group(1).lower().startswith("fig") else r"(?:Table|Tab\.)"
    return re.search(rf"\b{kind}\s*{m.group(2)}\b", text) is not None


def split_text(text: str, max_chars: int) -> list[str]:
    """Split on paragraph, then sentence boundaries, into pieces <= max_chars."""
    max_chars = max(200, max_chars)
    if len(text) <= max_chars:
        return [text]
    pieces, cur = [], ""
    units = re.split(r"(\n\s*\n)", text)
    if max(len(u) for u in units) > max_chars:
        units = re.split(r"(?<=[.!?])\s+", text)
    for u in units:
        while len(u) > max_chars:  # pathological: no boundaries at all
            pieces.append(u[:max_chars])
            u = u[max_chars:]
        if len(cur) + len(u) > max_chars and cur:
            pieces.append(cur)
            cur = ""
        cur += u if u.isspace() or not cur else (" " + u)
    if cur.strip():
        pieces.append(cur)
    return pieces


# ----------------------------------------------------------------- generator
class ScriptGenerator:
    def __init__(self, llm: LLMClient, cfg: Config, workdir: Path, progress=print, reporter=None):
        self.llm, self.cfg, self.workdir = llm, cfg, workdir
        self.speakers: list[Speaker] = speakers_for(cfg)
        self.names = [s.name for s in self.speakers]
        self.system = P.system_prompt(cfg.script.style, self.speakers, cfg.script.language)
        self.progress = progress
        self.reporter = reporter  # optional ProgressReporter for the web server
        self.notes: dict[int, str] = {}   # section index -> notes
        self.notes_path = workdir / "notes.json"
        if self.notes_path.exists():
            self.notes = {int(k): v for k, v in json.loads(self.notes_path.read_text()).items()}
        self.tags: list[str] = self._load_tags()

    # -- utils
    def _load_tags(self) -> list[str]:
        tp = self.workdir / "tags.json"
        if tp.exists():
            try:
                data = json.loads(tp.read_text())
                return [str(t).strip() for t in data if str(t).strip()]
            except (ValueError, TypeError):
                return []
        return []

    def _save_tags(self) -> None:
        (self.workdir / "tags.json").write_text(
            json.dumps(self.tags, indent=1, ensure_ascii=False))

    def _tok(self, s: str) -> int:
        return self.llm.tokens.count(s)

    def _ask(self, user: str, max_tokens: int, temperature: float | None = None,
             system: str | None = None) -> str:
        msgs = [{"role": "system", "content": system or self.system},
                {"role": "user", "content": user}]
        need = self._tok(msgs[0]["content"] + user)
        b = self.llm.budget()
        if need > b.window - max_tokens:
            log.warning("prompt (~%d tok) + output (%d) may exceed window %d", need, max_tokens, b.window)
        res = self.llm.chat(msgs, max_tokens=max_tokens, temperature=temperature)
        if res.finish_reason == "length":
            log.warning("completion hit max_tokens (%d); output may be cut", max_tokens)
        return res.text

    def _room(self, b: Budget, system: str, template: str) -> int:
        """Tokens left for source text once system prompt + instructions are counted."""
        room = b.max_input - self._tok(system) - self._tok(template) - 32
        if room < MIN_ROOM:
            raise RuntimeError(
                f"Context window {b.window} is too small: only {room} tokens left for paper text. "
                "Raise num_ctx on the server, set llm.extra_body, or lower llm.max_output_tokens.")
        return room

    def _save_notes(self):
        self.notes_path.write_text(json.dumps(self.notes, indent=1, ensure_ascii=False))

    # -- 1. knowledge
    def _section_text(self, i: int, s: Section) -> str:
        return f"[SECTION {i}] {s.title}\n{s.text}"

    def _notes_for(self, idx: list[int], sections: list[Section], title: str, b: Budget,
                   report: bool = False) -> None:
        """Map step: create notes for the given sections, chunked to fit."""
        todo = [i for i in idx if i not in self.notes]
        if not todo:
            return
        if report and self.reporter is not None:
            self.reporter.set_stage("notes", f"Extracting knowledge from the paper ({len(todo)} sections)")
        room = self._room(b, NOTE_SYS, P.NOTES_PROMPT.format(title=title, text="", target_words=99999))
        chunk_chars = self.llm.tokens.chars_for(room)
        # Pack whole sections into chunks; split oversized sections.
        chunks: list[tuple[list[int], str]] = []
        cur_ids, cur = [], ""
        for i in todo:
            for piece in split_text(self._section_text(i, sections[i]), chunk_chars):
                if cur and len(cur) + len(piece) > chunk_chars:
                    chunks.append((cur_ids, cur))
                    cur_ids, cur = [], ""
                if i not in cur_ids:
                    cur_ids.append(i)
                cur += piece + "\n\n"
        if cur:
            chunks.append((cur_ids, cur))

        total = len(chunks) or 1
        for n, (ids, text) in enumerate(chunks, 1):
            self.progress(f"  notes {n}/{len(chunks)} (sections {ids})")
            if report and self.reporter is not None:
                self.reporter.advance(n / total)
                self.reporter.set_message(f"Extracting knowledge for sections {ids}")
            target = max(150, min(int(self._tok(text) * 0.3 * 0.75), int(b.max_output * 0.7)))
            out = self._ask(P.NOTES_PROMPT.format(title=title, text=text, target_words=target),
                            max_tokens=b.max_output, temperature=0.2,
                            system=NOTE_SYS)
            # Attribute notes back to sections via their [SECTION i] markers when the model
            # kept them; otherwise every section in the chunk shares the chunk's notes.
            parts = re.split(r"\[?SECTION (\d+)\]?", out)
            assigned: set[int] = set()
            for k in range(1, len(parts) - 1, 2):
                j = int(parts[k])
                if j in ids and parts[k + 1].strip():
                    self.notes[j] = (self.notes.get(j, "") + "\n" + parts[k + 1]).strip()
                    assigned.add(j)
            for j in ids:
                if j not in assigned:
                    self.notes[j] = (self.notes.get(j, "") + "\n" + out).strip()
            self._save_notes()

    def _digest(self, paper: Paper, sections: list[Section], b: Budget, limit: int) -> str:
        """Notes for all sections, recursively reduced until they fit `limit` tokens."""
        self._notes_for(list(range(len(sections))), sections, paper.title, b, report=True)
        digest = "\n\n".join(f"[SECTION {i}] {s.title}\n{self.notes[i]}" for i, s in enumerate(sections))
        reduce_room = self._room(b, NOTE_SYS, P.REDUCE_PROMPT.format(title=paper.title, text="",
                                                                      target_words=99999))
        rounds = 0
        while self._tok(digest) > limit and rounds < 4:
            rounds += 1
            self.progress(f"  reducing digest (round {rounds}, ~{self._tok(digest)} tok)")
            pieces = split_text(digest, self.llm.tokens.chars_for(reduce_room))
            # words ~= 0.75 * tokens; aim below the limit so the loop converges
            target = max(100, int(limit / len(pieces) * 0.6 * 0.75))
            digest = "\n\n".join(
                self._ask(P.REDUCE_PROMPT.format(title=paper.title, text=p, target_words=target),
                          max_tokens=b.max_output, temperature=0.2,
                          system=NOTE_SYS)
                for p in pieces)
        if self._tok(digest) > limit:
            log.warning("digest still ~%d tok > %d after reduction; truncating", self._tok(digest), limit)
            digest = digest[: self.llm.tokens.chars_for(limit)]
        return digest

    # -- 2. outline
    def _outline(self, paper: Paper, sections: list[Section], b: Budget) -> list[Segment]:
        index = "\n".join(f"{i}: {s.title} (~{self._tok(s.text)} tok)" for i, s in enumerate(sections))
        head = (f"TITLE: {paper.title}\n"
                + (f"AUTHORS: {', '.join(paper.authors)}\n" if paper.authors else "")
                + (f"DOI: {paper.doi}\n" if paper.doi else "")
                + f"ABSTRACT:\n{paper.abstract}")
        full = "\n\n".join([head] +
                           [self._section_text(i, s) for i, s in enumerate(sections)])
        if paper.captions:
            full += "\n\nFIGURE/TABLE CAPTIONS:\n" + "\n".join(paper.captions)
        minutes = self.cfg.script.target_minutes
        min_seg = max(3, min(6, int(minutes / 5)))
        max_seg = max(min_seg + 2, min(18, int(minutes / 2)))
        fmt = dict(minutes=minutes, min_seg=min_seg, max_seg=max_seg, index=index)
        room = self._room(b, OUTLINE_SYS, P.OUTLINE_PROMPT.format(kind="TEXT", text="", **fmt))
        if self.reporter is not None:
            self.reporter.set_stage("notes", "Preparing paper summary")
        if self._tok(full) <= room:
            kind, text = "TEXT", full
            self.progress(f"  paper fits in context (~{self._tok(full)} tok): direct mode")
        else:
            self.progress(f"  paper ~{self._tok(full)} tok > room {room}: digest mode")
            kind, text = "NOTES", head + "\n\n" + self._digest(paper, sections, b, room - self._tok(head))

        prompt = P.OUTLINE_PROMPT.format(kind=kind, text=text, **fmt)
        if self.reporter is not None:
            self.reporter.set_stage("outline", "Planning outline")
        msgs = [{"role": "system", "content": OUTLINE_SYS},
                {"role": "user", "content": prompt}]
        for attempt in range(3):
            res = self.llm.chat(msgs, max_tokens=b.max_output, temperature=0.3)
            try:
                data = extract_json(res.text)
                segs = [Segment(title=str(s["title"]), goal=str(s.get("goal", "")),
                                sections=[int(x) for x in s.get("sections", [])
                                          if str(x).strip().lstrip("-").isdigit()
                                          and 0 <= int(x) < len(sections)],
                                key_points=[str(k) for k in s.get("key_points", [])],
                                weight=float(s.get("weight", 1.0) or 1.0),
                                monologue=bool(s.get("monologue", False)))
                        for s in data["segments"]]
                if len(segs) >= 2:
                    tags = [str(t).strip().lower() for t in data.get("tags", []) if str(t).strip()]
                    if tags:
                        self.tags = tags[:6]
                    break
            except (ValueError, KeyError, TypeError) as e:
                log.warning("outline parse failed (%s), retrying", e)
                msgs = [msgs[0], {"role": "user", "content": prompt + "\n\n" + P.FIX_JSON}]
        else:
            raise RuntimeError("Model failed to produce a valid outline after 3 attempts")

        # Ensure every section is covered somewhere.
        used = {i for s in segs for i in s.sections}
        for i in range(len(sections)):
            if i not in used:
                nearest = min(range(len(segs)), key=lambda k: min(
                    (abs(j - i) for j in segs[k].sections), default=99))
                segs[nearest].sections.append(i)
        total_words = minutes * self.cfg.script.words_per_minute
        wsum = sum(max(0.2, s.weight) for s in segs)
        for s in segs:
            s.target_words = int(total_words * max(0.2, s.weight) / wsum)
        return segs

    # -- 3. segments
    def _methodology_ids(self, sections: list[Section]) -> set[int]:
        """Section indices whose title marks them as methodology/approach content.

        Built from a title heuristic plus the configured ``monologue_sections`` titles.
        These sections are delivered as a faithful monologue rather than summarized.
        """
        extra = {t.strip().lower() for t in self.cfg.script.monologue_sections if t.strip()}
        return {
            i for i, s in enumerate(sections)
            if self._lean_title(s.title) in P.METHODOLOGY_TITLES or self._lean_title(s.title) in extra
        }

    @staticmethod
    def _lean_title(title: str) -> str:
        """Strip leading numbering/prefix (e.g. '3 Method', '2.1 Approach') for title matching."""
        t = title.strip().lower()
        t = re.sub(r"^([\d.]+|[ivxlc]+\.?|[a-z]\.)\s+", "", t).strip()
        return t.rstrip(".:")

    def _source_for(self, seg: Segment, sections: list[Section], budget_tok: int,
                    paper: Paper, b: Budget) -> tuple[str, str]:
        ids = sorted(set(seg.sections)) or list(range(len(sections)))
        raw = "\n\n".join(self._section_text(i, sections[i]) for i in ids)
        caps = [c for c in paper.captions if c[:60] not in raw and _caption_referenced(c, raw)]
        if caps:
            raw += "\n\nRELEVANT CAPTIONS:\n" + "\n".join(caps)
        if self._tok(raw) <= budget_tok:
            return "original text", raw
        self._notes_for(ids, sections, paper.title, b)
        notes = "\n\n".join(f"[SECTION {i}] {sections[i].title}\n{self.notes[i]}" for i in ids)
        if self._tok(notes) <= budget_tok:
            return "notes", notes
        log.warning("segment '%s': notes exceed budget, truncating", seg.title)
        return "notes (truncated)", notes[: self.llm.tokens.chars_for(budget_tok)]

    def _write_segment(self, k: int, segs: list[Segment], sections: list[Section],
                       paper: Paper, history: list[Turn], b: Budget,
                       methodology_ids: set[int] | None = None) -> list[Turn]:
        seg = segs[k]
        a, bb = self.names
        n = len(segs)
        pos = "only" if n == 1 else "first" if k == 0 else "last" if k == n - 1 else "middle"
        plan = "\n".join(f"{'>>' if i == k else '  '} {i + 1}. {s.title}" for i, s in enumerate(segs))
        kp = "\n".join(f"- {p}" for p in seg.key_points) or "- (derive from the source)"
        # A methodology/approach segment (flagged by the outline or by section title) becomes a
        # faithful monologue delivered by the expert, so the technical content is never summarized away.
        monologue = seg.monologue or bool(
            methodology_ids and any(i in methodology_ids for i in seg.sections))
        tem = P.MONOLOGUE_PROMPT if monologue else P.SEGMENT_PROMPT
        covered = ""
        if not monologue:
            covered = "\n".join(f"- {s.title}: " + "; ".join(s.key_points[:4]) for s in segs[:k]) or "(nothing yet)"

        # Output budget: ~1.4 tokens per word; split into parts if one call can't hold it.
        words_per_call = int(b.max_output * 0.8 / 1.4)
        n_parts = max(1, math.ceil(seg.target_words / words_per_call))
        turns: list[Turn] = []

        # For a monologue, the segment is carried by ONE voice, so the source must never change
        # voice or get truncated to fit. Instead we split the ORIGINAL text into blocks that each
        # fit the window and generate one audio chunk per block, all in the same voice. Chunk count
        # is therefore driven by source size, not by word target.
        chunks: list[str] | None = None
        if monologue:
            ids = sorted(set(seg.sections)) or list(range(len(sections)))
            raw = "\n\n".join(self._section_text(i, sections[i]) for i in ids)
            caps = [c for c in paper.captions if c[:60] not in raw and _caption_referenced(c, raw)]
            if caps:
                raw += "\n\nRELEVANT CAPTIONS:\n" + "\n".join(caps)
            # Estimate the source budget against the real template (incl. plan/part_note overhead),
            # then chunk the original text into blocks that each fit within that budget.
            probe = tem.format(
                seg_no=k + 1, n_segs=n, title=paper.title, plan=plan, seg_title=seg.title,
                goal=seg.goal, key_points=kp,
                part_note="\nThis methodology is spoken across N audio chunks in the SAME voice.\n",
                covered=covered, recent="",
                source_kind="{source_kind}", source="{source}",
                position_rules=P.POSITION_RULES["only"].format(a=a, b=bb),
                words=seg.target_words, a=a, b=bb)
            probe_budget = b.max_input - self._tok(self.system + probe) - 64
            if probe_budget < MIN_ROOM:
                raise RuntimeError(f"Context window {b.window} too small for a monologue segment "
                                   f"({probe_budget} tokens left for source text)")
            # Leave room for verbatim recent-turns memory plus the real part_note, so a chunk that
            # fits here also fits the tighter per-part src_budget computed inside the loop below.
            chars = self.llm.tokens.chars_for(int(probe_budget * 0.8))
            chunks = split_text(raw, max(200, chars))
            n_parts = max(1, len(chunks))

        for part in range(n_parts):
            if monologue and chunks:
                # each block is its own chunk of audio, spoken in the same (expert) voice
                share = "first" if part == 0 else "next" if part < n_parts - 1 else "final"
                part_note = (f"\nThis methodology is spoken across {n_parts} audio chunks in the SAME voice. "
                             f"This is chunk {part + 1} (the {share} part). Carried by {bb} throughout, "
                             f"continuing seamlessly from the previous chunk.\n")
            else:
                part_note = ""
                if n_parts > 1:
                    share = "first" if part == 0 else "next" if part < n_parts - 1 else "remaining"
                    part_note = (f"\nThis segment is written in {n_parts} parts; write PART {part + 1} of "
                                 f"{n_parts}, covering roughly the {share} share of the key points.\n")
            opens = pos in ("first", "only") and part == 0
            closes = pos in ("last", "only") and part == n_parts - 1
            this_pos = "only" if opens and closes else "first" if opens else "last" if closes else "middle"

            # Shrink the verbatim memory until the source material gets a fair share of the window.
            n_recent = self.cfg.script.recent_turns_verbatim
            while True:
                recent_turns = (history + turns)[-n_recent:] if n_recent else []
                recent = ("LAST LINES SO FAR (continue from here):\n" +
                          "\n".join(f"{t.speaker}: {t.text}" for t in recent_turns) + "\n") if recent_turns else ""
                fixed = tem.format(
                    seg_no=k + 1, n_segs=n, title=paper.title, plan=plan, seg_title=seg.title,
                    goal=seg.goal, key_points=kp, part_note=part_note, covered=covered, recent=recent,
                    source_kind="{source_kind}", source="{source}",
                    position_rules=P.POSITION_RULES[this_pos].format(a=a, b=bb),
                    words=seg.target_words // n_parts, a=a, b=bb)
                src_budget = b.max_input - self._tok(self.system + fixed) - 64
                if src_budget >= max(MIN_ROOM, 0.35 * b.max_input) or n_recent <= 2:
                    break
                n_recent -= 2
            if src_budget < MIN_ROOM:
                raise RuntimeError(f"Context window {b.window} too small for segment prompts "
                                   f"({src_budget} tokens left for source text)")
            if monologue and chunks is not None:
                kind, source = "original text", chunks[part]
            else:
                kind, source = self._source_for(seg, sections, src_budget, paper, b)
            user = fixed.replace("{source_kind}", kind).replace("{source}", source)

            msgs = [{"role": "system", "content": self.system}, {"role": "user", "content": user}]
            for attempt in range(3):
                res = self.llm.chat(msgs, max_tokens=b.max_output)
                got = parse_dialogue(res.text, self.names)
                ok = len(got) >= 1
                if not monologue:
                    ok = len(got) >= 2 and len({t.speaker for t in got}) == 2
                if ok:
                    break
                log.warning("segment %d: unparseable dialogue, retrying", k + 1)
                # Re-ask with the format reminder appended (not the failed answer: keeps size bounded).
                msgs = [msgs[0], {"role": "user", "content": user + "\n\n" + P.FIX_FORMAT.format(a=a, b=bb)}]
            else:
                raise RuntimeError(f"Could not get dialogue for segment {k + 1}")
            turns += got
        return turns

    # -- driver
    def _cast_first_author(self, paper: Paper) -> None:
        """Rename + revoice the presenter speaker as the paper's first author.

        Applied when the PDF exposed authors. The speaker's configured role (its index in
        ``self.speakers``) is untouched, so persona and framing still hold.
        """
        if not paper.authors:
            return
        idx = next((i for i, s in enumerate(self.speakers)
                    if s.role == self.cfg.script.author_speaker), None)
        if idx is None:
            log.warning("no speaker with role '%s' to cast as first author "
                        "(set script.author_speaker)", self.cfg.script.author_speaker)
            return
        sp = self.speakers[idx]
        given = re_first_name(paper.authors[0]) or sp.name
        if given and given != sp.name:
            self.progress(f"  casting first author as {sp.role}: {sp.name} -> {given}")
            sp.name = given
        gender = self.cfg.script.author_gender
        if gender == "auto":
            gender = guess_gender(given)
        if gender:
            new_voice = voice_for(gender, sp.voice)
            if new_voice != sp.voice:
                self.progress(f"  voice for {given}: {sp.voice} -> {new_voice} ({gender})")
                sp.voice = new_voice
        self.names = [s.name for s in self.speakers]
        self.system = P.system_prompt(self.cfg.script.style, self.speakers, self.cfg.script.language)

    def generate(self, paper: Paper, reporter=None) -> Script:
        self.reporter = reporter
        self._cast_first_author(paper)
        b = self.llm.budget()
        ctx = self.llm.discover_context()
        self.progress(f"Context window {b.window} tok (source: {ctx.source}); "
                      f"input budget {b.max_input}, output {b.max_output}")
        sections = paper.body_sections(self.cfg.script.include_references)

        # Sections carrying methodology/approach content (flag from outline or title heuristic).
        methodology_ids: set[int] = self._methodology_ids(sections)

        outline_path = self.workdir / "outline.json"
        if outline_path.exists():
            segs = [Segment(**{**s, "turns": [Turn(**t) for t in s.get("turns", [])]})
                    for s in json.loads(outline_path.read_text())]
            self.progress(f"Loaded outline ({len(segs)} segments) from {outline_path}")
        else:
            self.progress("Planning outline...")
            segs = self._outline(paper, sections, b)
            outline_path.write_text(json.dumps([asdict(s) for s in segs], indent=2, ensure_ascii=False))
        if self.tags:
            self._save_tags()
        for i, s in enumerate(segs, 1):
            self.progress(f"  {i:2d}. {s.title}  ({s.target_words} words, sections {s.sections})")

        history: list[Turn] = []
        for k, seg in enumerate(segs):
            if seg.turns:  # resumed
                history += seg.turns
                continue
            self.progress(f"Writing segment {k + 1}/{len(segs)}: {seg.title}")
            if self.reporter is not None:
                self.reporter.set_stage("segments", f"Writing segment {k + 1}/{len(segs)}")
                self.reporter.advance(k / len(segs))
            seg.turns = self._write_segment(k, segs, sections, paper, history, b, methodology_ids)
            history += seg.turns
            if self.reporter is not None:
                self.reporter.advance((k + 1) / len(segs))
            outline_path.write_text(json.dumps([asdict(s) for s in segs], indent=2, ensure_ascii=False))

        return Script(paper_title=paper.title, style=self.cfg.script.style,
                      language=self.cfg.script.language,
                      speakers=[asdict(s) for s in self.speakers], segments=segs,
                      meta={"model": self.llm.cfg.model, "context_window": b.window,
                            "context_source": ctx.source, "usage": dict(self.llm.usage),
                            "tags": self.tags})
