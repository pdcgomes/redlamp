"""
E05, Presets and LUTs: Lightroom develop presets dropped on the Recipes panel, the report of what came
across exactly, approximately or not at all, a .cube LUT dropped the same way, then a click on an
imported preset; then the real photo with it, and the end card.

The photo is the owner's two girls on a scooter (DSC03201 (2).jpg in ~/src/redlamp-social/photos), his
finished JPEG. The editor shows it cropped to the girls and the scooter; the preset's look in bar 5 is
drawn, a warmer, firmer pixel photo, since the owner's preset hasn't arrived. The result is the photo
as it is, labelled BEFORE, in Redlamp's before and after view, beside the frame Redlamp's render with
the preset goes in. The preset and LUT names stand in for his. The report's rows are real Camera Raw
settings and the outcome docs/recipes/lightroom-presets.md gives each: Exposure, Contrast and
Highlights map one to one, a Color Priority vignette style renders as Highlight Priority, and a
profile isn't converted.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e05")
FEATURE = "PRESETS AND LUTS"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC03201 (2).jpg"
PHOTO = ("DSC03201 (2).JPG, THE OWNER'S TWO GIRLS ON A SCOOTER, IN EVERY PANEL: BARS 1 TO 5 IN PIXEL ART, "
         "CROPPED TO THE GIRLS (THE PRESET'S LOOK IN BAR 5 IS DRAWN), AND BAR 6 THE WHOLE JPEG UNTOUCHED, AS "
         "BEFORE. TO COME FROM REDLAMP: THE PHOTO WITH THE OWNER'S .XMP PRESET, FOR AFTER. THE PRESET AND "
         "LUT NAMES STAND IN FOR HIS")
FILE = "DSC03201 (2).JPG"
REAL = w.crop(SOURCE)
BEFORE = w.crop(SOURCE, (180, 620, 1080, 1820))
ASPECT = BEFORE.width / BEFORE.height
PANEL = 70

PRESETS = ["PARADE.XMP", "AUTUMN.XMP", "HARBOUR.XMP"]
LUT = "SLATE.CUBE"
# The import report for PARADE.XMP: each setting and how it came across.
REPORT = [
    ("EXPOSURE", "EXACT"),
    ("CONTRAST", "EXACT"),
    ("HIGHLIGHTS", "EXACT"),
    ("VIGNETTE STYLE", "APPROXIMATE"),
    ("PROFILE", "NOT AT ALL"),
]
OUTCOME = {"EXACT": "green.light", "APPROXIMATE": "yellow.light", "NOT AT ALL": w.GREY["fill"]}

_photos = {}


def drawn_look(img):
    """A stand-in for the preset in the pixel photo only: warmer, a little firmer and richer."""
    a = np.asarray(img, np.float64) / 255
    a = a * [1.06, 1.0, 0.88] + [0.02, 0.0, -0.01]
    a = np.clip(a, 0, 1)
    a = a + 0.35 * (a - 0.5) * (1 - np.abs(2 * a - 1))
    y = a @ [0.2126, 0.7152, 0.0722]
    a = y[..., None] + (a - y[..., None]) * 1.25
    return Image.fromarray(np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8))


def photos(size):
    """The pixel photo before and after the preset."""
    if size not in _photos:
        _photos[size] = [w.pixel_photo(img, *size) for img in (BEFORE, drawn_look(BEFORE))]
    return _photos[size]


def recipes(c, p, imported=(), *, selected=None, drop=False):
    """The Recipes panel: the Imported group, open with what has been imported, and the bundled groups
    under it. `selected` names the highlighted item; `drop` marks the panel as a drop target."""
    y = w.panel_title(c, p.x, p.y, p.w, "RECIPES")
    entries = [("IMPORTED", str(len(imported)) if imported else "", True)]
    entries += [(name.rsplit(".", 1)[0], name.rsplit(".", 1)[1], False) for name in imported]
    entries += [(g, "", True) for g in ("ESSENTIALS", "PORTRAIT", "LANDSCAPE", "STREET")]
    rows = {}
    for i, (name, note, group) in enumerate(entries[:5]):
        ry = y + i * 9
        on = name == selected or (drop and i == 0)
        if on:
            c.rect(p.x - 2, ry - 2, p.w + 4, 9, w.GREY["raised"])
        tx = p.x + 12
        if group:
            c.icon(p.x, ry - 1, "folder", w.GREY["value"] if on else w.GREY["fill"])
        else:
            tx += 10
        c.text(tx, ry, name, w.GREY["value"] if on else w.GREY["label"])
        if note:
            c.text(p.x + p.w, ry, note, w.GREY["dim"], align="right")
        rows[name] = w.Rect(tx, ry, c.measure(name), 5)
    if drop:
        c.box(p.x - 4, p.y - 3, p.w + 7, p.h + 2, w.ACCENT)
    return rows


def edit(c, *, after=False, imported=(), selected=None, drop=False):
    w.header(c, FEATURE)
    size = w.layout(panel=PANEL, aspect=ASPECT).photo[2:]
    ed = w.editor(c, photos(size)[after], file=FILE, panel=PANEL, aspect=ASPECT)
    return ed, recipes(c, ed.panel, imported, selected=selected, drop=drop)


def files_window(c, ed, title, names, *, mark=None):
    """The Finder window, on the canvas left of the photo."""
    cv = ed.canvas
    rect = w.Rect(cv.x + 3, cv.y + 4, ed.photo.x - cv.x - 6, 13 + 10 * len(names))
    w.finder(c, rect, title, names, mark=mark)


def hook(c):
    ed, _ = edit(c)
    files_window(c, ed, "PRESETS", PRESETS)
    w.caption(c, EPISODE["hooks"]["a"])


def drop(c):
    ed, rows = edit(c, drop=True)
    files_window(c, ed, "PRESETS", PRESETS)
    r = rows["IMPORTED"]
    px, py = r.x2 + 14, r.y + 2
    w.drag_ghost(c, px, py, len(PRESETS))
    w.pointer(c, px, py)
    w.caption(c, ["DROP IN .XMP", "PRESETS"])


def report(c):
    """The import report, as a sheet over the photo: each setting and how it came across."""
    ed, _ = edit(c, imported=PRESETS)
    cv = ed.canvas
    sheet = w.Rect(cv.x + 4, cv.y, w.READ_RIGHT - 2 - (cv.x + 4), 21 + 11 * len(REPORT) + 2)
    c.rect(sheet.x + 1, sheet.y + 1, sheet.w, sheet.h, "shadow")
    c.rect(*sheet, w.GREY["raised"])
    c.box(*sheet, w.GREY["light"])
    c.text(sheet.x + 6, sheet.y + 5, PRESETS[0], w.GREY["value"], font="large")
    c.hline(sheet.x + 1, sheet.y + 16, sheet.w - 2, w.GREY["light"])
    for i, (name, outcome) in enumerate(REPORT):
        ry = sheet.y + 21 + i * 11
        c.text(sheet.x + 6, ry, name, w.GREY["label"], font="large")
        c.text(sheet.x2 - 6, ry, outcome, OUTCOME[outcome], font="large", align="right")
    c.claim(sheet, "report")
    w.caption(c, ["IT SHOWS WHAT", "CAME ACROSS"])


def lut(c):
    ed, rows = edit(c, imported=[*PRESETS, LUT], selected="SLATE")
    files_window(c, ed, "LUTS", [LUT], mark=0)
    r = rows["SLATE"]
    w.pointer(c, r.x2 + 6, r.y + 2)
    w.caption(c, [".CUBE AND .3DL", "LUTS TOO"])


def apply(c):
    _, rows = edit(c, after=True, imported=[*PRESETS, LUT], selected="PARADE")
    r = rows["PARADE"]
    w.pointer(c, r.x2 + 10, r.y + 2, pressed=True)
    w.caption(c, "CLICK TO APPLY")


def result(c, progress=1.0):
    return w.compare(c, FEATURE, FILE, REAL, ["REDLAMP'S", "RENDER", "GOES HERE"], ["WITH PARADE"], progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]),
            "A deep hit on frame 0, then sixteenths under a beat held back."),
    w.Panel(2, 2.4, drop, "DROP IN .XMP / PRESETS", "The motif starts; a soft drop sound on the beat."),
    w.Panel(3, 4.8, report, "IT SHOWS WHAT / CAME ACROSS", "A tick for each row of the report, one a beat."),
    w.Panel(4, 7.2, lut, ".CUBE AND .3DL / LUTS TOO", "A drop sound as the LUT joins the list; the drums come in."),
    w.Panel(5, 9.6, apply, "CLICK TO APPLY", "A click on the beat as the photo changes."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
