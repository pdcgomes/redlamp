#!/usr/bin/env python3
"""
The pixelkit promo's pictures (src/pixelkit/PixelkitPromo.tsx): every frame drawn by pixelkit, the
pixel-art kit in github.com/pdcgomes/pixelartvisuals, at its 320×180 canvas, from the promo's cue
sheet (src/pixelkit/cues.json) and words (src/pixelkit/copy.json). The composition shows them six
times the size, pixelated, so 1920×1080 holds every pixel as a 6×6 block and every word is in the
kit's own bitmap fonts.

    python3 scripts/pixelkit-frames.py              # public/pixelkit/frames/0000.png … with the default hook
    python3 scripts/pixelkit-frames.py --hooks      # and the opening of every other hook, in frames-<hook>/
    python3 scripts/pixelkit-frames.py --only 0,96  # just these frames, for a quick look

The kit is found at $PIXELKIT, or ~/src/pixelartvisuals. Needs Pillow and numpy.

It opens in the sysop's bedroom (examples/bedroom.py) as the PC dials a BBS, with the hook in a
dialog box; punches in on the CRT; picks SHOWCASE from the BBS's menu and switches the CRT off; cuts
through the showcase on every bar, faster at the end; shows the code behind a chart; and asks for a
star on an arcade's CONTINUE? screen, counting down on the beat, before it fades out in dither.
"""

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
KIT = Path(os.environ.get("PIXELKIT", Path.home() / "src/pixelartvisuals"))
sys.path.insert(0, str(KIT / "skill/scripts"))

from pixelkit import Canvas, blink, reveal  # noqa: E402

sheet = json.loads((ROOT / "src/pixelkit/cues.json").read_text())
copy = json.loads((ROOT / "src/pixelkit/copy.json").read_text())
FPS = sheet["fps"]
BEAT = 60 / sheet["bpm"]
PER_BEAT = BEAT * FPS
FRAMES = round(sheet["bars"] * sheet["beatsPerBar"] * PER_BEAT)
cue = sheet["cues"]
DEFAULT_HOOK = next(iter(copy["hooks"]))
W, H = 320, 180
RAINBOW = ["red", "orange", "gold", "lime", "cyan", "sky", "violet"]
BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16


