"""paper2pod loopback web server — debugging / API entry point.

Runs the embedded UI on 127.0.0.1 only. The desktop app opens this same app in
a native pywebview window (see `cli.gui`); this module exists for running the
server standalone.
"""

import os

import uvicorn

from . import webapp


def main() -> None:
    host = os.environ.get("PAPER2POD_HOST", "127.0.0.1")
    port = int(os.environ.get("PAPER2POD_PORT", "8170"))
    webapp.set_serving_options(None, {})
    print(f"Serving web UI on http://{host}:{port}  (library: {webapp.STORE.root})", flush=True)
    uvicorn.run(webapp.app, host=host, port=port)


if __name__ == "__main__":
    main()