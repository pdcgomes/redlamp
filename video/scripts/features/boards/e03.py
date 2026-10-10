"""
E03, Film looks: looks of 30 real film stocks, built from each film's datasheet. The editor opens a
landscape with the Base Look list showing five film names; Portra 400's characteristic curve, from
Kodak's datasheet, draws itself on a chart; then the photo in Portra 400, Tri-X 400, CineStill 800T,
Velvia 50 and HP5 Plus, picked from the list; then the real photo in the five looks, and the end card.

The photo stands in until the owner's arrives: the landscape of the README's film examples
(Sony_ILCE-6700.ARW from the look-development set), Redlamp's default rendering above each
docs/images/film/look-*.jpg and the look below it. The curve is the green-sensitive layer of Portra
400's characteristic curves, as research/film-data digitised them from Kodak's datasheet E-4050.
"""

import json

from PIL import Image

from features import world as w

EPISODE = w.episode("e03")
FEATURE = "FILM LOOKS"
PHOTO = ("SONY_ILCE-6700.ARW, THE LANDSCAPE IN THE README'S FILM EXAMPLES: DOCS/IMAGES/FILM/LOOK-PORTRA-400.JPG "
         "(THE ORIGINAL ABOVE), LOOK-TRI-X-400, LOOK-CINESTILL-800T, LOOK-VELVIA-50 AND LOOK-HP5-PLUS (THE LOOK "
         "BELOW). CURVE: RESEARCH/FILM-DATA/KODAK-PORTRA-400.JSON, FROM KODAK DATASHEET E-4050")
FILE = "SONY_ILCE-6700.ARW"
PANEL = 66

# The looks in the order the video picks them, and the README image of each.
LOOKS = [
    ("PORTRA 400", "portra-400"),
    ("TRI-X 400", "tri-x-400"),
    ("CINESTILL 800T", "cinestill-800t"),
    ("VELVIA 50", "velvia-50"),
    ("HP5 PLUS", "hp5-plus"),
]
NAMES = [name for name, _ in LOOKS]
# Each README example is three photos across, the original above the look; the landscape is the first.
ORIGINAL_BOX, LOOK_BOX = (1, 1, 419, 279), (1, 287, 419, 565)
ORIGINAL = w.crop("docs/images/film/look-portra-400.jpg", ORIGINAL_BOX)
LOOKED = {name: w.crop(f"docs/images/film/look-{slug}.jpg", LOOK_BOX) for name, slug in LOOKS}
ASPECT = ORIGINAL.width / ORIGINAL.height

CURVES = json.loads((w.REPO / "research/film-data/kodak-portra-400.json").read_text())["characteristicCurves"]


def photo_palette(images, colors=48):
    """A palette taken from the photos themselves, with the editor's greys. The shared palette's
    saturated greens and blues would make every look the same picture; this keeps each look's own
    warmth, contrast and colour, so the pixel photo changes as the real one does."""
    tiles = [img.resize((140, 93), Image.BOX) for img in images]
    sheet = Image.new("RGB", (140 * len(tiles), 93))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (140 * i, 0))
    flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[:3 * colors]
    found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    return list(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))


PALETTE = photo_palette([ORIGINAL, *LOOKED.values()])

_photos = {}


def pixel(name, size):
    """The pixel photo of the look `name`, or of the original when it's None."""
    if (name, size) not in _photos:
        src = w.fit(LOOKED[name] if name else ORIGINAL, *size, Image.BOX)
        _photos[name, size] = w.lock(src, PALETTE, dither=0.45).convert("RGB")
    return _photos[name, size]


def edit(c, look=None, *, press=False):
    """The editor showing the photo in `look` (None for the original), with the Base Look list and the
    look chosen in it, the pointer clicking it when `press`. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(look, size), file=FILE, aspect=ASPECT, panel=PANEL)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASE LOOK", right="36 LOOKS")
    i = NAMES.index(look) if look else None
    w.rows(c, p.x + 2, y + 1, p.w - 4, NAMES, selected=i)
    if press and i is not None:
        w.pointer(c, p.x + 2 + c.measure(look) + 10, y + 1 + i * 9 + 3, pressed=True)
    return ed


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
    ed = edit(c, "PORTRA 400")
    return w.result_frame(c, ed, LOOKED["PORTRA 400"], mark="PORTRA 400", progress=progress)


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
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO) + ", the photo's tag naming each look",
            "The develop sting, then a blip a beat as the real photo goes through the five looks."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
