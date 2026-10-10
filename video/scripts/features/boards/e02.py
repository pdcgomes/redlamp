"""
E02, Subject mask: the person selected in one click by an AI mask that runs on the Mac, the mask
inverted to select the background, and the background darkened so the subject stands out. The editor
opens the owner's son at a colour run; the pointer clicks SUBJECT in the Masks panel and the red
overlay covers him, hair included; INVERT moves it to the background; the mask's Exposure goes down
and the background darkens; then the real photo and the end card.

The photo is the owner's IMG_3557.jpg (in ~/src/redlamp-social/photos), cropped to 4:5 about the boy.
The overlay is the Subject mask Apple Vision's foreground model makes for the photo, the request
Redlamp's Subject mask runs (VisionMasks.swift), stored below at 192 × 256. The darkened background
is a drawing in the pixel photo only. The real photo is shown as it is, as the before; the after,
Redlamp's render of the darkened background, is still to come, so the result shows a placeholder for
it. The mask's Exposure stands in until that edit is made.
"""

import base64
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e02")
FEATURE = "SUBJECT MASK"
SOURCE = Path.home() / "src/redlamp-social/photos/IMG_3557.jpg"
PHOTO = ("THE OWNER'S IMG_3557.JPG (THE BOY AT THE COLOUR RUN), CROPPED TO 4:5, IN EVERY EDITOR PANEL AND AS THE "
         "BEFORE IN BAR 6. THE OVERLAY IS APPLE VISION'S SUBJECT MASK FOR IT; THE DARKENED BACKGROUND IN BAR 5 IS A "
         "DRAWING. TO COME FROM REDLAMP: THE AFTER IN BAR 6 (THE BACKGROUND DARKENED) AND THE MASK'S EXPOSURE, "
         "WHICH STANDS IN UNTIL THEN")
FILE = "IMG_3557.JPG"
# A 4:5 crop about the boy, in the photo's own pixels.
BOX = (150, 200, 1510, 1900)
FULL = Image.open(SOURCE).convert("RGB")
BEFORE = FULL.crop(BOX)
ASPECT = 4 / 5
PANEL = 58

AI_MASKS = ["SUBJECT", "SKY", "BACKGROUND", "PEOPLE"]
# The mask's Exposure, and the slider's reach either side of zero (ParameterSpec's localExposure).
EXPOSURE, REACH = -1.00, 4

# VNGenerateForegroundInstanceMaskRequest's mask for the whole photo, 192 × 256, a bit a pixel, packed
# and compressed.
SUBJECT = (
    "eNrt1ktyhCAUBVApBw7NMDOX4tJkIVkMS2EJDBkQXvoT2w/3qi/VpiqVZnhKeXKRT1W92qu92j9s75i7D+x9xj4IZCMiDnh9cfRG"
    "c3VJhbc3L9/o7u6IR+JFR73gjsbnA/FIPBHPShdL3Cndn+NjbuuAmA+Cg2M+8jpQpZuH51O8fric7fYMb37u7ojX+25/0w3JWev7"
    "85VP8Yb85/seiXviljjcnrnnCvdz0Guy3JkbpVdk+2Fu9jwo3ZO6zB1xq/TyGN/0RPwNn6flXYF5t3nuR6UHcq9g7pXunuT2sLfE"
    "e3wtMnjWx/XFrkueTG+s8LLLFVnulpzunuyqkewmGV8qVgUmXhSYHUaLArNuFgVk3iza4xfRtQsP5VVp9UsPCxdcdipgVh7g50wF"
    "mpVn+JnTyDrBhQv3ZWrzSAtPcLiPD2IuRYMxjAMA7oh7FNuGBxTnhkcY83cQzLvSs9IFxr/hFsW/4Q5OC3fP3SAPMH7uEcbPPcH4"
    "uWccM3XBMXO3MOarQ74ETdxg90oPSo/MybgSySHh/C9BkwIVKcAngE1YS7whXhM3Gk/EycJIeB+7rTtD1jvz+o94o3D7RF//D59K"
    "TzveneXD3fun+Bdpni1q"
)
MASK = Image.fromarray(
    np.unpackbits(np.frombuffer(zlib.decompress(base64.b64decode(SUBJECT)), np.uint8)).reshape(256, 192) * 255
).resize(FULL.size, Image.BILINEAR).crop(BOX)


def darken(img, mask, ev):
    """`img` with `ev` stops of exposure where `mask` is clear, in linear light: a drawing of the
    inverted mask's edit, for the pixel photo only."""
    small = (img.width // 4, img.height // 4)
    a = np.asarray(img.resize(small, Image.BOX), dtype=np.float64) / 255
    m = np.asarray(mask.resize(small, Image.BILINEAR), dtype=np.float64)[..., None] / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** (ev * (1 - m))
    v = np.clip(lin, 0, 1)
    v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.rint(v * 255).astype(np.uint8))


DARK = darken(BEFORE, MASK, EXPOSURE)


def photo_palette(images, colors=40):
    """A palette taken from the photos themselves, with the editor's greys, so the grass, the powder
    colours and the sunglasses keep their own colours in the pixel photo."""
    tiles = [img.resize((96, 120), Image.BOX) for img in images]
    sheet = Image.new("RGB", (96 * len(tiles), 120))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (96 * i, 0))
    flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[:3 * colors]
    found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    return list(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))


