"""Screenshot a dashboard page section by section and report console errors (dev tool).

Usage:  uv run --with playwright python tools/shot.py <page.html> [--width 1440] [--out data/screens] [--full]
Needs the server running (uv run serve.py). Saves <out>/<page>_<width>_<n>.png, one per viewport-height slice.
"""
import argparse
from pathlib import Path

from playwright.sync_api import sync_playwright

ap = argparse.ArgumentParser()
ap.add_argument("page")
ap.add_argument("--width", type=int, default=1440)
ap.add_argument("--height", type=int, default=1000)
ap.add_argument("--out", default="data/screens")
ap.add_argument("--wait", type=int, default=3500)
ap.add_argument("--full", action="store_true", help="one full-page image instead of slices")
a = ap.parse_args()
out = Path(a.out)
out.mkdir(parents=True, exist_ok=True)
stem = Path(a.page).stem
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome", headless=True)
    pg = b.new_page(viewport={"width": a.width, "height": a.height}, color_scheme="dark")
    logs = []
    pg.on("console", lambda m: logs.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
    pg.on("pageerror", lambda e: logs.append(f"pageerror: {e}"))
    pg.route("**/api/sync", lambda r: r.fulfill(json={"running": False, "step": None, "error": None, "last_sync": "2099-01-01T00:00:00"}) if r.request.method == "GET" else r.abort())
    pg.goto(f"http://localhost:8420/{a.page}", wait_until="networkidle")
    pg.wait_for_timeout(a.wait)
    files = []
    if a.full:
        f = out / f"{stem}_{a.width}_full.png"
        pg.screenshot(path=str(f), full_page=True)
        files.append(f)
    else:
        total = pg.evaluate("document.documentElement.scrollHeight")
        y, n = 0, 0
        while y < total and n < 30:
            pg.evaluate(f"window.scrollTo(0, {y})")
            pg.wait_for_timeout(900)
            f = out / f"{stem}_{a.width}_{n:02d}.png"
            pg.screenshot(path=str(f))
            files.append(f)
            y += a.height - 80
            n += 1
    print("\n".join(str(f) for f in files))
    real = [l for l in logs if "favicon" not in l and "404" not in l]
    print("\n".join(real) or "no console errors")
    b.close()
