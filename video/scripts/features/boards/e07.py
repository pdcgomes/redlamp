"""
E07, Speed: a slider change rendering in 1.8 ms and a 24 MP raw opening in 0.16 s, on an M1 Ultra.
The editor shows the time of each render under the photo, as the app's canvas toolbar does; Exposure
is dragged up and back down, a 24 MP raw opens from the filmstrip, and the two figures are shown
with where they were measured; then the real photo, edited in Redlamp, and the end card.

The figures are the README's performance card (docs/images/performance-card.svg, from
docs/performance/history.jsonl, 29 Sep to 10 Oct 2026): 1.8 ms to render a slider change and 160 ms
to open a 24 MP raw, on an Apple M1 Ultra with a Release build.

The photos stand in until the owner's renders arrive. The dancer is DSC04439.ARW, from a Sony α7R V,
as the app shows it in docs/images/hero.png at Exposure +0.75, Contrast +29 and Highlights +37,
cropped to the photo above the canvas's toolbar; the pixel photo at the drag's other values is that
render brightened or darkened in linear light by the difference. docs/images/hero-slider.png has it at
+0.85, the next render, but its slider covers the top of the photo. The raw that opens is DSC_0750.NEF,
from a Nikon Z 6 (24 MP), at its edit (Exposure +0.35, Highlights -45), from docs/images/before-after.png.
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e07")
FEATURE = "SPEED"
PHOTO = ("DSC04439.ARW (SONY ILCE-7RM5) AT EXPOSURE +0.75, DOCS/IMAGES/HERO.PNG (+0.85 IN HERO-SLIDER.PNG); "
         "DSC_0750.NEF (NIKON Z 6, 24 MP), DOCS/IMAGES/BEFORE-AFTER.PNG")
DANCER = w.crop("docs/images/hero.png", (686, 78, 1627, 1405))
RAW = w.crop("docs/images/before-after.png", (880, 275, 1577, 709))
PANEL, STRIP = 50, 16
RENDER, OPEN = "RENDER 1.8 MS", "OPEN 0.16 S"

# Each photo's file, its picture, the Exposure it was rendered at, and the edit's sliders: name, the
# slider's reach either side of zero, the value.
PHOTOS = {
    "dancer": ("DSC04439.ARW", DANCER, 0.75, [("EXPOSURE", 5, 0.75), ("CONTRAST", 100, 29), ("HIGHLIGHTS", 100, 37)]),
    "raw": ("DSC_0750.NEF", RAW, 0.35, [("EXPOSURE", 5, 0.35), ("CONTRAST", 100, 0), ("HIGHLIGHTS", 100, -45)]),
}
THUMBS = [
    ("docs/images/hero.png", (686, 78, 1627, 1405)),
    ("docs/images/before-after.png", (880, 275, 1577, 709)),
    ("docs/images/recipes.png", (300, 150, 1400, 800)),
    ("docs/images/black-and-white.png", (300, 150, 1400, 800)),
    ("docs/images/color-grading.png", (300, 150, 1400, 800)),
    ("docs/images/proraw.png", (650, 250, 1150, 700)),
    ("docs/images/film-editor.png", (300, 150, 1400, 800)),
    ("docs/images/detail.png", (300, 150, 1400, 800)),
]

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


def edit(c, key="dancer", *, exposure=None, active=None, press=None, readout_text=RENDER, sliders=True):
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
    small = cached(("thumbs",), lambda: [w.pixel_photo(w.crop(p, b), 18, 12) for p, b in THUMBS])
    cells = w.filmstrip(c, ed.strip, small, selected=shown)
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


def result(c, progress=1.0):
    ed = edit(c, active="EXPOSURE")
    return w.result_frame(c, ed, DANCER, progress=progress)


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
