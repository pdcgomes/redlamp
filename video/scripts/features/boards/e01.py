"""
E01, Free: a free raw photo editor for Mac. The editor opens a raw at its defaults; three slider steps,
one a bar, take it to the edit the real photo has, while the words say what Redlamp costs and where
it runs; backslash shows before and after; then the real photo, edited in Redlamp, and the end card.

The photo is the owner's cosplayer with orange hair (DSC02372.jpg, in ~/src/redlamp-social/photos),
cropped to 4:5 about him, so the portrait fills the editor's canvas. His JPEG is his finished photo
and stands in for Redlamp's render of the edit; it is shown as it is. The pixel photo before the edit
is a drawing of it at a raw's defaults (flatter, darker, less colour), and each step draws it nearer
the finished photo. The before in the result is Redlamp's render of the raw at its defaults, still to
come, so the result shows a placeholder for it beside his photo. The sliders' values stand in until
his edit's are read from its sidecar.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e01")
FEATURE = "FREE"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC02372.jpg"
PHOTO = ("THE OWNER'S DSC02372.JPG (THE COSPLAYER), CROPPED TO 4:5, IN EVERY EDITOR PANEL AND AS THE AFTER IN BAR 6, "
         "STANDING IN FOR REDLAMP'S RENDER. THE PIXEL PHOTO BEFORE THE EDIT IS A DRAWING. TO COME FROM REDLAMP: "
         "THE BEFORE IN BAR 6 (THE RAW AT ITS DEFAULTS) AND THE EDIT'S SLIDER VALUES, WHICH STAND IN UNTIL THEN")
FILE = "DSC02372.ARW"
# A 4:5 crop about the subject, in the photo's own pixels, leaving out most of the shoulder at the left.
BOX = (230, 270, 1330, 1645)
AFTER = Image.open(SOURCE).convert("RGB").crop(BOX)
ASPECT = 4 / 5
PANEL = 58

# The Basic panel's sliders this edit moves: name, the slider's reach either side of zero, the value.
SLIDERS = [("EXPOSURE", 5, 0.35), ("HIGHLIGHTS", 100, -45), ("SHADOWS", 100, 40), ("VIBRANCE", 100, 25)]
# How many of them are set after each step, from the raw as opened to the finished edit.
SET = [0, 1, 3, 4]


def drawn(img, *, ev=0.0, contrast=1.0, colour=1.0):
    """`img` redrawn nearer a raw at its defaults: `ev` stops of exposure, contrast about the middle
    grey and colour toward grey, for the pixel photo only."""
    a = np.asarray(img, dtype=np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** ev
    v = np.clip(lin, 0, 1)
    v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
    v = 0.46 + (v - 0.46) * contrast
    grey = v @ [0.2126, 0.7152, 0.0722]
    v = grey[..., None] + (v - grey[..., None]) * colour
    return Image.fromarray(np.rint(np.clip(v, 0, 1) * 255).astype(np.uint8))


# The pixel photo after each step: as opened, after Exposure, after Highlights and Shadows, the edit.
STEPS = [
    drawn(AFTER, ev=-0.4, contrast=0.75, colour=0.65),
    drawn(AFTER, ev=0.0, contrast=0.77, colour=0.68),
    drawn(AFTER, ev=0.0, contrast=0.92, colour=0.75),
    AFTER,
]


def photo_palette(images, colors=40):
    """A palette taken from the photos themselves, with the editor's greys, so skin, the orange hair and
    the jacket's red keep their own colours in the pixel photo."""
    tiles = [img.resize((96, 120), Image.BOX) for img in images]
    sheet = Image.new("RGB", (96 * len(tiles), 120))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (96 * i, 0))
    flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[:3 * colors]
    found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    return list(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))


PALETTE = photo_palette(STEPS)

_photos = {}


def pixel(step, size):
    if (step, size) not in _photos:
        src = w.fit(STEPS[step], *size, Image.BOX)
        _photos[step, size] = w.lock(src, PALETTE, dither=0.4).convert("RGB")
    return _photos[step, size]


def value(reach, v):
    if v == 0:
        return "0.00" if reach < 10 else "0"
    return f"{v:+.2f}" if reach < 10 else f"{v:+.0f}"


def edit(c, step, *, shown=None, active=None, press=None, mark=None, sliders=True, photo=True):
    """The editor at a step of the edit, showing the pixel photo of step `shown` (the same by default),
    with `active` highlighted and the pointer pressed on `press`. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(step if shown is None else shown, size) if photo else None, file=FILE,
                  aspect=ASPECT, panel=PANEL)
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


def placeholder(c, r, lines, mark):
    """An empty frame where a render still to come from Redlamp goes: dashed, with what goes there."""
    c.rect(*r, w.GREY["well"])
    for y in (r.y, r.y2 - 1):
        c.dashes(r.x, y, r.w, w.GREY["light"])
    for x in (r.x, r.x2 - 1):
        c.dashes(x, r.y, r.h, w.GREY["light"], vertical=True)
    top = r.cy - (7 * len(lines) - 2) // 2
    for i, line in enumerate(lines):
        c.text(r.cx, top + 7 * i, line, w.GREY["label"] if i == 0 else w.GREY["dim"], align="center")
    w.tag(c, r, mark)


def pair(ed):
    """Two frames the photo's size side by side on the canvas, centred left of the side buttons."""
    ph, gap = ed.photo, 4
    x = ed.canvas.x + (w.READ_RIGHT - ed.canvas.x - (2 * ph.w + gap)) // 2
    return w.Rect(x, ph.y, ph.w, ph.h), w.Rect(x + ph.w + gap, ph.y, ph.w, ph.h)


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
    """The before and after side by side: Redlamp's render of the raw at its defaults still to come at
    the left, and the owner's finished photo, resolving out of the pixel one, at the right."""
    ed = edit(c, 3, photo=False)
    before, after = pair(ed)
    placeholder(c, before, ["REDLAMP'S", "RENDER OF", "THE RAW", "GOES HERE"], "BEFORE")
    c.img.paste(pixel(3, (after.w, after.h)), (after.x, after.y))
    pixels = np.asarray(c.img)[after.y:after.y2, after.x:after.x2].copy()
    w.tag(c, after, "AFTER")
    w.caption(c, w.REAL_PHOTO)
    return [w.Overlay(after, AFTER, pixels, progress)]


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
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO) + "; before, then after at 13.2 s",
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
