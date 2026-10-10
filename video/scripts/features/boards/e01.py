"""
E01, Free: a free raw photo editor for Mac. The editor opens a raw at its defaults; three slider steps,
one a bar, take it to the edit the real photo has, while the words say what Redlamp costs and where
it runs; backslash shows before and after; then the real photo, edited in Redlamp, and the end card.

The photo is DSC_0750.NEF, from a Nikon Z 6, in Redlamp's before and after view (docs/images/
before-after.png), cropped below the view's Before and After labels. Its edit is Exposure +0.35,
Highlights -45, Shadows +40, Clarity +10, Dehaze +15, Vibrance +25 and Vignette -20 (the capture's
History), and the sliders on screen are its main ones, at those values.
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e01")
FEATURE = "FREE"
SOURCE = "docs/images/before-after.png"
PHOTO = "DSC_0750.NEF (NIKON Z 6) IN REDLAMP'S BEFORE AND AFTER VIEW, DOCS/IMAGES/BEFORE-AFTER.PNG"
BEFORE = w.crop(SOURCE, (176, 275, 873, 709))
AFTER = w.crop(SOURCE, (880, 275, 1577, 709))
PANEL = 58

# The Basic panel's sliders this edit moves: name, the slider's reach either side of zero, the value.
SLIDERS = [("EXPOSURE", 5, 0.35), ("HIGHLIGHTS", 100, -45), ("SHADOWS", 100, 40), ("VIBRANCE", 100, 25)]
# How many of them are set after each step, from the raw as opened to the finished edit.
SET = [0, 1, 3, 4]

_photos = {}


def photos(size):
    """The pixel photo after each step: as opened, after Exposure, after Highlights and Shadows (the
    before's colours at the edit's brightness), and the edit itself."""
    if size not in _photos:
        b = np.asarray(w.fit(BEFORE, *size, Image.BOX), dtype=np.float64) / 255
        a = np.asarray(w.fit(AFTER, *size, Image.BOX), dtype=np.float64) / 255
        lin = np.where(b <= 0.04045, b / 12.92, ((b + 0.055) / 1.055) ** 2.4)
        lin_a = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
        yb = lin @ [0.2126, 0.7152, 0.0722] + 1e-4
        ya = lin_a @ [0.2126, 0.7152, 0.0722] + 1e-4

        def at(y):
            v = np.clip(lin * (y / yb)[..., None], 0, 1)
            v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
            return Image.fromarray(np.rint(v * 255).astype(np.uint8))

        steps = [BEFORE, at(yb ** 0.4 * ya ** 0.6), at(ya), AFTER]
        _photos[size] = [w.pixel_photo(img, *size) for img in steps]
    return _photos[size]


def value(reach, v):
    if v == 0:
        return "0.00" if reach < 10 else "0"
    return f"{v:+.2f}" if reach < 10 else f"{v:+.0f}"


def edit(c, step, *, shown=None, active=None, press=None, mark=None, sliders=True):
    """The editor at a step of the edit, showing the pixel photo of step `shown` (the same by default),
    with `active` highlighted and the pointer pressed on `press`. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(panel=PANEL).photo[2:]
    ed = w.editor(c, photos(size)[step if shown is None else shown], panel=PANEL)
    if mark:
        w.tag(c, ed.photo, mark)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASIC")
    knobs = {}
    for i, (name, reach, target) in enumerate(SLIDERS if sliders else []):
        v = target if i < SET[step] else 0
        knobs[name] = w.slider(c, p.x, y + i * 10, p.w, name, value(reach, v), 0.5 + v / (2 * reach),
                               active=name == active)
    if press:
        w.pointer(c, *knobs[press], pressed=True)
    return ed


def hook(c):
    edit(c, 0)
    w.caption(c, EPISODE["hooks"]["a"])


def exposure(c):
    edit(c, 1, active="EXPOSURE", press="EXPOSURE")
    w.caption(c, "NO SUBSCRIPTION")


def tone(c):
    edit(c, 2, active="SHADOWS", press="SHADOWS")
    w.caption(c, "NO CLOUD")


def vibrance(c):
    edit(c, 3, active="VIBRANCE", press="VIBRANCE")
    w.caption(c, "OPEN SOURCE")


def before_after(c):
    """Backslash held down: the photo as it was opened, and the key shown over the sliders."""
    ed = edit(c, 3, shown=0, mark="BEFORE", sliders=False)
    label = "BEFORE / AFTER"
    p = ed.panel
    box = w.Rect(p.x - 3, p.y + 9, p.w + 3, 43)
    c.rect(*box, w.GREY["chrome"])
    c.box(*box, w.GREY["light"])
    width = 25 + 6 + c.measure(label, "large")
    w.keycap(c, box.cx - width // 2, box.y + 9, "\\", label, pressed=True, size=25, scale=2)
    w.caption(c, ["FAMILIAR LAYOUT", "AND SHORTCUTS"])


def result(c, progress=1.0):
    ed = edit(c, 3)
    return w.result_frame(c, ed, AFTER, mark="AFTER", progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]),
            "A soft chord and a gentle hit on frame 0; the theme's intro."),
    w.Panel(2, 2.4, exposure, "NO SUBSCRIPTION", "The motif starts; a slider tick on the beat."),
    w.Panel(3, 4.8, tone, "NO CLOUD", "The motif; ticks on the beats."),
    w.Panel(4, 7.2, vibrance, "OPEN SOURCE", "The motif's answer; the drums come in."),
    w.Panel(5, 9.6, before_after, "FAMILIAR LAYOUT / AND SHORTCUTS", "A key click on the beat."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
