"""
E04, Lightroom shortcuts: Lightroom Classic's keyboard shortcuts, panel order and slider names, working
in Redlamp. The editor has the dancer open with four keys under the photo; each bar presses one and the
editor does what Lightroom does: R the crop frame, K the brush, backslash before and after, V black and
white; then the real Redlamp window, its panels in Lightroom's order, then its shortcut list, and the
end card.

The photo is DSC04439.ARW, from a Sony α7R V, the README's hero, with its edit (docs/images/hero.png);
the before is the same photo in Redlamp's before and after view (docs/images/hero-compare.png). The
black and white stands in for Redlamp's: the edit's own luminance. The result is the app itself, its
window captured by scripts/capture-promo.sh (video/public/promo/panels.png and shortcuts.png).
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e04")
FEATURE = "LIGHTROOM SHORTCUTS"
PHOTO = ("DSC04439.ARW (SONY ILCE-7RM5) WITH ITS EDIT, DOCS/IMAGES/HERO.PNG; "
         "ITS BEFORE FROM DOCS/IMAGES/HERO-COMPARE.PNG; THE BLACK AND WHITE IS THE EDIT'S LUMINANCE, STANDING IN FOR REDLAMP'S. THE REAL APP: "
         "VIDEO/PUBLIC/PROMO/PANELS.PNG, THEN SHORTCUTS.PNG")
FILE = "DSC04439.ARW"
AFTER = w.crop("docs/images/hero.png", (686, 78, 1627, 1477))
BEFORE = w.crop("docs/images/hero-compare.png", (387, 220, 1160, 1346))
ASPECT = AFTER.width / AFTER.height
PANEL = 70

# The keys the video presses, in order, and what each does (README, Keyboard shortcuts).
KEYS = [("R", "CROP"), ("K", "BRUSH"), ("\\", "BEFORE / AFTER"), ("V", "BLACK & WHITE")]
KEY, PITCH = 15, 16


def mono(img):
    """`img` in black and white: its luminance in linear light, back in sRGB."""
    a = np.asarray(img, dtype=np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) @ [0.2126, 0.7152, 0.0722]
    v = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.rint(np.repeat(v[..., None], 3, axis=2) * 255).astype(np.uint8))


MONO = mono(AFTER)


def capture(path):
    """A window capture with its transparent corners on the page's background."""
    img = Image.open(w.REPO / path).convert("RGBA")
    page = Image.new("RGBA", img.size, w.THEME.rgb("bg") + (255,))
    return Image.alpha_composite(page, img).convert("RGB")


APP = capture("video/public/promo/panels.png")

_photos = {}


def pixel(img, size):
    key = (id(img), size)
    if key not in _photos:
        _photos[key] = w.pixel_photo(img, *size)
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
    brush_ring(c, ph.x + round(ph.w * 0.42), ph.y + round(ph.h * 0.66))
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
    c.img.paste(pixel(APP, (r.w, r.h)), (r.x, r.y))
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
