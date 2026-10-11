"""paper2pod web server — single entry point.

Runs the web UI (the only supported interface). Config and the LLM/TTS settings
are read from env vars / config.yaml / the web UI's Settings gear.
"""

import os

import uvicorn

from . import webapp


def main() -> None:
    host = os.environ.get("PAPER2POD_HOST", "0.0.0.0")
    port = int(os.environ.get("PAPER2POD_PORT", "8170"))
    webapp.set_serving_options(None, {})
    print(f"Serving web UI on http://{host}:{port}  (library: {webapp.LIBRARY})")
    uvicorn.run(webapp.app, host=host, port=port)


if __name__ == "__main__":
    main()