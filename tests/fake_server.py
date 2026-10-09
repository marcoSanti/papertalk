"""A tiny fake OpenWebUI for tests: /api/models, /ollama/api/show, /api/chat/completions.

It emulates Ollama's behaviour of *silently truncating the start* of prompts that
exceed `ctx` tokens, so the context probe and budget logic are exercised for real.
"""
from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CPT = 3.3  # chars per token the fake "tokenizer" uses


class FakeOpenWebUI:
    def __init__(self, ctx: int = 6000, honour_num_ctx: bool = False):
        self.ctx = ctx
        self.honour_num_ctx = honour_num_ctx
        self.calls: list[dict] = []
        srv = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, obj, code=200):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.rstrip("/") == "/api/models":
                    return self._json({"data": [
                        {"id": "fake-ollama", "owned_by": "ollama", "ollama": {"model": "fake-ollama"}},
                        {"id": "fake-openai", "owned_by": "openai", "context_length": 32000},
                    ]})
                self._json({"detail": "not found"}, 404)

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                req = json.loads(self.rfile.read(n) or b"{}")
                if self.path == "/ollama/api/show":
                    return self._json({"parameters": "stop <|eot|>",
                                       "model_info": {"llama.context_length": 131072}})
                if self.path.rstrip("/") == "/api/chat/completions":
                    return self._json(srv.complete(req))
                self._json({"detail": "not found"}, 404)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/api"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()

    # ------------------------------------------------------------- behaviour
    def complete(self, req: dict) -> dict:
        ctx = self.ctx
        if self.honour_num_ctx and (req.get("options") or {}).get("num_ctx"):
            ctx = req["options"]["num_ctx"]
        msgs = req["messages"]
        text = "\n".join(m["content"] for m in msgs)
        max_chars = int((ctx - req.get("max_tokens", 0)) * CPT)
        truncated = len(text) > max_chars
        visible = text[-max_chars:] if truncated else text   # Ollama drops the start
        self.calls.append({"chars": len(text), "truncated": truncated, "kind": self._kind(visible)})
        out = self._answer(visible, msgs)
        return {
            "id": "x", "object": "chat.completion", "created": 0, "model": req["model"],
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": out}}],
            "usage": {"prompt_tokens": int(len(visible) / CPT), "completion_tokens": int(len(out) / CPT),
                      "total_tokens": int((len(visible) + len(out)) / CPT)},
        }

    @staticmethod
    def _kind(t: str) -> str:
        if "secret code" in t:
            return "probe"
        if "Return ONLY a JSON object" in t:
            return "outline"
        if "Write dense technical NOTES" in t:
            return "notes"
        if "Merge them into a single" in t:
            return "reduce"
        if "CURRENT SEGMENT" in t:
            return "segment"
        return "other"

    def _answer(self, t: str, msgs) -> str:
        kind = self._kind(t)
        if kind == "probe":
            m = re.search(r"The secret code is (\S+)\.", t)
            return m.group(1) if m else "I don't know."
        if kind == "outline":
            idx = sorted({int(i) for i in re.findall(r"^(\d+): ", t.split("SECTION INDEX:")[1], re.M)})
            segs = [{"title": "Introduction and motivation", "goal": "why it matters",
                     "sections": idx[:2], "key_points": ["the problem", "the contribution"], "weight": 1}]
            for i in idx[2:]:
                segs.append({"title": f"Section {i} in depth", "goal": "details",
                             "sections": [i], "key_points": [f"point A of {i}", f"point B of {i}"],
                             "weight": 1.2})
            segs.append({"title": "Verdict and takeaways", "goal": "wrap up", "sections": [],
                         "key_points": ["limitations", "takeaways"], "weight": 0.6})
            return "Sure! Here is the plan:\n```json\n" + json.dumps({"segments": segs}) + "\n```"
        if kind in ("notes", "reduce"):
            ids = re.findall(r"\[SECTION (\d+)\]", t)
            return "\n".join(f"[SECTION {i}] notes: key result 92.4% accuracy; method uses X." for i in ids) \
                or "Merged notes: key result 92.4% accuracy."
        if kind == "segment":
            sysmsg = msgs[0]["content"]
            names = re.findall(r"^- (\w+) \(", sysmsg, re.M)[:2]
            seg = re.search(r'CURRENT SEGMENT: "([^"]+)"', t).group(1)
            a, b = names
            return (f"**{a}:** So, let's talk about {seg}. What is going on here?\n"
                    f"{b}: The authors report about ninety-two percent accuracy [3], which is e.g. a big jump.\n"
                    f"This continues the same turn.\n"
                    f"{a}: Interesting. And how does that compare to the baselines?\n"
                    f"{b}: It beats them by a clear margin on every benchmark they tried.")
        return "ok"
