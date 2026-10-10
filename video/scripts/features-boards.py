#!/usr/bin/env python3
"""
The feature videos' storyboard sheets (docs/plans/2026-10-10-feature-videos.md). Each episode's board,
scripts/features/boards/<episode>.py, defines its eight panels, one a bar, drawn with the shared pieces
in scripts/features/world.py. This lays them out in two rows of four at twice their size, with the bar,
time, words and sound under each and the claim's source from docs/social/posts.json in the footer, and
writes the cover (the opener's frame its first post names, the hook over the lit lamp) and the result
at their own size for the social room.

    python3 scripts/features-boards.py --episode e01   # out/features/boards/e01.png, e01-hook.png, e01-result.png
    python3 scripts/features-boards.py --all
    python3 scripts/features-boards.py --episode e01 --zones   # the covered zones outlined on each panel

When the result panel's draw function takes a progress, it also writes <episode>-reveal.png, the real
photo halfway through resolving out of the pixel one. Needs Pillow and numpy, and pixelkit at $PIXELKIT
or ~/src/pixelartvisuals. Every warning the kit or the safe zones raise is printed; fix them all.
"""

import argparse
import importlib.util
import inspect
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from features import world as w  # noqa: E402

BOARDS = w.VIDEO / "scripts/features/boards"
OUT = w.VIDEO / "out/features/boards"
SHEET = 2
GAP, PAD, HEAD = 8, 8, 16
NOTE_W = w.W - 10


def load(path):
    spec = importlib.util.spec_from_file_location(f"board_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def draw(panel, *, zones=False, **kw):
    """A panel on its own canvas, its overlays, and its warnings."""
    c = w.canvas()
    overlays = panel.draw(c, **kw) or []
    notes = w.check(c)
    if zones:
        for zone, _ in w.covered():
            c.box(*zone, "#c04a8a")
    return c, overlays, notes


def notes_height(panel):
    small = w.FONTS["small"]
    words = small.wrap(panel.words, w.W)
    sound = small.wrap(panel.sound, NOTE_W)
    return 9 + 7 * len(words) + 3 + 7 * len(sound)


def sheet(key, board, drawn):
    ep = board.EPISODE
    under = max(notes_height(p) for p in board.PANELS) + 4
    footer = [f"CLAIM: {ep['feature']}", f"SOURCE: {ep['source']}"]
    if getattr(board, "PHOTO", None):
        footer.append(f"PHOTO: {board.PHOTO}")
    width = 2 * PAD + 4 * w.W + 3 * GAP
    lines = sum(len(w.FONTS["small"].wrap(ln, width - 8)) for ln in footer)
    foot_h = 4 + 7 * lines - 2 + 4 + 1
    height = HEAD + 6 + 2 * (w.H + 4 + under) + GAP + foot_h
    c = w.canvas(width, height, SHEET)
    c.footer(footer)
    variant = f" · {board.VARIANT}" if getattr(board, "VARIANT", None) else ""
    title = f"REDLAMP FEATURE VIDEOS · {ep['id'].upper()} {ep['title'].upper()}{variant} · STORYBOARD"
    right = f"{w.BPM} BPM · 8 BARS · {8 * w.BAR:.1f} S · {w.W * w.SCALE} × {w.H * w.SCALE}"
    c.header(title, right=right, font="large", h=HEAD, mark=w.LAMP_MARK)
    overlays = []
    for i, (panel, (pc, pov, _)) in enumerate(zip(board.PANELS, drawn)):
        x = PAD + (i % 4) * (w.W + GAP)
        y = HEAD + 6 + (i // 4) * (w.H + 4 + under + GAP)
        c.box(x - 1, y - 1, w.W + 2, w.H + 2, "line")
        c.paste(pc, x, y)
        overlays += [ov._replace(rect=w.Rect(ov.rect.x + x, ov.rect.y + y, ov.rect.w, ov.rect.h)) for ov in pov]
        ty = y + w.H + 5
        c.spans(x, ty, [(f"BAR {panel.bar}", "white"), (f" · {panel.time:.1f} S", "dim")])
        ty = c.paragraph(x, ty + 9, panel.words, w.W, "text") + 3
        c.icon(x, ty - 1, "note", "muted")
        c.paragraph(x + 10, ty, panel.sound, NOTE_W, "muted")
    return c, overlays


def episode(key, *, zones=False):
    board = load(BOARDS / f"{key}.py")
    assert len(board.PANELS) == 8, f"{key} has {len(board.PANELS)} panels, not 8"
    drawn = [draw(p, zones=zones) for p in board.PANELS]
    for panel, (_, _, notes) in zip(board.PANELS, drawn):
        for note in notes:
            print(f"{key} bar {panel.bar}: warning: {note}")
    c, overlays = sheet(key, board, drawn)
    for note in w.check(c, video=False):
        print(f"{key} sheet: warning: {note}")
    paths = [w.save(w.render(c, SHEET, overlays), OUT / f"{key}.png")]
    post = next(p for p in w.POSTS["posts"] if p["episode"] == board.EPISODE["id"] and p["hook"] == "a")
    cover = w.canvas()
    w.opener(cover, round(post["coverMs"] / 1000 * w.FPS), board.EPISODE, board.EPISODE["hooks"]["a"], board.FEATURE)
    paths.append(w.save(cover.img, OUT / f"{key}-hook.png"))
    pc, pov, _ = drawn[5]
    paths.append(w.save(w.render(pc, 1, pov), OUT / f"{key}-result.png"))
    result = board.PANELS[5].draw
    if "progress" in inspect.signature(result).parameters:
        pc, pov, _ = draw(board.PANELS[5], progress=0.5)
        paths.append(w.save(w.render(pc, 1, pov), OUT / f"{key}-reveal.png"))
    for path in paths:
        print(f"wrote {path.relative_to(w.VIDEO)}")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--episode", help="an episode, such as e01")
    group.add_argument("--all", action="store_true", help="every episode with a board")
    parser.add_argument("--zones", action="store_true", help="outline the covered zones on each panel")
    args = parser.parse_args()
    keys = sorted(p.stem for p in BOARDS.glob("e*.py") if "-" not in p.stem) if args.all else [args.episode.lower()]
    for key in keys:
        episode(key, zones=args.zones)


if __name__ == "__main__":
    main()
