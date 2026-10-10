"""
E04, Lightroom shortcuts: Lightroom Classic's keyboard shortcuts, panel order and slider names, working
in Redlamp. The editor has a portrait open with four keys under the photo; each bar presses one and the
editor does what Lightroom does: R the crop frame, K the brush, backslash before and after, V black and
white; then the real Redlamp window, its panels in Lightroom's order, then its shortcut list, and the
end card.

The photo is the owner's man in the green shirt (DSC03301 (2).jpg, in ~/src/redlamp-social/photos),
cropped to 4:5 about him. His JPEG is his finished photo and stands in for the edit. The before and the
black and white on the pixel photo are drawings of it: the before flatter, darker and with less colour,
the black and white its luminance. The result is the app itself, its window captured by
scripts/capture-promo.sh (video/public/promo/panels.png and shortcuts.png).
"""

from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e04")
FEATURE = "LIGHTROOM SHORTCUTS"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC03301 (2).jpg"
PHOTO = ("THE OWNER'S DSC03301 (2).JPG (THE MAN IN THE GREEN SHIRT), CROPPED TO 4:5, IN EVERY EDITOR PANEL; ITS "
         "BEFORE AND ITS BLACK AND WHITE ON THE PIXEL PHOTO ARE DRAWINGS. THE REAL APP: VIDEO/PUBLIC/PROMO/PANELS.PNG, "
         "THEN SHORTCUTS.PNG, CAPTURED WITH THE README'S DANCER OPEN")
FILE = "DSC03301.ARW"
# A 4:5 crop about the man, in the photo's own pixels.
BOX = (165, 80, 1365, 1580)
AFTER = Image.open(SOURCE).convert("RGB").crop(BOX)
ASPECT = 4 / 5
PANEL = 64

# The keys the video presses, in order, and what each does (README, Keyboard shortcuts).
KEYS = [("R", "CROP"), ("K", "BRUSH"), ("\\", "BEFORE / AFTER"), ("V", "BLACK & WHITE")]
KEY, PITCH = 13, 14


