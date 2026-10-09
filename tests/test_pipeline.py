import json
import sys
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

sys.path.insert(0, str(Path(__file__).parent))
from fake_server import FakeOpenWebUI  # noqa: E402
from make_sample_pdf import build  # noqa: E402

from paper2pod.audio import normalize_for_tts
from paper2pod.cli import main
from paper2pod.config import LLMConfig
from paper2pod.llm import LLMClient
from paper2pod.pdf_extract import extract_paper
from paper2pod.script import extract_json, parse_dialogue, split_text


@pytest.fixture
def server():
    s = FakeOpenWebUI(ctx=6000)
    yield s
    s.close()


@pytest.fixture
def pdf(tmp_path):
    p = tmp_path / "paper.pdf"
    build(str(p), paras_per_section=6)
    return p


def test_extract_structure(pdf):
    p = extract_paper(pdf)
    titles = [s.title for s in p.sections]
    assert p.title.startswith("Sparse Routing Attention")
    assert "3 Method" in titles and "References" in titles
    assert p.sections[-1].is_references
    assert p.abstract
    assert "Preprint" not in p.full_text(True)          # running header removed
    assert len(p.captions) == 2


def test_parse_dialogue_tolerant():
    txt = "**Alex:** Hi there.\ncontinued line\nSam (laughing): Hello!\nSam: Again.\n\nnoise"
    turns = parse_dialogue(txt, ["Alex", "Sam"])
    assert [t.speaker for t in turns] == ["Alex", "Sam"]
    assert turns[0].text == "Hi there. continued line"
    assert turns[1].text == "Hello! Again. noise"


def test_extract_json_variants():
    assert extract_json('blah ```json\n{"a": [1,2,],}\n``` end') == {"a": [1, 2]}


def test_split_text_bounds():
    text = "\n\n".join("word " * 50 for _ in range(10))
    parts = split_text(text, 600)
    assert all(len(p) <= 600 for p in parts) and len(parts) > 3


def test_normalize_for_tts():
    out = normalize_for_tts("Smith et al. [3] got ~92% (Jones, 2020), e.g. **bold**.")
    assert out == "Smith and colleagues got about 92 percent, for example, bold."


def test_context_probe_detects_silent_truncation(server, tmp_path):
    cfg = LLMConfig(base_url=server.url, model="fake-ollama", probe_context="auto")
    llm = LLMClient(cfg, tmp_path)
    info = llm.discover_context()
    # Metadata says 131072 (architectural max) but the runtime truncates at 6000.
    assert info.source == "probe"
    assert 4096 < info.window <= 6000
    # cached on second call
    assert LLMClient(cfg, tmp_path).discover_context().source == "probe"


def test_context_from_metadata(server, tmp_path):
    cfg = LLMConfig(base_url=server.url, model="fake-openai")
    info = LLMClient(cfg, tmp_path).discover_context()
    assert info.window == 32000 and info.source == "models metadata"


def test_end_to_end_digest_mode(server, pdf, tmp_path, capsys):
    out = tmp_path / "out"
    main(["run", str(pdf), "-o", str(out), "--base-url", server.url, "--model", "fake-ollama",
          "--backend", "null", "--format", "wav", "--minutes", "6", "--style", "peers"])
    wd = out / "paper"
    script = json.loads((wd / "script.json").read_text())
    assert script["meta"]["context_source"] == "probe"
    names = {s["name"] for s in script["speakers"]}
    assert names == {"Maya", "Leo"}
    assert all(t["speaker"] in names for s in script["segments"] for t in s["turns"])
    # every non-reference section used
    used = {i for s in script["segments"] for i in s["sections"]}
    assert used >= set(range(8))
    # paper (~22k chars) cannot fit 4096 tokens -> notes were produced
    assert (wd / "notes.json").exists()
    kinds = {c["kind"] for c in server.calls}
    assert {"probe", "notes", "outline", "segment"} <= kinds
    # no real call (other than probes) was silently truncated
    assert not any(c["truncated"] for c in server.calls if c["kind"] != "probe")
    audio, sr = sf.read(wd / "podcast.wav")
    assert len(audio) / sr > 30
    assert (wd / "podcast.srt").read_text().startswith("1\n00:00:00")


def test_resume_skips_llm(pdf, tmp_path):
    server = FakeOpenWebUI(ctx=32000)
    args = ["script", str(pdf), "-o", str(tmp_path), "--base-url", server.url,
            "--model", "fake-openai"]
    main(args)
    n = len(server.calls)
    main(args)
    assert len(server.calls) == n   # outline + segments reloaded from outline.json
    server.close()


def test_lying_metadata_is_detected(server, pdf, tmp_path):
    # /models says 32000 but the server truncates at 6000 -> must fail loudly, not hallucinate.
    from paper2pod.llm import ContextTruncatedError
    with pytest.raises(ContextTruncatedError):
        main(["script", str(pdf), "-o", str(tmp_path), "--base-url", server.url, "--model", "fake-openai"])


def test_custom_plugin_by_import_path(tmp_path, monkeypatch):
    mod = tmp_path / "my_tts.py"
    mod.write_text(
        "import numpy as np\nfrom paper2pod.tts import TTSBackend\n"
        "class Beep(TTSBackend):\n    name='beep'\n"
        "    @property\n    def sample_rate(self): return 8000\n"
        "    def synthesize(self, text, voice, speed=1.0): return np.ones(800, np.float32)*0.1\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    from paper2pod.tts import create_backend
    b = create_backend("my_tts:Beep", device="auto")
    assert b.device == "cpu" and b.synthesize("hi", "x").shape == (800,)


def test_kokoro_backend_wiring_with_stub(monkeypatch):
    """Exercises KokoroBackend against a stub `kokoro` module (no torch / model download)."""
    import types
    created = []

    class KModel:
        def __init__(self, repo_id=None):
            self.repo_id = repo_id
        def to(self, device):
            self.device = device
            return self
        def eval(self):
            return self

    class KPipeline:
        def __init__(self, lang_code, repo_id=None, model=None):
            created.append(lang_code)
            self.model = model
        def __call__(self, text, voice, speed=1.0, split_pattern=None):
            for _ in text.split("\n"):
                yield "g", "p", np.full(2400, 0.1, np.float32)

    monkeypatch.setitem(sys.modules, "kokoro", types.SimpleNamespace(KModel=KModel, KPipeline=KPipeline))
    from paper2pod.tts import create_backend
    b = create_backend("kokoro", device="cpu")
    assert b.sample_rate == 24000 and b.model.device == "cpu"
    assert b.synthesize("one\ntwo", "am_michael").shape == (4800,)
    b.synthesize("ciao", "if_sara")
    b.synthesize("again", "af_heart")
    assert created == ["a", "i"]            # one pipeline per language, shared model
    b.validate_voice("af_bella,af_heart")
    with pytest.raises(ValueError):
        b.validate_voice("xx_nobody")
