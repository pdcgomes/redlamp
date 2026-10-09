"""Renders a canvas outside Cursor, with Cursor's own canvas runtime, and captures parts of it.

    python3 -m venv /tmp/rl-canvas-shot && /tmp/rl-canvas-shot/bin/pip install --quiet playwright pillow
    /tmp/rl-canvas-shot/bin/python .cursor/skills/workstream-canvas/capture.py <canvas.tsx> <out folder> \
        [--data=<canvas.data.json>] [--set=tab=Bugs] overview=0,1 now=2:700 measured=5

Each shot is `name=sections[:max height]`: the indices of the canvas's top-level sections (the
children of its root element) to frame together, in CSS pixels at a 1368 px width, rendered at 2x
in the dark theme. It compiles the canvas with the site's TypeScript (web/node_modules), serves it
on 127.0.0.1, and drives the installed Google Chrome with the flags Cursor's sandbox needs.

The canvas starts with no saved state unless --data gives it the `.canvas.data.json` beside it, so
it shows the owner's marks and choices as Cursor does. Each --set=<key>=<value> then sets one key of
that state (the value read as JSON when it parses, as text otherwise), such as the tab a canvas
keeps under `tab`. --now=<ISO time> stops the page's clock at that time, so "3 min ago" reads as it
did then.

The runtime is Cursor's own (canvas-runtime.esm.js inside Cursor.app), so captures look as they do
beside the chat; its path and the host object it expects (`window.__cursorCanvas` with `data` and
`state` maps) are Cursor's internals and may change with an update.
"""
import http.server
import json
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
RUNTIME = Path(
    "/Applications/Cursor.app/Contents/Resources/app/extensions/cursor-local-agent-runtime/dist/canvas-runtime/canvas-runtime.esm.js"
)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FLAGS = ["--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
PAGE = """<!doctype html><html><head><meta charset="utf-8"></head><body><div id="root"></div>
<script type="module">
import { mountCanvas } from "./canvas-runtime.esm.js";
window.__cursorCanvas = { data: new Map(Object.entries(__SEED__)), state: new Map() };
mountCanvas(new URL("./canvas.js", import.meta.url).href);
</script></body></html>"""
COMPILE = """
const ts = require(process.argv[1]);
const fs = require("fs");
let out = ts.transpileModule(fs.readFileSync(process.argv[2], "utf8"), { compilerOptions: {
  jsx: ts.JsxEmit.React, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText;
fs.writeFileSync(process.argv[3], out.replace(/import\\s*\\{[^}]*\\}\\s*from\\s*"cursor\\/canvas";?/g, ""));
"""
PAD = 20


def main(canvas: Path, out: Path, shots: list[str], seed: dict, now: str | None = None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as site, tempfile.TemporaryDirectory() as profile:
        site = Path(site)
        (site / "canvas-runtime.esm.js").write_bytes(RUNTIME.read_bytes())
        (site / "index.html").write_text(PAGE.replace("__SEED__", json.dumps(seed)))
        typescript = ROOT / "web/node_modules/typescript"
        subprocess.run(["node", "-e", COMPILE, str(typescript), str(canvas), str(site / "canvas.js")], check=True)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(site), **kwargs)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_address[1]}/index.html"

        with sync_playwright() as p:
            context = p.chromium.launch_persistent_context(
                profile, executable_path=CHROME, args=FLAGS, headless=True,
                viewport={"width": 1368, "height": 1000}, device_scale_factor=2, color_scheme="dark",
            )
            page = context.new_page()
            if now:
                page.clock.set_fixed_time(now)
            page.goto(url)
            page.wait_for_function("document.querySelector('#root')?.firstElementChild?.children.length > 0")
            page.wait_for_timeout(1500)
            for spec in shots:
                name, _, rest = spec.partition("=")
                indices, _, cap = rest.partition(":")
                boxes = [
                    page.evaluate(
                        "(i) => { const r = document.querySelector('#root').firstElementChild.children[i]"
                        ".getBoundingClientRect(); return [r.left, r.top + window.scrollY, r.right, r.bottom + window.scrollY]; }",
                        int(i),
                    )
                    for i in indices.split(",")
                ]
                x0, y0 = max(min(b[0] for b in boxes) - PAD, 0), max(min(b[1] for b in boxes) - PAD, 0)
                x1, y1 = max(b[2] for b in boxes) + PAD, max(b[3] for b in boxes) + PAD
                height = min(y1 - y0, float(cap)) if cap else y1 - y0
                path = out / f"{name}.png"
                page.screenshot(path=str(path), full_page=True, clip={"x": x0, "y": y0, "width": x1 - x0, "height": height})
                print(path)
            context.close()
        server.shutdown()


def state(options: list[str]) -> dict:
    seed: dict = {}
    for option in options:
        if option.startswith("--data="):
            seed.update(json.loads(Path(option.removeprefix("--data=")).read_text()))
    for option in options:
        if option.startswith("--set="):
            key, _, value = option.removeprefix("--set=").partition("=")
            try:
                seed[key] = json.loads(value)
            except json.JSONDecodeError:
                seed[key] = value
    return seed


if __name__ == "__main__":
    options = [arg for arg in sys.argv[3:] if arg.startswith("--")]
    shots = [arg for arg in sys.argv[3:] if not arg.startswith("--")]
    if len(sys.argv) < 4 or not shots:
        sys.exit(__doc__)
    clock = next((option.removeprefix("--now=") for option in options if option.startswith("--now=")), None)
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), shots, state(options), clock)
