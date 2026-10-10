"""
E03, Film looks: looks of 30 real film stocks, built from each film's datasheet. The editor opens a
photo with the Base Look list showing five film names; Portra 400's characteristic curve, from Kodak's
datasheet, draws itself on a chart; then the photo in Portra 400, Tri-X 400, CineStill 800T, Velvia 50
and HP5 Plus, picked from the list; then the real photo in the five looks, and the end card.

The photo is the owner's street-food cook at the grill (DSC03230 (2).jpg, in ~/src/redlamp-social/
photos), cropped to 4:5 about him and the grill. The looks in the pixel photo are drawings (Portra
warm and soft, Tri-X black and white with more contrast, Velvia richer and deeper), standing in for
Redlamp's looks. The real photo is shown as it is, as the before; Redlamp's renders of it in the five
looks are still to come, so the result shows a placeholder for them. The curve is the green-sensitive
layer of Portra 400's characteristic curves, as research/film-data digitised them from Kodak's
datasheet E-4050.
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e03")
FEATURE = "FILM LOOKS"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC03230 (2).jpg"
PHOTO = ("THE OWNER'S DSC03230 (2).JPG (THE STREET-FOOD COOK), CROPPED TO 4:5, IN EVERY EDITOR PANEL AND AS THE "
         "BEFORE IN BAR 6. THE LOOKS ON THE PIXEL PHOTO ARE DRAWINGS. TO COME FROM REDLAMP: THE PHOTO IN PORTRA 400, "
         "TRI-X 400, CINESTILL 800T, VELVIA 50 AND HP5 PLUS FOR BAR 6. CURVE: RESEARCH/FILM-DATA/KODAK-PORTRA-400.JSON, "
         "FROM KODAK DATASHEET E-4050")
FILE = "DSC03230.ARW"
# A 4:5 crop about the cook and the grill, in the photo's own pixels.
BOX = (40, 200, 1340, 1825)
ORIGINAL = Image.open(SOURCE).convert("RGB").crop(BOX)
ASPECT = 4 / 5
PANEL = 66

# The looks in the order the video picks them.
NAMES = ["PORTRA 400", "TRI-X 400", "CINESTILL 800T", "VELVIA 50", "HP5 PLUS"]

CURVES = json.loads((w.REPO / "research/film-data/kodak-portra-400.json").read_text())["characteristicCurves"]


def drawn(img, *, contrast=1.0, colour=1.0, warmth=0.0, lift=0.0):
    """A drawing of a film look on `img`, for the pixel photo only: contrast about the middle grey,
    colour toward grey (0 is black and white), a warm or cool shift and lifted shadows."""
    v = np.asarray(img.resize((img.width // 4, img.height // 4), Image.BOX), dtype=np.float64) / 255
    v = 0.45 + (v - 0.45) * contrast
    grey = v @ [0.2126, 0.7152, 0.0722]
    v = grey[..., None] + (v - grey[..., None]) * colour
    v = v + np.array([1.0, 0.25, -0.8]) * warmth
    v = lift + v * (1 - lift)
    return Image.fromarray(np.rint(np.clip(v, 0, 1) * 255).astype(np.uint8))


LOOKED = {
    "PORTRA 400": drawn(ORIGINAL, contrast=0.92, colour=0.9, warmth=0.025, lift=0.03),
    "TRI-X 400": drawn(ORIGINAL, contrast=1.3, colour=0.0),
    "VELVIA 50": drawn(ORIGINAL, contrast=1.18, colour=1.45),
}


def photo_palette(images, colors=48):
    """A palette taken from the photos themselves, with the editor's greys, so each look keeps its own
    warmth, contrast and colour in the pixel photo."""
    tiles = [img.resize((96, 120), Image.BOX) for img in images]
    sheet = Image.new("RGB", (96 * len(tiles), 120))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (96 * i, 0))
    flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[:3 * colors]
    found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    return list(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))


PALETTE = photo_palette([ORIGINAL, *LOOKED.values()])

_photos = {}


def pixel(name, size):
    """The pixel photo in the look `name`, or the original when it's None."""
    if (name, size) not in _photos:
        src = w.fit(LOOKED[name] if name else ORIGINAL, *size, Image.BOX)
        _photos[name, size] = w.lock(src, PALETTE, dither=0.4).convert("RGB")
    return _photos[name, size]


