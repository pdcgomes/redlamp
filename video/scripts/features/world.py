"""
The shared pieces of Redlamp's feature videos (docs/plans/2026-10-10-feature-videos.md): ten 19.2-second
vertical videos, each a pixel-art Redlamp editor doing one feature step by step, then the real photo
edited in Redlamp, then the end card. Every frame is drawn with pixelkit, the pixel-art kit in
github.com/pdcgomes/pixelartvisuals (at $PIXELKIT, or ~/src/pixelartvisuals), on a 216 × 384 grid shown
five times the size, so 1080 × 1920 holds every logical pixel as a 5 × 5 block.

TikTok and Instagram draw their own controls over the top 52 rows, the bottom 96, and the right 32
columns between rows 140 and 320, so nothing to read goes there. Words that must be read are in the
large font at twice its size: at most 17 characters a line and two lines at once.

The page is the kit's dark navy; the editor is neutral grey, as the app is, with the control being
changed in the system accent, as the app marks it. The only red is the lamp's light, and the editor's
own red mask overlay in the episodes that use masks.
"""

import json
import math
import os
import sys
from pathlib import Path
from typing import Callable, NamedTuple

import numpy as np
from PIL import Image

VIDEO = Path(__file__).resolve().parents[2]
REPO = VIDEO.parent
KIT = Path(os.environ.get("PIXELKIT", Path.home() / "src/pixelartvisuals"))
sys.path.insert(0, str(KIT / "skill/scripts"))

from pixelkit import FONTS, Canvas, Rect, load_theme, lock  # noqa: E402

THEME = load_theme()
POSTS = json.loads((REPO / "docs/social/posts.json").read_text())

# ---------------------------------------------------------------- the grid

W, H, SCALE = 216, 384, 5
BPM = 100
BAR = 4 * 60 / BPM

# Where the apps' own controls sit on a 1080 × 1920 video, in output pixels (x, y, w, h).
COVERED_PX = {
    "top bar": (0, 0, 1080, 260),
    "caption and buttons": (0, 1440, 1080, 480),
    "side buttons": (920, 700, 160, 900),
}

HEADER = Rect(0, 52, W, 12)
CAPTION = Rect(0, 66, W, 35)
CAPTION_ROWS = {1: (77,), 2: (67, 87)}
STAGE = Rect(4, 104, 208, 183)
READ_RIGHT = 184
LINE_CHARS = 17

REAL_PHOTO = ("REAL PHOTO,", "EDITED IN REDLAMP")
REAL_APP = ("THE REAL APP",)
END_CARD = tuple(POSTS["standard"]["endCard"])