def load(path):
    spec = importlib.util.spec_from_file_location(Path(path).stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bedroom = load(KIT / "examples/bedroom.py")
arcade = load(KIT / "examples/arcade.py")
# The showcase's animations, and how long each one's loop runs (seamless ones wrap).
PIECES = {
    "tracker": (load(KIT / "examples/tracker.py"), 3.2, True),
    "fruitmusic": (load(KIT / "examples/fruitmusic.py"), 4.0, True),
    "daw": (load(KIT / "examples/daw.py"), 1.6, True),
    "finance": (load(KIT / "examples/finance.py"), 4.0, True),
    "hacker": (load(KIT / "examples/hacker.py"), 6.0, False),
    "rpg": (load(KIT / "examples/rpg.py"), 4.0, True),
    "skyline": (load(KIT / "examples/skyline.py"), 4.0, True),
}
dashboard = load(KIT / "skill/examples/dashboard_live.py")
PIECES["dashboard"] = (dashboard, dashboard.SECONDS, True)
# The stills, read back from their 4× PNGs at one pixel per logical pixel.
STILLS = {
    "commits": KIT / "examples/commits.png",
    "planets": KIT / "examples/planets.png",
    "moon": KIT / "examples/moon.png",
    "overview": KIT / "projects/redlamp-architecture/01_overview.png",
}
_stills = {}


def still(name):
    if name not in _stills:
        im = Image.open(STILLS[name]).convert("RGB")
        _stills[name] = im.resize((W, H), Image.NEAREST)
    return _stills[name]


def canvas():
    return Canvas(preset="wide")


def rainbow_text(c, x, y, s, *, scale, shift=0, align="center"):
    """Text with each letter in the next colour of the rainbow."""
    width = c.measure(s, "large", scale)
    x = x - width // 2 if align == "center" else x
    advance = lambda ch: c.measure(ch + "A", "large", scale) - c.measure("A", "large", scale)
    for i, ch in enumerate(s):
        if ch != " ":
            c.text(x, y, ch, RAINBOW[(i + shift) % len(RAINBOW)], font="large", scale=scale, shadow="#1a0a20",
                   check=False)
        x += advance(ch)


def fade(c, amount):
    """Darken towards black through an ordered dither, as the hardware this imitates would have."""
    if amount <= 0:
        return
    a = np.asarray(c.img).copy()
    h, w = a.shape[:2]
    mask = np.tile(BAYER4, (h // 4 + 1, w // 4 + 1))[:h, :w] < amount
    a[mask] = 0
    c.img = Image.fromarray(a)


# ---------------------------------------------------------------- the bedroom and the hook

def dialog(c, lines, b, y_shift=0):
    """A JRPG text box across the bottom: the first line from the first frame, the second on its cue."""
    x, y, w, h = 4, 132 + y_shift, 312, 44
    c.rect(x, y, w, h, "#0c1446")
    c.box(x, y, w, h, "white")
    c.box(x + 2, y + 2, w - 4, h - 4, "#6a7ad8")
    for px, py in ((x, y), (x + w - 1, y), (x, y + h - 1), (x + w - 1, y + h - 1)):
        c.px(px, py, "#000000")
    c.text(x + 10, y + 8, lines[0], "white", font="large", scale=2, check=False)
    if b >= cue["hook2"]:
        typed = reveal(lines[1], (b - cue["hook2"]) / 0.5)
        c.text(x + 10, y + 26, typed, "gold", font="large", scale=2, check=False)
        if typed == lines[1] and blink(b, 1):
            c.text(x + w - 12, y + h - 9, "▼", "white", check=False)


def intro(c, f, b, hook):
    sec = f / FPS
    bedroom.draw(c, sec / bedroom.SECONDS)
    leave = cue["connect"] - 0.5
    if b < cue["connect"]:
        shift = 0 if b < leave else round((b - leave) / 0.5 * 48)
        dialog(c, copy["hooks"][hook], b, shift)


def zoom(c, f):
    """Twice the size, on the CRT, as the BBS answers."""
    desk = Canvas(W, H, theme=c.theme, bg="#0a0a16")
    top = 13
    bedroom.crt(desk, 208, top + 1, f / FPS)
    bedroom.modem_panel(desk, 208, top + 104, f / FPS)
    crop = desk.img.crop((184, 19, 344, 109)).resize((W, H), Image.NEAREST)
    c.img.paste(crop, (0, 0))


# ---------------------------------------------------------------- the BBS

def bbs(c, b):
    c.rect(0, 0, W, H, bedroom.BEIGE["top"])
    c.hline(0, 0, W, "#efe6c8")
    c.hline(0, H - 1, W, bedroom.BEIGE["right"])
    c.rect(6, 5, W - 12, H - 18, "#3a3628")
    screen = Canvas(W - 16, H - 22, theme=c.theme, bg="#04060c")
    s = screen
    shift = int(b * 4)
    rainbow_text(s, s.w // 2, 6, copy["bbs"]["title"], scale=3, shift=shift)
    s.strip(8, 30, s.w - 16, 2, RAINBOW)
    s.text(s.w // 2, 36, copy["bbs"]["sub"], "dim", align="center")
    menu = copy["bbs"]["menu"]
    shown = int((b - cue["menu"]) / 0.5) + 1 if b >= cue["menu"] else 0
    picked = b >= cue["press"]
    for k, (key, label) in enumerate(menu[:shown]):
        y = 50 + k * 18
        chosen = picked and key == copy["bbs"]["command"]
        if chosen:
            s.rect(10, y - 3, s.w - 20, 20, "#1c3a8a")
        s.text(16, y, f"[{key}]", "sky" if not chosen else "white", font="large", scale=2, check=False)
        s.text(56, y, label, "white" if not chosen else "gold", font="large", scale=2, check=False)
    if b >= cue["press"] - 0.5:
        prompt = "COMMAND: " + (copy["bbs"]["command"] if picked else "")
        w = s.text(16, s.h - 12, prompt, "gold", font="large", check=False)
        if blink(b, 2):
            s.rect(17 + w, s.h - 12, 5, 7, bedroom.PHOSPHOR)
    rows = np.asarray(screen.img).copy()
    rows[::2] = (rows[::2].astype(np.uint16) * 3 // 4).astype(np.uint8)
    img = Image.fromarray(rows)
    if b >= cue["off"]:
        img = power_off(img, (b - cue["off"]) / (cue["drop"] - cue["off"]))
    c.img.paste(img, (8, 7))
    c.text(10, H - 10, "PIXELTRON 12", "#6a5e44")
    c.rect(W - 18, H - 9, 6, 3, "lime" if b < cue["off"] else "#2a3a1a")


def power_off(img, p):
    """A CRT switching off: the picture squashes to a line, the line to a dot, then black."""
    w, h = img.size
    out = Image.new("RGB", (w, h), (4, 6, 12))
    if p < 0.35:
        squash = max(2, round(h * (1 - p / 0.35) ** 2))
        out.paste(img.resize((w, squash), Image.NEAREST), (0, (h - squash) // 2))
    elif p < 0.7:
        length = max(2, round(w * (1 - (p - 0.35) / 0.35)))
        line = Image.new("RGB", (length, 2), (230, 240, 255))
        out.paste(line, ((w - length) // 2, h // 2 - 1))
    elif p < 0.85:
        out.paste(Image.new("RGB", (2, 2), (230, 240, 255)), (w // 2 - 1, h // 2 - 1))
    return out


# ---------------------------------------------------------------- the showcase

def montage(c, b):
    entries = sheet["montage"]
    k = max(i for i, e in enumerate(entries) if e[0] <= b)
    start, name, offset, caption = entries[k]
    local = (b - start) * BEAT + offset
    if name in STILLS:
        c.img.paste(still(name), (0, 0))
    else:
        module, seconds, seamless = PIECES[name]
        t = (local / seconds) % 1 if seamless else min(local / seconds, 1.0)
        module.draw(c, t)
    banner(c, caption, (b - start), k + 1, len(entries))


def banner(c, caption, since, n, total):
    """The caption along the bottom: a rainbow rule, the word typed in on its beat, and a counter."""
    y = 154
    c.rect(0, y, W, H - y, "#0a0a16")
    c.strip(0, y, W, 2, RAINBOW)
    c.text(8, y + 8, reveal(caption, since / 0.25), "white", font="large", scale=2, check=False)
    c.text(W - 8, y + 12, f"{n:02d}/{total:02d}", "dim", font="large", align="right", check=False)


# ---------------------------------------------------------------- how it's made

COFFEE = [3, 2, 4, 5, 6, 1, 2]


def how(c, b):
    c.rect(0, 0, W, H, "bg")
    title = copy["how"][0] if b < cue["skill"] else copy["how"][1]
    since = b - (cue["how"] if b < cue["skill"] else cue["skill"])
    c.text(W // 2, 8, reveal(title, since / 0.25), "white", font="large", scale=2, align="center", check=False)
    c.strip(W // 2 - 60, 26, 120, 2, RAINBOW)

    ed = c.panel(0, 34, 200, 132, "COFFEE.PY", color="gold", right="PYTHON")
    starts = sheet["code"]
    for i, line in enumerate(copy["code"]):
        y = ed.y + 4 + i * 14
        c.text(ed.x, y, str(i + 1), "dim", font="code", check=False)
        if b >= starts[i]:
            typed = reveal(line, (b - starts[i]) / 0.75)
            w = c.text(ed.x + 10, y, typed, "white", font="code", check=False)
            if typed != line or (i == len(copy["code"]) - 1 and blink(b, 2)):
                c.rect(ed.x + 11 + w, y, 5, 7, "gold")
    if b >= cue["skill"]:
        ask = "> a chart of my coffee, pixel style"
        y = ed.y2 - 26
        c.rect(ed.x - 2, y - 4, ed.w + 4, 16, "#1c2a5a")
        c.text(ed.x + 2, y, reveal(ask, (b - cue["skill"]) / 1.0), "lime.light", font="code", check=False)

    out = c.panel(204, 34, 116, 132, "COFFEE.PNG", color="orange")
    chart_at = starts[2] + 0.75
    if b >= chart_at:
        grow = min(1.0, (b - chart_at) / 1.5)
        c.bar_chart(out.x, out.y + 22, out.w, out.h - 36, COFFEE, xlabels=["M", "T", "W", "T", "F", "S", "S"],
                    ticks=3, ymax=6, grow=grow)
    if b >= starts[3] + 0.75:
        c.icon(out.x, out.y2 - 8, "check", "lime")
        c.text(out.x + 10, out.y2 - 7, "SAVED", "lime", check=False)


# ---------------------------------------------------------------- the ask

def ask(c, b):
    c.rect(0, 0, W, H, "#000000")
    step = int(b * 2) % 2
    march = 2 * (int(b) % 4) - 3
    for row, (frames, color, w) in enumerate([(arcade.SQUID, "violet.light", 8), (arcade.CRAB, "cyan", 11)]):
        for i in range(10):
            x = 160 - 90 + i * 18 + (18 - w) // 2 + march * 2
            c.sprite(x, 4 + row * 10, frames[step], {"#": color})
    text = copy["ask"]
    thanks = b >= cue["thanks"]
    rainbow_text(c, W // 2, 26, text["thanks"] if thanks else text["continue"], scale=2 if thanks else 3,
                 shift=int(b * 6))

    coin = b >= cue["coin"]
    counts = sheet["countdown"]
    if not coin and b >= counts[0]:
        n = 9 - max(i for i, beat in enumerate(counts) if beat <= b)
        c.text(W // 2, 54, str(n), "gold", font="large", scale=6, align="center", shadow="#3a2208", check=False)
    elif coin:
        bob = 0 if thanks else round(-6 * max(0.0, 1 - (b - cue["coin"]) / 0.5))
        c.icon(W // 2 - 21, 56 + bob, "star", "gold", scale=6)

    y = 104
    tw = c.measure(text["title"], "large", 2)
    tx = W // 2 - (tw + 18) // 2
    c.icon(tx, y + 3, "star", "gold" if coin or blink(b, 1) else "dim", scale=1)
    c.text(tx + 12, y, text["title"], "white", font="large", scale=2, check=False)
    c.text(W // 2, y + 22, text["address"], "sky.light", font="large", align="center", check=False)
    c.text(W // 2, y + 34, text["reason"], "dim", align="center", check=False)
    c.text(8, H - 10, "1UP", "red", check=False)
    c.text(W - 8, H - 10, "CREDIT 01" if coin else "CREDIT 00", "white" if coin else "dim", align="right", check=False)
    c.hline(0, H - 13, W, "lime")
    if b >= cue["fade"]:
        fade(c, (b - cue["fade"]) / (cue["out"] - cue["fade"]) * 1.05)


# ---------------------------------------------------------------- the film

def frame(f, hook):
    b = f / PER_BEAT
    c = canvas()
    if b < cue["zoom"]:
        intro(c, f, b, hook)
    elif b < cue["bbs"]:
        zoom(c, f)
    elif b < cue["drop"]:
        bbs(c, b)
    elif b < cue["how"]:
        montage(c, b)
    elif b < cue["ask"]:
        how(c, b)
    else:
        ask(c, b)
    return c.img


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hook", default=DEFAULT_HOOK, choices=list(copy["hooks"]))
    parser.add_argument("--hooks", action="store_true", help="also the opening of every other hook")
    parser.add_argument("--only", help="comma-separated frames")
    args = parser.parse_args()
    out = ROOT / "public/pixelkit"
    jobs = [(out / "frames", args.hook, range(FRAMES))]
    if args.hooks:
        opening = range(round(cue["bbs"] * PER_BEAT))
        jobs += [(out / f"frames-{h}", h, opening) for h in copy["hooks"] if h != args.hook]
    if args.only:
        wanted = [int(x) for x in args.only.split(",")]
        jobs = [(d, h, [f for f in fs if f in wanted]) for d, h, fs in jobs[:1]]
    for folder, hook, frames in jobs:
        folder.mkdir(parents=True, exist_ok=True)
        for f in frames:
            frame(f, hook).save(folder / f"{f:04d}.png", optimize=True)
        print(f"==> {folder.relative_to(ROOT)} ({len(frames)} frames, hook {hook})")


if __name__ == "__main__":
    main()