def edit(c, look=None, *, press=False, show=True):
    """The editor showing the photo in `look` (None for the original), with the Base Look list and the
    look chosen in it, the pointer clicking it when `press`. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(look, size) if show else None, file=FILE, aspect=ASPECT, panel=PANEL)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASE LOOK", right="36 LOOKS")
    i = NAMES.index(look) if look else None
    w.rows(c, p.x + 2, y + 1, p.w - 4, NAMES, selected=i)
    if press and i is not None:
        w.pointer(c, p.x + 2 + c.measure(look) + 10, y + 1 + i * 9 + 3, pressed=True)
    return ed


def placeholder(c, r, lines, mark):
    """An empty frame where renders still to come from Redlamp go: dashed, with what goes there."""
    c.rect(*r, w.GREY["well"])
    for y in (r.y, r.y2 - 1):
        c.dashes(r.x, y, r.w, w.GREY["light"])
    for x in (r.x, r.x2 - 1):
        c.dashes(x, r.y, r.h, w.GREY["light"], vertical=True)
    top = r.cy - (7 * len(lines) - 2) // 2
    for i, line in enumerate(lines):
        c.text(r.cx, top + 7 * i, line, w.GREY["label"] if i < len(NAMES) else w.GREY["dim"], align="center")
    w.tag(c, r, mark)


def pair(ed):
    """Two frames the photo's size side by side on the canvas, centred left of the side buttons."""
    ph, gap = ed.photo, 4
    x = ed.canvas.x + (w.READ_RIGHT - ed.canvas.x - (2 * ph.w + gap)) // 2
    return w.Rect(x, ph.y, ph.w, ph.h), w.Rect(x + ph.w + gap, ph.y, ph.w, ph.h)


def hook(c):
    edit(c)
    w.caption(c, EPISODE["hooks"]["a"])


def datasheet(c, progress=1.0):
    """Portra 400's characteristic curve on a plain chart: how dense the negative gets with more light.
    `progress` is how much of it has drawn."""
    w.header(c, FEATURE)
    w.caption(c, ["BUILT FROM EACH", "FILM'S DATASHEET"])
    box = w.STAGE
    c.claim(box, "datasheet")
    c.rect(box.x + 2, box.y + 2, box.w, box.h, "shadow")
    c.rect(*box, "panel")
    c.box(*box, "line")
    x0 = box.x + 6
    c.text(x0, box.y + 6, "PORTRA 400", "white", font="large")
    c.text(x0, box.y + 17, "CHARACTERISTIC CURVE", "muted")
    plot = w.Rect(x0 + 6, box.y + 40, w.READ_RIGHT - 8 - (x0 + 6), box.h - 40 - 28)
    c.text(x0, plot.y - 9, "DENSITY", "text")
    c.grid(*plot, rows=4, cols=6, color="line")
    c.vline(plot.x, plot.y, plot.h, "dim")
    c.hline(plot.x, plot.y2 - 1, plot.w, "dim")
    green = CURVES["green"]
    lo, hi = 0.0, 3.0
    shown = max(2, round(progress * plot.w))
    xs = c.spark(plot.x + 1, plot.y, shown, plot.h - 1, green[:max(2, round(progress * len(green)))], "white",
                 lo=lo, hi=hi)
    c.rect(plot.x + shown - 1, xs[-1] - 1, 3, 3, "white")
    c.text(plot.x2, plot.y2 + 4, "MORE LIGHT →", "text", align="right")
    c.text(x0, box.y2 - 9, "KODAK DATASHEET E-4050", "dim")


def portra(c):
    edit(c, "PORTRA 400", press=True)
    w.caption(c, "PORTRA 400")


def tri_x(c):
    edit(c, "TRI-X 400", press=True)
    w.caption(c, "TRI-X 400")


def velvia(c):
    edit(c, "VELVIA 50", press=True)
    w.caption(c, "VELVIA 50")


def result(c, progress=1.0):
    """The owner's photo, resolving out of the pixel one, at the left, and Redlamp's renders of it in
    the five looks still to come at the right."""
    ed = edit(c, show=False)
    before, after = pair(ed)
    c.img.paste(pixel(None, (before.w, before.h)), (before.x, before.y))
    pixels = np.asarray(c.img)[before.y:before.y2, before.x:before.x2].copy()
    w.tag(c, before, "BEFORE")
    placeholder(c, after, [*NAMES, "", "REDLAMP'S", "RENDERS", "GO HERE"], "THE LOOKS")
    w.caption(c, w.REAL_PHOTO)
    return [w.Overlay(before, ORIGINAL, pixels, progress)]


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, datasheet, "BUILT FROM EACH / FILM'S DATASHEET",
            "The motif starts; a soft tone rising with the curve as it draws."),
    w.Panel(3, 4.8, portra, "PORTRA 400", "A blip as the look applies."),
    w.Panel(4, 7.2, tri_x, "TRI-X 400, then CINESTILL 800T two beats later",
            "A blip for each look; the drums come in."),
    w.Panel(5, 9.6, velvia, "VELVIA 50, then HP5 PLUS two beats later", "A blip for each look."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO) + "; the photo, then its five looks, one a beat",
            "The develop sting, then a blip a beat as the real photo goes through the five looks."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