def drawn(img, *, ev=0.0, contrast=1.0, colour=1.0):
    """`img` redrawn for the pixel photo only: `ev` stops of exposure, contrast about the middle grey
    and colour toward grey (0 is its luminance, in linear light)."""
    a = np.asarray(img.resize((img.width // 4, img.height // 4), Image.BOX), dtype=np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** ev
    grey = lin @ [0.2126, 0.7152, 0.0722]
    lin = np.clip(grey[..., None] + (lin - grey[..., None]) * colour, 0, 1)
    v = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    v = 0.4 + (v - 0.4) * contrast
    return Image.fromarray(np.rint(np.clip(v, 0, 1) * 255).astype(np.uint8))


BEFORE = drawn(AFTER, ev=-0.3, contrast=0.75, colour=0.6)
MONO = drawn(AFTER, colour=0.0, contrast=1.1)


def capture(path):
    """A window capture with its transparent corners on the page's background."""
    img = Image.open(w.REPO / path).convert("RGBA")
    page = Image.new("RGBA", img.size, w.THEME.rgb("bg") + (255,))
    return Image.alpha_composite(page, img).convert("RGB")


APP = capture("video/public/promo/panels.png")


def photo_palette(images, colors=40):
    """A palette taken from the photos themselves, with the editor's greys, so the skin, the green
    shirt and the grey hair keep their own colours in the pixel photo."""
    tiles = [img.resize((96, 120), Image.BOX) for img in images]
    sheet = Image.new("RGB", (96 * len(tiles), 120))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (96 * i, 0))
    flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[:3 * colors]
    found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    return list(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))


PALETTE = photo_palette([AFTER, BEFORE, MONO])

_photos = {}


def pixel(img, size):
    key = (id(img), size)
    if key not in _photos:
        _photos[key] = w.lock(w.fit(img, *size, Image.BOX), PALETTE, dither=0.4).convert("RGB")
    return _photos[key]


def edit(c, photo=AFTER, *, pressed=None):
    """The editor with `photo`, and the four keys under it, the `pressed` one (an index) held down and
    its label lit. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(photo, size), file=FILE, aspect=ASPECT, panel=PANEL)
    p = ed.panel
    for i, (key, label) in enumerate(KEYS):
        color = w.GREY["label"] if pressed is None else w.GREY["value"] if i == pressed else w.GREY["dim"]
        w.keycap(c, p.x + 2, p.y + 1 + i * PITCH, key, label, pressed=i == pressed, size=KEY, label_color=color)
    return ed


def crop_frame(c, r):
    """Redlamp's crop overlay on the whole photo: the frame, its rule-of-thirds guide and the handles at
    the corners and the middle of each edge."""
    for k in (1, 2):
        c.dots(r.x + 1, r.y + round(k * r.h / 3), r.w - 2, w.GREY["key"])
        c.vdots(r.x + round(k * r.w / 3), r.y + 1, r.h - 2, w.GREY["key"])
    c.box(*r, w.GREY["thumb"])
    for hx in (r.x, r.x2 - 1):
        for hy in (r.y, r.y2 - 1):
            c.rect(hx - 1, hy - 1, 3, 3, w.GREY["thumb"])
    c.rect(r.cx - 2, r.y - 1, 5, 2, w.GREY["thumb"])
    c.rect(r.cx - 2, r.y2 - 1, 5, 2, w.GREY["thumb"])
    c.rect(r.x - 1, r.cy - 2, 2, 5, w.GREY["thumb"])
    c.rect(r.x2 - 1, r.cy - 2, 2, 5, w.GREY["thumb"])


def brush_ring(c, cx, cy, r=9):
    """The brush's pointer: its size as a ring, its feather as a fainter ring inside, and its centre."""
    c.circle(cx + 0.5, cy + 0.5, r + 0.5, None, outline=w.GREY["thumb"])
    c.circle(cx + 0.5, cy + 0.5, r * 0.6 + 0.5, None, outline=w.GREY["fill"])
    c.hline(cx - 1, cy, 3, w.GREY["thumb"])
    c.vline(cx, cy - 1, 3, w.GREY["thumb"])


def hook(c):
    edit(c)
    w.caption(c, EPISODE["hooks"]["a"])


def crop(c):
    ed = edit(c, pressed=0)
    crop_frame(c, ed.photo)
    w.caption(c, "R  CROP")


def brush(c):
    ed = edit(c, pressed=1)
    ph = ed.photo
    brush_ring(c, ph.x + round(ph.w * 0.3), ph.y + round(ph.h * 0.72))
    w.caption(c, "K  BRUSH")


def before_after(c):
    ed = edit(c, BEFORE, pressed=2)
    w.tag(c, ed.photo, "BEFORE")
    w.caption(c, "\\  BEFORE / AFTER")


def black_white(c):
    edit(c, MONO, pressed=3)
    w.caption(c, "V  BLACK & WHITE")


def result(c, progress=1.0):
    """The real Redlamp window in place of a pixel one, centred on the stage."""
    w.header(c, FEATURE)
    st = w.STAGE
    h = round(st.w * APP.height / APP.width)
    r = w.Rect(st.x, st.y + (st.h - h) // 2, st.w, h)
    c.claim(r, "the app")
    c.rect(r.x + 2, r.y + 2, r.w, r.h, "shadow")
    c.img.paste(w.pixel_photo(APP, r.w, r.h), (r.x, r.y))
    pixels = np.asarray(c.img)[r.y:r.y2, r.x:r.x2].copy()
    ed = w.Editor(r, r, r, None, r, pixels)
    return w.result_frame(c, ed, APP, label=w.REAL_APP, progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, crop, "R  CROP", "A key click; each key plays a note of the motif."),
    w.Panel(3, 4.8, brush, "K  BRUSH", "A key click and the motif's next note."),
    w.Panel(4, 7.2, before_after, "\\  BEFORE / AFTER",
            "A key click; the drums come in. The photo shows before, then after on the next beat."),
    w.Panel(5, 9.6, black_white, "V  BLACK & WHITE", "A key click."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_APP),
            "The develop sting: the motif's head over struck glass; a tick as the shortcut list opens at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
