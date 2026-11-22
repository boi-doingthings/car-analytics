"""Local web app: serves web/ and re-reads the iCloud i20_book folder on request. Localhost only.

Usage:  uv run serve.py [--port 8420]   then open http://localhost:8420
"""

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import threading
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).parent
WEB = ROOT / "web"
STATE = ROOT / "data" / "last_sync.json"
LOG = ROOT / "data" / "collect.log"
# Read-only viewer: the iPhone app writes i20_book, the Mac only reads it.
BOOK = Path(os.environ.get("I20_BOOK") or "~/Library/Mobile Documents/com~apple~CloudDocs/i20_book").expanduser()
NODE_MISSING = "Node.js not found \u2014 install it or set I20_NODE."


def find_node() -> str | None:
    """I20_NODE, else node on PATH, else the newest nvm-installed node."""
    if os.environ.get("I20_NODE"):
        return os.environ["I20_NODE"]
    found = shutil.which("node")
    if found:
        return found
    def ver(p: Path):
        return tuple(int(x) for x in re.findall(r"\d+", p.parent.parent.name))
    nvm = sorted(Path("~/.nvm/versions/node").expanduser().glob("*/bin/node"), key=ver)
    return str(nvm[-1]) if nvm else None


STEP = "analytics/cli.mjs"
EXIT_ERRORS = {
    127: NODE_MISSING,
    3: "Some files are still downloading from iCloud. Try again shortly.",
    2: "Can't read the i20_book folder in iCloud Drive.",
}

_lock = threading.Lock()
_status = {"running": False, "step": None, "error": None}


def read_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def run_cli() -> tuple[int, int]:
    """Run the analytics CLI; returns (exit code, issue count). Its output goes to the log."""
    with LOG.open("a") as log:
        log.write(f"\n== {dt.datetime.now():%Y-%m-%d %H:%M:%S} {STEP}\n")
        log.flush()
        node = find_node()
        if not node:
            log.write(NODE_MISSING + "\n")
            return 127, 0
        try:
            proc = subprocess.run([node, "analytics/cli.mjs", "--book", str(BOOK), "--out", "web"], cwd=ROOT, capture_output=True, text=True)
        except OSError as e:
            log.write(f"{e}\n")
            return 127, 0
        log.write(proc.stdout + proc.stderr)
    issues = 0
    try:
        issues = int(json.loads(proc.stdout.strip().splitlines()[-1]).get("issues", 0))
    except (ValueError, IndexError, AttributeError, TypeError):
        pass
    return proc.returncode, issues


def sync_error(code: int) -> str | None:
    if code == 0:
        return None
    return EXIT_ERRORS.get(code) or f"Reading the book failed (exit {code}); see data/collect.log"


def run_sync() -> None:
    try:
        _status["step"] = STEP
        code, issues = run_cli()
        err = sync_error(code)
        if err:
            raise RuntimeError(err)
        STATE.write_text(json.dumps({"last_sync": dt.datetime.now().isoformat(timespec="seconds"), "issues": issues}))
        _status["error"] = None
    except Exception as e:  # surfaced to the page
        _status["error"] = str(e)
    finally:
        _status.update(running=False, step=None)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WEB), **kw)

    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        if self.path.startswith("/data.json") or self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/sync":
            return self._json(200, {**_status, **read_state()})
        return super().do_GET()

    def do_POST(self):
        if self.path != "/api/sync":
            return self._json(404, {"error": "not found"})
        origin = self.headers.get("Origin", "")
        host = self.headers.get("Host", "")
        if origin and origin.split("://", 1)[-1] != host:
            return self._json(403, {"error": "cross-origin request refused"})
        with _lock:
            if not _status["running"]:
                _status.update(running=True, step="starting", error=None)
                threading.Thread(target=run_sync, daemon=True).start()
        return self._json(202, {**_status, **read_state()})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8420)
    parser.add_argument("--host", default="127.0.0.1", help="0.0.0.0 to serve beyond localhost")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if not (WEB / "data.json").exists():
        print("Building web/data.json from i20_book first...")
        code, _ = run_cli()
        if code:
            print(sync_error(code))
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://localhost:{args.port}"
    print(f"i20 dashboard on {url}  (Ctrl+C to stop)")
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
