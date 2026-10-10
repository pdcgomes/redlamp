#!/usr/bin/env python3
"""
Every part in world.py on four frames, for whoever draws the next board: the Masks panel's buttons
and the red overlay, a text field and a list, a filmstrip, the banner and a file list, and keycaps.
The photo is E01's, standing in for each episode's own.

    python3 scripts/features/specimen.py      # out/features/specimen.png, at twice the grid's size
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from features import world as w  # noqa: E402

PHOTO = w.crop("docs/images/before-after.png", (176, 275, 873, 709))


def masks(c):
    w.header(c, "SKY MASK")
    w.caption(c, ["CLICK SKY"])
    size = w.layout().photo[2:]
    ed = w.editor(c, w.pixel_photo(PHOTO, *size))
    w.mask_overlay(c, ed.photo, np.arange(ed.photo.h)[:, None] < ed.photo.h * 0.4 + np.zeros(ed.photo.w))
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "MASKS")
    x = p.x
    sky = None
    for label in ("SUBJECT", "SKY", "BACKGROUND", "PEOPLE"):
        r = w.button(c, x, y, label, pressed=label == "SKY")
        sky = r if label == "SKY" else sky
        x = r.x2 + 3
    w.slider(c, p.x, y + 16, p.w, "EXPOSURE", "-0.80", 0.42, active=True)
    w.pointer(c, sky.x2 - 2, sky.y2 - 2, pressed=True)


def search(c):
    w.header(c, "REMOVE")
    w.caption(c, ["TYPE WHAT TO", "REMOVE"])
    size = w.layout(panel=70).photo[2:]
    ed = w.editor(c, w.pixel_photo(PHOTO, *size), panel=70)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "REMOVE", right="ON THIS MAC")
    w.field(c, p.x, y, p.w, "POWER LINES", focused=True)
    w.rows(c, p.x + 2, y + 16, p.w - 4, ["STREET", "LANDSCAPE", "PORTRAIT"], selected=0, icon="folder",
           right=["13", "40", "7"])


def stack(c):
    w.header(c, "FOCUS STACKING")
    w.caption(c, ["IT FINDS THE", "STACK FOR YOU"])
    size = w.layout(panel=40, strip=18).photo[2:]
    ed = w.editor(c, w.pixel_photo(PHOTO, *size), panel=40, strip=18)
    ph = ed.photo
    w.banner(c, ph.x + 2, ph.y + 2, ph.w - 4, ["FOCUS STACK DETECTED", "25 FRAMES"], action="MERGE")
    thumb = w.pixel_photo(PHOTO, 21, 14)
    w.filmstrip(c, ed.strip, [thumb] * 8, selected=2)
    p = ed.panel
    w.files(c, p.x + 1, p.y + 3, p.w - 2, ["IMG_1234.ARW", "IMG_1234.ARW.REDLAMP"], badges=["UNCHANGED", "NEW"],
            mark=1)


def keys(c):
    w.header(c, "SHORTCUTS")
    w.caption(c, ["SAME SHORTCUTS", "AS LIGHTROOM"])
    size = w.layout(panel=90).photo[2:]
    ed = w.editor(c, w.pixel_photo(PHOTO, *size), panel=90)
    p = ed.panel
    for i, (key, label) in enumerate([("R", "CROP"), ("K", "BRUSH"), ("\\", "BEFORE / AFTER"), ("V", "BLACK & WHITE")]):
        w.keycap(c, p.x + 2, p.y + 2 + i * 21, key, label, pressed=i == 2)


def main():
    frames = []
    for draw in (masks, search, stack, keys):
        c = w.canvas()
        draw(c)
        for note in w.check(c):
            print(f"{draw.__name__}: warning: {note}")
        frames.append(w.render(c, 2))
    sheet = Image.new("RGB", (len(frames) * (w.W * 2 + 16) - 16, w.H * 2), (40, 40, 40))
    for i, f in enumerate(frames):
        sheet.paste(f, (i * (w.W * 2 + 16), 0))
    print(f"wrote {w.save(sheet, w.VIDEO / 'out/features/specimen.png').relative_to(w.VIDEO)}")


if __name__ == "__main__":
    main()
