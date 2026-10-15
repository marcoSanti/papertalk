"""A stand-in OpenAI-compatible LLM for the Linux end-to-end import
(client-linux/e2e/import.sh). It answers each pipeline prompt with a canned reply,
matched on the same markers the Swift test suite's MockLLM uses."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

META = {"title": "Attention Mechanisms in Modern Models", "authors": ["Ada Lovelace", "Grace Hopper"],
        "affiliations": ["UCL"], "doi": "", "tags": ["nlp"]}
CAST = {"speakers": [{"role": "Interviewer", "gender": "male", "name": "Jordan"},
                     {"role": "Scientist", "gender": "female", "name": "Ada"}],
        "authors": [{"name": "Ada Lovelace", "gender": "female"}, {"name": "Grace Hopper", "gender": "female"}]}
OUTLINE = {"tags": ["nlp"],
           "sections": [{"title": "Abstract", "min_sec": 20}, {"title": "Method", "min_sec": 20}],
           "segments": [{"title": "Abstract", "goal": "overview", "sections": [1], "key_points": ["survey"],
                         "weight": 0.5, "monologue": False},
                        {"title": "Method", "goal": "how", "sections": [2], "key_points": ["attention"],
                         "weight": 0.5, "monologue": False}]}
DIALOGUE = ("Jordan: Welcome to Papertalk, running on Linux today.\n"
            "Ada: Thanks. This paper looks at how attention lets a model focus on the right words.\n"
            "Jordan: What did the authors actually measure?\n"
            "Ada: They compared it with a recurrent baseline and saw clear gains in translation quality.\n")


def reply_for(text: str) -> str:
    if "bibliographic metadata" in text:
        return json.dumps(META)
    if "You are casting" in text:
        return json.dumps(CAST)
    if '"segments": [{"title"' in text or '"sections": [{"title"' in text:
        return json.dumps(OUTLINE)
    if "METHOD TEXT" in text:
        return "The model projects queries, keys and values and attends over the whole sequence."
    if "SEGMENT" in text:
        return DIALOGUE
    return "{}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, body: dict):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send({"data": [{"id": "fake-model"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        text = "\n".join(str(m.get("content", "")) for m in body.get("messages", []))
        self._send({"choices": [{"message": {"role": "assistant", "content": reply_for(text)}}]})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Handler).serve_forever()
