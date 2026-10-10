"""
E07, Speed: a slider change rendering in 1.8 ms and a 24 MP raw opening in 0.16 s, on an M1 Ultra.
The editor shows the time of each render under the photo, as the app's canvas toolbar does; Exposure
is dragged up and back down, a 24 MP raw opens from the filmstrip, and the two figures are shown
with where they were measured; then the real photo, edited in Redlamp, and the end card.

The figures are the README's performance card (docs/images/performance-card.svg, from
docs/performance/history.jsonl, 29 Sep to 10 Oct 2026): 1.8 ms to render a slider change and 160 ms
to open a 24 MP raw, on an Apple M1 Ultra with a Release build.

The photo dragged is the owner's shopkeeper among her jars (DSC01584 (2).jpg in
~/src/redlamp-social/photos), his finished JPEG, cropped in the editor to her and the shelves. Its
sliders start at zero, since the JPEG is the starting point, and the pixel photo at the drag's values
is it brightened or darkened in linear light, a drawing of what the renders will show. The raw that
opens is still DSC_0750.NEF, from a Nikon Z 6 (24 MP), at its edit (Exposure +0.35, Highlights -45),
from docs/images/before-after.png: the owner's α7R V raws are 61 MP, so the 24 MP figure needs a 24 MP
raw. The result is the shopkeeper as she is, labelled BEFORE, in Redlamp's before and after view, beside
the frame Redlamp's renders at each Exposure go in.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e07")
FEATURE = "SPEED"
SHOOT = Path.home() / "src/redlamp-social/photos"
SOURCE = SHOOT / "DSC01584 (2).jpg"
PHOTO = ("DSC01584 (2).JPG, THE OWNER'S SHOPKEEPER, IN BARS 1 TO 3 IN PIXEL ART (THE EXPOSURE DRAG IS DRAWN) "
         "AND IN BAR 6 UNTOUCHED, AS BEFORE. THE 24 MP RAW OPENED IN BARS 4 AND 5 IS DSC_0750.NEF (NIKON Z 6) "
         "FROM DOCS/IMAGES/BEFORE-AFTER.PNG, UNTIL ONE OF HIS. TO COME FROM REDLAMP: THE SHOPKEEPER RENDERED AT "
         "EACH EXPOSURE OF THE DRAG, ONE A BEAT, FOR BAR 6")
REAL = w.crop(SOURCE)
SHOP = w.crop(SOURCE, (100, 280, 1300, 1780))
RAW = w.crop("docs/images/before-after.png", (880, 275, 1577, 709))
PANEL, STRIP = 50, 18
RENDER, OPEN = "RENDER 1.8 MS", "OPEN 0.16 S"

# Each photo's file, its picture, the Exposure it was rendered at, and the edit's sliders: name, the
# slider's reach either side of zero, the value.
PHOTOS = {
    "shop": ("DSC01584 (2).JPG", SHOP, 0.0, [("EXPOSURE", 5, 0.0), ("CONTRAST", 100, 0), ("HIGHLIGHTS", 100, 0)]),
    "raw": ("DSC_0750.NEF", RAW, 0.35, [("EXPOSURE", 5, 0.35), ("CONTRAST", 100, 0), ("HIGHLIGHTS", 100, -45)]),
}
# The filmstrip: the shopkeeper, the raw, then the rest of the owner's photos.
THUMBS = [SOURCE, "docs/images/before-after.png"] + sorted(
    p for p in SHOOT.glob("*.jpg") if p != SOURCE)
THUMB = (round((STRIP - 4) * 2 / 3), STRIP - 4)

_cache = {}


def cached(key, make):
    if key not in _cache:
        _cache[key] = make()
    return _cache[key]


def exposed(img, stops):
    """`img` brightened by `stops` in linear light, as a change of Exposure moves it."""
    v = np.asarray(img, dtype=np.float64) / 255
    lin = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4) * 2.0 ** stops
    v = np.clip(lin, 0, 1)
    v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.rint(v * 255).astype(np.uint8))


def value(reach, v):
    if v == 0:
        return "0.00" if reach < 10 else "0"
    return f"{v:+.2f}" if reach < 10 else f"{v:+.0f}"


def readout(c, cx, y, text):
    """A measured figure in the large font, centred on cx, as the canvas toolbar shows a render's time."""
    tw = c.measure(text, "large")
    r = w.Rect(cx - (tw + 12) // 2, y, tw + 12, 15)
    c.rect(r.x + 1, r.y + 1, r.w, r.h, "shadow")
    c.rect(*r, w.GREY["raised"])
    c.box(*r, w.GREY["light"])
    c.text(r.x + 6, r.y + 4, text, w.GREY["value"], font="large")
    c.claim(r, "readout")
    return r


def edit(c, key="shop", *, exposure=None, active=None, press=None, readout_text=RENDER, sliders=True):
    """The editor with `key`'s photo open at `exposure` (its own by default), the Basic sliders, and the
    render time under the photo. `press` is "EXPOSURE" or a thumbnail's index. Returns the editor."""
    file, img, own, edit_sliders = PHOTOS[key]
    ev = own if exposure is None else exposure
    w.header(c, FEATURE)
    aspect = img.width / img.height
    size = w.layout(panel=PANEL, strip=STRIP, aspect=aspect).photo[2:]
    pixel = cached((key, ev, size), lambda: w.pixel_photo(exposed(img, ev - own) if ev != own else img, *size))
    ed = w.editor(c, pixel, file=file, panel=PANEL, strip=STRIP, aspect=aspect)
    shown = list(PHOTOS).index(key)
    small = cached(("thumbs",), lambda: [w.pixel_photo(RAW if i == 1 else p, *THUMB) for i, p in enumerate(THUMBS)])
    cells = w.filmstrip(c, ed.strip, small, selected=shown, cell=THUMB[0])
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASIC")
    knobs = {}
    for i, (name, reach, v) in enumerate(edit_sliders if sliders else []):
        v = ev if name == "EXPOSURE" else v
        knobs[name] = w.slider(c, p.x, y + i * 10, p.w, name, value(reach, v), 0.5 + v / (2 * reach),
                               active=name == active)
    if readout_text:
        readout(c, ed.canvas.cx, ed.canvas.y2 - 18, readout_text)
    if isinstance(press, int):
        r = cells[press]
        w.pointer(c, r.cx, r.cy, pressed=True)
    elif press:
        w.pointer(c, *knobs[press], pressed=True)
    return ed


def hook(c):
    edit(c)
    w.caption(c, EPISODE["hooks"]["a"])


def up(c):
    edit(c, exposure=1.0, active="EXPOSURE", press="EXPOSURE")
    w.caption(c, "DRAG A SLIDER")


def down(c):
    edit(c, exposure=-0.5, active="EXPOSURE", press="EXPOSURE")
    w.caption(c, "1.8 MS PER CHANGE")


def open_raw(c):
    edit(c, "raw", press=1, readout_text=OPEN)
    w.caption(c, ["A 24 MP RAW OPENS", "IN 0.16 S"])


def measured(c):
    """Both figures over the sliders, with the Mac and the build they were measured on."""
    ed = edit(c, "raw", readout_text=None, sliders=False)
    p = ed.panel
    box = w.Rect(p.x - 3, p.y + 9, p.w + 3, 34)
    c.rect(*box, w.GREY["chrome"])
    c.box(*box, w.GREY["light"])
    for i, (name, figure) in enumerate((("RENDER", "1.8 MS"), ("OPEN", "0.16 S"))):
        ry = box.y + 4 + i * 11
        c.text(box.x + 6, ry, name, w.GREY["label"], font="large")
        c.text(box.x2 - 6, ry, figure, w.GREY["value"], font="large", align="right")
    c.text(box.x + 6, box.y + 26, "APPLE M1 ULTRA · RELEASE BUILD", w.GREY["dim"])
    w.caption(c, ["MEASURED ON", "AN M1 ULTRA"])


def placeholder(c, frame, lines, note=()):
    """The frame a Redlamp render goes in until it arrives: dashed, with what's to come in it."""
    c.rect(*frame, w.GREY["well"])
    for x0, y0, length, vertical in ((frame.x, frame.y, frame.w, False), (frame.x, frame.y2 - 1, frame.w, False),
                                     (frame.x, frame.y, frame.h, True), (frame.x2 - 1, frame.y, frame.h, True)):
        c.dashes(x0, y0, length, w.GREY["dim"], vertical=vertical)
    top = frame.cy - (8 * (len(lines) + len(note)) + (3 if note else 0)) // 2
    for i, line in enumerate(lines):
        c.text(frame.cx, top + i * 8, line, w.GREY["value"], align="center")
    for i, line in enumerate(note):
        c.text(frame.cx, top + 3 + (len(lines) + i) * 8, line, w.GREY["dim"], align="center")


def compare(c, file, real, lines, note=(), *, progress=1.0):
    """Redlamp's before and after view across the stage: the owner's photo as it is, labelled BEFORE,
    and beside it the frame Redlamp's render goes in, labelled AFTER. Returns the overlay that resolves
    the pixel photo into the real one."""
    w.header(c, FEATURE)
    ed = w.editor(c, None, file=file, panel=8)
    pw, ph, gap = 100, 150, 3
    cv = ed.canvas
    before = w.Rect(cv.x + (cv.w - 2 * pw - gap) // 2, cv.y + (cv.h - ph) // 2, pw, ph)
    after = w.Rect(before.x2 + gap, before.y, pw, ph)
    c.img.paste(w.pixel_photo(real, pw, ph), (before.x, before.y))
    pixels = np.asarray(c.img)[before.y:before.y2, before.x:before.x2].copy()
    placeholder(c, after, lines, note)
    w.tag(c, before, "BEFORE")
    w.tag(c, after, "AFTER")
    w.caption(c, w.REAL_PHOTO)
    return [w.Overlay(before, real, pixels, progress)]


def result(c, progress=1.0):
    return compare(c, PHOTOS["shop"][0], REAL, ["REDLAMP'S", "RENDERS", "GO HERE"], ["EXPOSURE", "+1.00 TO -0.50"],
                   progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]),
            "A soft chord and a gentle hit on frame 0; the theme's intro."),
    w.Panel(2, 2.4, up, "DRAG A SLIDER", "The motif starts; a slider tick a beat as Exposure climbs to +1.00."),
    w.Panel(3, 4.8, down, "1.8 MS PER CHANGE", "Ticks on the beats as Exposure comes back to -0.50."),
    w.Panel(4, 7.2, open_raw, "A 24 MP RAW OPENS / IN 0.16 S", "A click on the thumbnail; the drums come in."),
    w.Panel(5, 9.6, measured, "MEASURED ON / AN M1 ULTRA", "The motif's answer."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass, then a tick a beat as each render shows."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
