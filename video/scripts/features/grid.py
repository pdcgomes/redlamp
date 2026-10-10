#!/usr/bin/env python3
"""
The test frames that settled the feature videos' grid: the same frame drawn on 216 × 384 at ×5 and on
180 × 320 at ×6, with the zones TikTok and Instagram cover hatched and outlined. Each carries the
header, the widest two-line hook in posts.json and the editor, so what fits shows at a glance.

    python3 scripts/features/grid.py      # out/features/grid/216x384.png, 180x320.png and both.png
"""

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from features import world as w  # noqa: E402

OUT = w.VIDEO / "out/features/grid"
PHOTO = w.crop("docs/images/before-after.png", (176, 275, 873, 709))
HOOK = ["BRING YOUR", "LIGHTROOM PRESETS"]


def frame(gw, gh, scale):
    c = w.canvas(gw, gh, scale)
    zones = w.covered(gw, gh, scale)
    top = zones[0][0].y2
    bottom = zones[1][0].y
    side = zones[2][0]
    head = top
    rows = (head + 15, head + 35)
    stage = w.Rect(4, rows[1] + 17, gw - 8, bottom - 1 - (rows[1] + 17))
    w.header(c, "PRESETS", y=head)
    for line, y in zip(HOOK, rows):
        c.text(gw // 2, y, line, "white", font="large", scale=2, align="center")
    panel = 58 if gh == w.H else 50
    ed = w.editor(c, None, panel=panel, window=stage, read_right=side.x)
    c.img.paste(w.pixel_photo(PHOTO, ed.photo.w, ed.photo.h), ed.photo[:2])
    x, pw = ed.panel.x, ed.panel.w
    y = w.panel_title(c, x, ed.panel.y, pw, "BASIC")
    for i, (label, value, frac) in enumerate([("EXPOSURE", "+0.35", 0.535), ("HIGHLIGHTS", "-45", 0.275),
                                              ("SHADOWS", "+40", 0.7), ("VIBRANCE", "+25", 0.625)]):
        w.slider(c, x, y + i * 10, pw, label, value, frac, active=i == 0)
    for zone, name in zones:
        c.pattern(*zone, "#7a2a5a", kind="diagonal")
        c.box(*zone, "#c04a8a")
    warnings = w.check(c)
    for note in warnings:
        print(f"{gw}x{gh}: warning: {note}")
    widest = max(c.measure(s, "large", 2) for s in HOOK)
    print(f"{gw}x{gh} at x{scale}: widest hook line {widest} px of {gw}; stage {stage.h} rows; "
          f"photo {ed.photo.w}x{ed.photo.h} ({ed.photo.w * scale}x{ed.photo.h * scale} px)")
    return c.img.resize((gw * scale, gh * scale), Image.NEAREST)


def main():
    a = frame(216, 384, 5)
    b = frame(180, 320, 6)
    w.save(a, OUT / "216x384.png")
    w.save(b, OUT / "180x320.png")
    both = Image.new("RGB", (a.width + b.width + 40, a.height), (30, 30, 30))
    both.paste(a, (0, 0))
    both.paste(b, (a.width + 40, 0))
    w.save(both.resize((both.width // 2, both.height // 2), Image.NEAREST), OUT / "both.png")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