def covered(w=W, h=H, scale=SCALE):
    """The covered zones of a w × h grid shown `scale` times the size, widened to whole logical pixels."""
    zones = []
    for name, (x, y, zw, zh) in COVERED_PX.items():
        x0, y0 = x // scale, y // scale
        x1, y1 = min(w, -(-(x + zw) // scale)), min(h, -(-(y + zh) // scale))
        zones.append((Rect(x0, y0, x1 - x0, y1 - y0), name))
    return zones


def canvas(w=W, h=H, scale=SCALE):
    return Canvas(w, h, theme=THEME, scale=scale)


def episode(key):
    return next(e for e in POSTS["episodes"] if e["id"] == key)


class Panel(NamedTuple):
    """One bar of a storyboard: its number and start in seconds, what draws it (a function of the canvas
    that returns any overlays for render), the words on screen and the sound."""
    bar: int
    time: float
    draw: Callable
    words: str
    sound: str


# ---------------------------------------------------------------- colour

# The editor's neutral greys, after Palette.standard in RedlampDesign (panels at 0.115 white, labels at
# 72 % white, values at 90 %), spaced a little wider so each step survives at this size.
GREY = {
    "edge": "#060606",
    "rim": "#3e3e3e",
    "chrome": "#1b1b1b",
    "well": "#151515",
    "canvas": "#202020",
    "panel": "#282828",
    "raised": "#353535",
    "control": "#474747",
    "light": "#5d5d5d",
    "dim": "#7c7c7c",
    "fill": "#9c9c9c",
    "label": "#b4b4b4",
    "key": "#d6d6d6",
    "value": "#ebebeb",
    "thumb": "#f4f4f4",
}
INK = "#141414"
# The system accent, which the app gives the control being changed.
ACCENT = "sky"

# Brand.swift's safelight lamp: the ring, the steel and the near-black behind the glass.
LAMP_RING, LAMP_STEEL, LAMP_INK = "#d9d0cb", "#57504e", "#1a1414"

# A photo locks to the kit's palette, the editor's greys and a ramp of warm neutrals, so its greys stay
# grey and its beiges, woods and skin stay warm instead of turning navy or orange.
WARM = ["#2e2620", "#4a3e33", "#6b5b4b", "#8f7c66", "#b3a084", "#d6c6a8", "#f0e6d0"]
PHOTO_PALETTE = list(dict.fromkeys(THEME.palette() + [THEME.rgb(c) for c in [*GREY.values(), *WARM]]))


# ---------------------------------------------------------------- the header and captions

# The architecture series' safelight mark, without the white pixel it had in the middle of the lens.
LAMP_MARK = (
    [
        "..ooooo..",
        ".orrrrro.",
        "orrlllrro",
        "orlllllro",
        "orlllllro",
        "orrlllrro",
        ".orrrrro.",
        "..ooooo..",
    ],
    {"o": "muted", "r": "red", "l": "red.light"},
)


def header(c, feature, *, y=HEADER.y):
    """Redlamp's safelight mark and REDLAMP · FEATURE, centred, in the large font."""
    parts = [("REDLAMP", "white"), (f" · {feature}", "muted")]
    tw = c.measure("".join(p for p, _ in parts), "large")
    x = (c.w - (9 + 4 + tw)) // 2
    c.sprite(x, y + 2, *LAMP_MARK)
    c.spans(x + 13, y + 3, parts, font="large")
    c.claim(Rect(0, y, c.w, HEADER.h), "header")


def caption(c, lines, *, color="white", rows=None):
    """One or two lines centred under the header, in the large font at twice its size."""
    lines = [lines] if isinstance(lines, str) else [ln for ln in lines if ln]
    for line, y in zip(lines, rows or CAPTION_ROWS[len(lines)]):
        c.text(c.w // 2, y, line, color, font="large", scale=2, align="center")
    c.claim(CAPTION, "caption")


def check(c, *, video=True):
    """The kit's layout warnings, plus words in the covered zones and caption lines over 17 characters."""
    notes = c.check()
    for r, s in c.texts:
        if video:
            for zone, name in covered(c.w, c.h, c.scale):
                if r.intersects(zone):
                    notes.append(f"{s!r} is under the {name} at {tuple(r)}")
        if r.h >= 14 and len(s) > LINE_CHARS:
            notes.append(f"{s!r} is longer than {LINE_CHARS} characters")
    return list(dict.fromkeys(notes))


# ---------------------------------------------------------------- photos

def crop(path, box=None):
    """A picture from the repository, cropped to `box` (left, top, right, bottom) in its own pixels."""
    img = Image.open(REPO / path).convert("RGB")
    return img.crop(box) if box else img


def fit(img, w, h, resample=Image.LANCZOS):
    """`img` cropped about its centre to the shape of w × h, then resized to it."""
    iw, ih = img.size
    if iw * h > ih * w:
        cw = round(ih * w / h)
        img = img.crop(((iw - cw) // 2, 0, (iw - cw) // 2 + cw, ih))
    elif iw * h < ih * w:
        ch = round(iw * h / w)
        img = img.crop((0, (ih - ch) // 2, iw, (ih - ch) // 2 + ch))
    return img.resize((w, h), resample)


def pixel_photo(src, w, h, *, dither=0.45):
    """A real photo at the photo area's size, locked to the palette, so the pixel photo and the real one
    are the same picture. `src` is a path in the repository or a PIL image."""
    img = crop(src) if isinstance(src, (str, Path)) else src.convert("RGB")
    return lock(fit(img, w, h, Image.BOX), PHOTO_PALETTE, dither=dither).convert("RGB")


# ---------------------------------------------------------------- the editor

class Editor(NamedTuple):
    window: Rect
    photo: Rect
    canvas: Rect
    strip: Rect | None
    panel: Rect
    pixels: np.ndarray | None


def layout(*, aspect=1.6, panel=58, strip=0, window=STAGE, read_right=READ_RIGHT):
    """Where editor() puts its parts, without drawing them: the window, the photo, its canvas, the
    filmstrip (or None) and the panel's content area, which ends left of the side buttons."""
    x, y, w, h = window
    top = y + h - 1 - panel
    film = Rect(x + 1, top - 1 - strip, w - 2, strip) if strip else None
    area_bottom = (film.y - 1) if film else (top - 1)
    area = Rect(x + 1, y + 12, w - 2, area_bottom - (y + 12))
    ph = area.h - 6
    pw = min(area.w - 8, round(ph * aspect))
    ph = min(ph, round(pw / aspect))
    photo = Rect(area.x + (area.w - pw) // 2, area.y + (area.h - ph) // 2, pw, ph)
    content = Rect(x + 5, top + 4, read_right - 1 - (x + 5), panel - 7)
    return Editor(Rect(x, y, w, h), photo, area, film, content, None)


def editor(c, photo=None, *, file="DSC_0750.NEF", aspect=1.6, panel=58, strip=0, window=STAGE,
           read_right=READ_RIGHT):
    """A Mac app window in neutral greys: a title bar with the file's name, the photo centred on its
    canvas, an optional filmstrip `strip` rows tall, and a panel `panel` rows tall at the bottom.
    `photo` is a PIL image (see pixel_photo) or None for an empty canvas. Returns the parts' rects as
    layout() does, with the pixel photo as drawn, so overlays can tell what has been drawn over it."""
    ed = layout(aspect=aspect, panel=panel, strip=strip, window=window, read_right=read_right)
    x, y, w, h = window
    c.claim(window, "editor")
    c.rect(x + 2, y + 2, w, h, "shadow")
    c.rect(x, y, w, h, GREY["chrome"])
    c.box(x, y, w, h, GREY["rim"])
    for cx, cy in ((x, y), (x + w - 1, y), (x, y + h - 1), (x + w - 1, y + h - 1)):
        c.px(cx, cy, "bg")
    for i in range(3):
        lx = x + 5 + i * 6
        c.rect(lx, y + 4, 4, 4, GREY["light"])
        for cx, cy in ((lx, y + 4), (lx + 3, y + 4), (lx, y + 7), (lx + 3, y + 7)):
            c.px(cx, cy, GREY["chrome"])
    c.text(x + 25, y + 3, file, GREY["label"])
    c.hline(x + 1, y + 11, w - 2, GREY["edge"])

    top = y + h - 1 - panel
    c.rect(x + 1, top, w - 2, panel, GREY["panel"])
    c.hline(x + 1, top - 1, w - 2, GREY["edge"])
    if ed.strip:
        c.rect(*ed.strip, GREY["well"])
        c.hline(x + 1, ed.strip.y - 1, w - 2, GREY["edge"])
    c.rect(*ed.canvas, GREY["canvas"])

    pr, pixels = ed.photo, None
    if photo is not None:
        if photo.size != (pr.w, pr.h):
            photo = fit(photo, pr.w, pr.h, Image.NEAREST)
        c.img.paste(photo, (pr.x, pr.y))
        pixels = np.asarray(c.img)[pr.y:pr.y2, pr.x:pr.x2].copy()
    c.claim(ed.panel, "panel")
    return ed._replace(pixels=pixels)


def panel_title(c, x, y, w, name, *, right=None):
    """A panel's header: an open disclosure triangle, its name, an optional note at the right, a rule
    under it. Returns the y its content starts at."""
    c.text(x, y, "▼", GREY["dim"])
    c.text(x + 7, y, name, GREY["value"])
    if right:
        c.text(x + w, y, right, GREY["dim"], align="right")
    c.hline(x, y + 8, w, GREY["raised"])
    return y + 12


def slider(c, x, y, w, label, value, frac, *, origin=0.5, active=False, label_w=46, value_w=24):
    """One row as Lightroom draws it: the name, a track with its knob at `frac` (0 to 1) and a tick at
    `origin`, and the value right-aligned at x + w. The `active` one is marked as Redlamp marks the
    slider being changed: its name in the system accent and a bar at the panel's edge. Returns the
    knob's centre, for the pointer."""
    ink = GREY["value"] if active else GREY["label"]
    if active:
        c.vline(x - 3, y - 1, 7, ACCENT)
    c.text(x, y, label, ACCENT if active else ink)
    t0, t1 = x + label_w, x + w - value_w
    ty = y + 2
    span = t1 - t0 - 1
    kx, ox = t0 + round(frac * span), t0 + round(origin * span)
    c.hline(t0, ty, t1 - t0, GREY["control"])
    lo, hi = sorted((ox, kx))
    c.hline(lo, ty, hi - lo + 1, GREY["fill"] if active else GREY["dim"])
    c.vline(ox, ty - 1, 3, GREY["dim"])
    c.rect(kx - 2, y, 5, 5, GREY["thumb"])
    for cx, cy in ((kx - 2, y), (kx + 2, y), (kx - 2, y + 4), (kx + 2, y + 4)):
        c.px(cx, cy, GREY["panel"])
    c.text(x + w, y, value, ink, align="right")
    return kx, ty


def button(c, x, y, label, *, w=None, pressed=False, selected=False, primary=False, bg=GREY["panel"]):
    """A rounded push button, 9 rows tall. `primary` is the light default button; `pressed` lights it
    and sinks its label a row, as it looks under the click."""
    w = w or c.measure(label) + 10
    fill = GREY["key"] if primary else GREY["light"] if selected else GREY["control"]
    if pressed:
        fill = GREY["fill"] if primary else GREY["dim"]
    c.rect(x, y, w, 9, fill)
    if not pressed:
        c.hline(x + 1, y, w - 2, GREY["value"] if primary else GREY["light"] if not selected else GREY["fill"])
    for cx, cy in ((x, y), (x + w - 1, y), (x, y + 8), (x + w - 1, y + 8)):
        c.px(cx, cy, bg)
    ink = INK if primary else GREY["value"]
    c.text(x + (w - c.measure(label)) // 2, y + 2 + (1 if pressed else 0), label, ink)
    return Rect(x, y, w, 9)


def rows(c, x, y, w, items, *, selected=None, icon=None, step=9, right=None):
    """A list, one item a row, with an optional icon from the kit and a dim note right-aligned per row
    (`right`, a list). The `selected` row is highlighted. Returns the y below the list."""
    for i, item in enumerate(items):
        ry = y + i * step
        on = i == selected
        if on:
            c.rect(x - 2, ry - 2, w + 4, step, GREY["raised"])
        tx = x
        if icon:
            c.icon(x, ry - 1, icon, GREY["fill"] if not on else GREY["value"])
            tx += 12
        c.text(tx, ry, item, GREY["value"] if on else GREY["label"])
        if right and right[i]:
            c.text(x + w, ry, right[i], GREY["dim"], align="right")
    return y + len(items) * step


def field(c, x, y, w, text="", *, placeholder="", focused=False, caret=True):
    """A text field, 11 rows tall: the typed text with a caret when focused, or the dim placeholder."""
    c.rect(x, y, w, 11, GREY["well"])
    c.box(x, y, w, 11, GREY["fill"] if focused else GREY["control"])
    if text:
        tw = c.text(x + 4, y + 3, text, GREY["value"])
    else:
        tw = c.text(x + 4, y + 3, placeholder, GREY["dim"]) if placeholder else 0
        tw = 0 if focused else tw
    if focused and caret:
        c.vline(x + 4 + tw + (1 if text else 0), y + 2, 7, GREY["value"])
    return Rect(x, y, w, 11)


def filmstrip(c, rect, thumbs, *, selected=None, cell=None, gap=2):
    """Thumbnails along a filmstrip: PIL images (fitted to each cell) or colours. The `selected` one is
    ringed in white. Returns each thumbnail's rect."""
    th = rect.h - 4
    tw = cell or round(th * 1.5)
    out = []
    for i, thumb in enumerate(thumbs):
        tx = rect.x + 3 + i * (tw + gap)
        if tx + tw > rect.x2 - 2:
            break
        r = Rect(tx, rect.y + 2, tw, th)
        if isinstance(thumb, Image.Image):
            c.img.paste(fit(thumb, tw, th, Image.NEAREST), (r.x, r.y))
        else:
            c.rect(*r, thumb)
        if i == selected:
            c.box(r.x - 1, r.y - 1, r.w + 2, r.h + 2, GREY["value"])
        out.append(r)
    return out


def banner(c, x, y, w, parts, *, action=None, pressed=False):
    """A notice across the top of the photo: `parts` joined by ' · ', and a button at its right, 13 rows
    tall. Returns the button's rect, or the banner's when it has none."""
    c.rect(x, y, w, 13, GREY["raised"])
    c.box(x, y, w, 13, GREY["light"])
    c.text(x + 4, y + 4, " · ".join(parts), GREY["value"])
    if action:
        bw = c.measure(action) + 10
        return button(c, x + w - bw - 2, y + 2, action, w=bw, primary=True, pressed=pressed, bg=GREY["raised"])
    return Rect(x, y, w, 13)


def files(c, x, y, w, names, *, badges=None, mark=None, step=10):
    """A file list: the kit's file icon and each name, and a dim badge right-aligned (UNCHANGED, NEW).
    The row `mark` is highlighted. Returns the y below the list."""
    for i, name in enumerate(names):
        ry = y + i * step
        if i == mark:
            c.rect(x - 2, ry - 2, w + 4, step, GREY["raised"])
        c.icon(x, ry - 2, "file", GREY["fill"])
        c.text(x + 10, ry, name, GREY["value"] if i == mark else GREY["label"])
        if badges and badges[i]:
            c.text(x + w, ry, badges[i], GREY["dim"], align="right")
    return y + len(names) * step


def keycap(c, x, y, key, label=None, *, pressed=False, size=19, scale=1, label_color="white"):
    """A key seen from above with its legend in the large font at `scale`, pressed (sunk 2 rows) or
    not, and a label to its right in the large font. Returns the key's rect."""
    sink = 2 if pressed else 0
    c.rect(x, y, size, size, INK)
    face = Rect(x + 1, y + 1 + sink, size - 2, size - 4)
    if not pressed:
        c.rect(x + 1, y + size - 3, size - 2, 2, GREY["dim"])
    c.rect(*face, GREY["key"])
    c.hline(face.x, face.y, face.w, GREY["thumb"])
    c.vline(face.x, face.y, face.h, GREY["thumb"])
    c.text(face.x + face.w // 2 + 1, face.y + (face.h - 7 * scale) // 2, key, INK, font="large", scale=scale,
           align="center")
    if label:
        c.text(x + size + 6, y + (size - 7) // 2, label, label_color, font="large")
    return Rect(x, y, size, size)


POINTER = [
    "#",
    "##",
    "###",
    "####",
    "#####",
    "######",
    "#######",
    "########",
    "#####",
    "##.##",
    "#...##",
    "....##",
]


def pointer(c, x, y, *, pressed=False):
    """The Mac's arrow, black with a white rim, its tip on (x, y). Pressed, a ring marks the click."""
    if pressed:
        c.circle(x + 0.5, y + 0.5, 4.5, None, outline=GREY["key"])
    c.sprite(x, y, POINTER, {"#": "#000000"}, outline="#ffffff")


def tag(c, photo, text):
    """A small label on the photo, as Redlamp marks BEFORE and AFTER, centred at its top."""
    tw = c.measure(text)
    r = Rect(photo.cx - (tw + 8) // 2, photo.y + 3, tw + 8, 9)
    c.rect(*r, GREY["raised"])
    for cx, cy in ((r.x, r.y), (r.x2 - 1, r.y), (r.x, r.y2 - 1), (r.x2 - 1, r.y2 - 1)):
        c.px(cx, cy, GREY["chrome"])
    c.text(r.x + 4, r.y + 2, text, GREY["value"])
    return r


def mask_overlay(c, photo, mask, *, amount=0.5):
    """The editor's red overlay on the pixels of `photo` (a Rect) where `mask` (h × w booleans) is set,
    as Lightroom shows a mask."""
    yy, xx = np.mgrid[0:photo.h, 0:photo.w]
    on = mask & (bayer(4)[(photo.y + yy) % 4, (photo.x + xx) % 4] < amount)
    a = np.asarray(c.img).copy()
    a[photo.y:photo.y2, photo.x:photo.x2][on] = THEME.rgb("red")
    c.img.paste(Image.fromarray(a), (0, 0))


# ---------------------------------------------------------------- the result

def bayer(n=8):
    """An n × n ordered-dither threshold matrix (n a power of two), thresholds evenly in 0..1."""
    m = np.zeros((1, 1), dtype=int)
    while m.shape[0] < n:
        m = np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])
    return (m + 0.5) / m.size


def reveal_mask(p, w, h, *, block=1, order=8):
    """Which logical pixels of a w × h photo show the real image at progress p (0 to 1): an ordered
    dither, so the pixel photo resolves into the real one block by block, evenly across the picture.
    `block` groups pixels into larger squares."""
    yy, xx = np.mgrid[0:h, 0:w] // block
    return bayer(order)[yy % order, xx % order] < p


class Overlay(NamedTuple):
    """A real image laid over `rect` at output resolution, through the reveal at `progress`. Pixels drawn
    over the pixel photo since it was placed (tags, the pointer) stay on top."""
    rect: Rect
    image: Image.Image
    pixels: np.ndarray | None = None
    progress: float = 1.0


def result_frame(c, ed, real, *, label=REAL_PHOTO, mark=None, progress=1.0):
    """The result: the real photo where the pixel one was, with its label as the caption and an optional
    BEFORE or AFTER tag. Draw the editor with the pixel photo first. Returns the overlay to render."""
    caption(c, label)
    if mark:
        tag(c, ed.photo, mark)
    return [Overlay(ed.photo, real, ed.pixels, progress)]


def render(c, scale=SCALE, overlays=()):
    """The frame at `scale`: the canvas with nearest-neighbour pixels, and each overlay's real image at
    full resolution inside its rect."""
    out = c.img.resize((c.w * scale, c.h * scale), Image.NEAREST)
    for ov in overlays:
        r = ov.rect
        show = reveal_mask(ov.progress, r.w, r.h)
        if ov.pixels is not None:
            show &= (np.asarray(c.img)[r.y:r.y2, r.x:r.x2] == ov.pixels).all(axis=2)
        mask = Image.fromarray((show * 255).astype(np.uint8)).resize((r.w * scale, r.h * scale), Image.NEAREST)
        out.paste(fit(ov.image, r.w * scale, r.h * scale), (r.x * scale, r.y * scale), mask)
    return out


def save(img, path):
    """Write a PNG, as a palette image when the frame has no more than 256 colours."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    colors = img.getcolors(256)
    if colors:
        flat = [v for _, rgb in colors for v in rgb]
        pal = Image.new("P", (1, 1))
        pal.putpalette(flat + flat[:3] * (256 - len(colors)))
        img = img.quantize(palette=pal, dither=Image.Dither.NONE)
    img.save(path, optimize=True)
    return path


# ---------------------------------------------------------------- the end card

def lamp(c, cx, cy, r=19):
    """The safelight seen head-on, as the app icon draws it: a ruby lens with faint Fresnel rings in a
    steel bezel held by three screws, lit from above left. The lens is brightest across its middle and
    darkens to its rim; the only highlight is a small crescent off the centre, so there is no bright
    point in the lens."""
    bezel = r + 8
    shades = [THEME.rgb(s) for s in (LAMP_INK, "#2e2827", LAMP_STEEL, "#8f8682", LAMP_RING)]
    reds = [THEME.rgb(s) for s in ("red.dark", "#b52d31", "red", "red.light")]
    t = bayer(4)
    screws = [(cx + (r + 4) * math.cos(math.radians(a)), cy + (r + 4) * math.sin(math.radians(a)))
              for a in (-90, 30, 150)]
    for py in range(int(cy - bezel) - 1, int(cy + bezel) + 2):
        for px in range(int(cx - bezel) - 1, int(cx + bezel) + 2):
            dx, dy = px + 0.5 - cx, py + 0.5 - cy
            d = math.hypot(dx, dy)
            if d >= bezel:
                continue
            th = t[py % 4][px % 4]
            lit = -(dx + dy) / (d * math.sqrt(2)) if d else 0.0
            if d >= bezel - 1:
                col = THEME.rgb("#060606")
            elif d >= r + 1:
                level = (0.5 + 0.5 * lit) * 0.9 + 0.05
                if d < r + 2:
                    level = 0.35 - 0.3 * lit
                k = level * (len(shades) - 2) + 1
                i = min(int(k), len(shades) - 2)
                col = shades[i + 1] if k - i > th else shades[i]
                if any(math.hypot(px + 0.5 - sx, py + 0.5 - sy) < 1.6 for sx, sy in screws):
                    near = min(screws, key=lambda s: math.hypot(px + 0.5 - s[0], py + 0.5 - s[1]))
                    col = shades[3] if (px + 0.5 < near[0] and py + 0.5 < near[1]) else shades[0]
            elif d >= r:
                col = shades[0]
            else:
                q = d / r
                level = min(2.0, 2.0 - 1.5 * q ** 1.6 + 0.25 * lit * q)
                if any(abs(q - ring) < 0.5 / r for ring in (0.38, 0.62, 0.84)):
                    level -= 0.55
                k = max(0.0, min(level, len(reds) - 1.001))
                i = int(k)
                col = reds[i + 1] if k - i > th else reds[i]
                ang = math.degrees(math.atan2(dy, dx))
                if 0.5 < q < 0.72 and -160 < ang < -115:
                    col = reds[3]
            c.px(px, py, col)
    return Rect(int(cx - bezel), int(cy - bezel), 2 * bezel, 2 * bezel)


def cta_card(c, end_line, *, cta=True, lamp_y=168):
    """The end card: the end line at the top, the lamp lit in the middle, its light warming the page
    around it and falling off into the dark, and DOWNLOAD FREE / REDLAMP.APP under it once `cta` is on,
    all inside the safe area. It has no header, so the lamp is the picture's one red light."""
    c.glow(c.w / 2, lamp_y, 120, "#2a0e12", amount=0.9, levels=4)
    c.glow(c.w / 2, lamp_y, 52, "red.dark", amount=0.35, levels=3)
    lamp(c, c.w / 2, lamp_y)
    caption(c, end_line)
    if cta:
        for line, y in zip(END_CARD, (lamp_y + 44, lamp_y + 64)):
            c.text(c.w // 2, y, line, "white", font="large", scale=2, align="center")
        c.claim(Rect(0, lamp_y + 42, c.w, 38), "call to action")


def fade(c, p, color="shadow"):
    """The picture fading out through an ordered dither, adding no colours: the share p is gone."""
    if p > 0:
        c.dissolve(min(1.0, p), color)