PALETTE = photo_palette([BEFORE, DARK])

_cache = {}


def pixel(img, size):
    """`img` as a pixel photo at `size`, locked to PALETTE."""
    key = (id(img), size)
    if key not in _cache:
        _cache[key] = w.lock(w.fit(img, *size, Image.BOX), PALETTE, dither=0.4).convert("RGB")
    return _cache[key]


def subject(size):
    """The mask at the photo's size, as the overlay shows it: set where the pixel is mostly the boy."""
    return np.asarray(w.fit(MASK, *size, Image.BOX)) >= 128


def edit(c, photo, *, pressed=None, chosen=False, inverted=False, exposure=None, active=False, press=None,
         show=True):
    """The editor with `photo` (BEFORE or DARK) and the Masks panel: the AI masks, SUBJECT pressed or
    chosen, then the mask's INVERT and Exposure once it exists. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(photo, size) if show else None, file=FILE, aspect=ASPECT, panel=PANEL)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "MASKS", right="AI MASKS")
    x, at = p.x, {}
    for label in AI_MASKS:
        r = w.button(c, x, y, label, pressed=pressed == label, selected=chosen and label == "SUBJECT")
        at[label] = r
        x = r.x2 + 3
    if chosen:
        r = w.button(c, p.x, y + 14, "INVERT", pressed=pressed == "INVERT", selected=inverted)
        at["INVERT"] = r
        note = "MASK 1 · SUBJECT, INVERTED" if inverted else "MASK 1 · SUBJECT"
        c.text(r.x2 + 6, y + 16, note, w.GREY["dim"])
    if exposure is not None:
        value = "0.00" if exposure == 0 else f"{exposure:+.2f}"
        at["EXPOSURE"] = w.slider(c, p.x, y + 29, p.w, "EXPOSURE", value, 0.5 + exposure / (2 * REACH),
                                  active=active)
    if press in ("SUBJECT", "INVERT"):
        r = at[press]
        w.pointer(c, r.x2 - 5, r.y + 3, pressed=True)
    elif press:
        w.pointer(c, *at[press], pressed=True)
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
        c.text(r.cx, top + 7 * i, line, w.GREY["label"] if i < 2 else w.GREY["dim"], align="center")
    w.tag(c, r, mark)


def pair(ed):
    """Two frames the photo's size side by side on the canvas, centred left of the side buttons."""
    ph, gap = ed.photo, 4
    x = ed.canvas.x + (w.READ_RIGHT - ed.canvas.x - (2 * ph.w + gap)) // 2
    return w.Rect(x, ph.y, ph.w, ph.h), w.Rect(x + ph.w + gap, ph.y, ph.w, ph.h)


def hook(c):
    edit(c, BEFORE)
    w.caption(c, EPISODE["hooks"]["a"])


def click(c):
    edit(c, BEFORE, pressed="SUBJECT", press="SUBJECT")
    w.caption(c, "CLICK SUBJECT")


def selected(c):
    ed = edit(c, BEFORE, chosen=True, exposure=0)
    w.mask_overlay(c, ed.photo, subject(ed.photo[2:]))
    w.caption(c, ["HE IS SELECTED,", "HAIR INCLUDED"])


def invert(c):
    ed = edit(c, BEFORE, chosen=True, inverted=True, pressed="INVERT", exposure=0, press="INVERT")
    w.mask_overlay(c, ed.photo, ~subject(ed.photo[2:]))
    w.caption(c, ["INVERT IT FOR", "THE BACKGROUND"])


def darker(c):
    edit(c, DARK, chosen=True, inverted=True, exposure=EXPOSURE, active=True, press="EXPOSURE")
    w.caption(c, ["DARKEN THE", "BACKGROUND"])


def result(c, progress=1.0):
    """The before and after side by side: the owner's photo, resolving out of the pixel one, at the
    left, and Redlamp's render of the darkened background still to come at the right."""
    ed = edit(c, DARK, chosen=True, inverted=True, exposure=EXPOSURE, show=False)
    before, after = pair(ed)
    c.img.paste(pixel(BEFORE, (before.w, before.h)), (before.x, before.y))
    pixels = np.asarray(c.img)[before.y:before.y2, before.x:before.x2].copy()
    w.tag(c, before, "BEFORE")
    placeholder(c, after, ["BACKGROUND", "DARKENED", "", "REDLAMP'S", "RENDER", "GOES HERE"], "AFTER")
    w.caption(c, w.REAL_PHOTO)
    return [w.Overlay(before, BEFORE, pixels, progress)]


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, click, "CLICK SUBJECT", "The motif starts; a click on the beat."),
    w.Panel(3, 4.8, selected, "HE IS SELECTED, / HAIR INCLUDED", "A soft rising blip as the overlay fills."),
    w.Panel(4, 7.2, invert, "INVERT IT FOR / THE BACKGROUND", "A click; the drums come in."),
    w.Panel(5, 9.6, darker, "DARKEN THE / BACKGROUND", "Slider ticks on the beats of the drag; the motif's answer."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO) + "; before, then after at 13.2 s",
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
