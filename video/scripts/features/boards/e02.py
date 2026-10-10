"""
E02, Subject mask, in the series' look (boards/e01.py): the person selected in one click by an AI mask
that runs on the Mac, the mask inverted to select the background, and the background darkened so the
subject stands out. The editor is drawn as E01's dashboard is: the owner's photo of his son at a colour
run in the photo panel as pixel art, its histogram and level under it, and the Masks panel below, with
the four AI masks in their accents and the chosen mask's Invert and Exposure. The pointer clicks
SUBJECT and the editor's red overlay fills up the boy, hair included; INVERT moves it to the
background; the mask's Exposure goes down and the background darkens. What each bar says comes up as a
card: the model on the Mac with nothing to download, the hair's edge magnified under the overlay, the
mask's thumbnail turning over, and the background's level falling while his stays. The result is the
photo before and after, in pixel art.

The photo is the owner's IMG_3557.jpg (in ~/src/redlamp-social/photos), cropped about the boy to each
panel's shape and reduced to pixel art with a palette of its own colours. The editor labels it as the
raw it would be from his iPhone, IMG_3557.DNG, since Redlamp is a raw editor (the owner, 10 October 2026). The overlay is the Subject
mask Apple Vision's foreground model makes for the photo, the request Redlamp's Subject mask runs
(VisionMasks.swift), stored below at 192 × 256. The darkened background is the mask's Exposure applied
to the photo in linear light, a drawing of the inverted mask's edit.
"""

import base64
import math
import zlib
from functools import cache
from pathlib import Path
from typing import NamedTuple

import numpy as np
from PIL import Image

from features import world as w
from pixelkit.art import oklab

EPISODE = w.episode("e02")
FEATURE = "SUBJECT MASK"
SOURCE = Path.home() / "src/redlamp-social/photos/IMG_3557.jpg"
FILE = "IMG_3557.DNG"
PHOTO = ("THE OWNER'S IMG_3557.JPG (THE BOY AT THE COLOUR RUN), LABELLED AS ITS RAW, IMG_3557.DNG, AS PIXEL ART WITH ITS "
         "OWN PALETTE, CROPPED ABOUT HIM. "
         "THE OVERLAY IS APPLE VISION'S SUBJECT MASK FOR IT; THE DARKENED BACKGROUND IS THE MASK'S EXPOSURE (-1.00) "
         "APPLIED TO THE PHOTO IN LINEAR LIGHT")
CUE = w.CUE

PHOTO_PANEL = w.Rect(4, 106, 208, 128)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 236, 208, 12)
MASKS = w.Rect(4, 250, 178, 36)
LEVEL = w.Rect(190, 252, 18, 32)
EDITOR = (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16)
RESULT = (RESULT_PANEL.w - 8, RESULT_PANEL.h - 16)
# The cards come up over the park at the photo's left, clear of the boy.
CARD = w.Rect(10, 124, 64, 50)
# Each AI mask's accent, as the kit gives each channel one; red is the overlay's alone.
AI_MASKS = {"SUBJECT": "cyan", "SKY": "sky", "BACKGROUND": "green", "PEOPLE": "violet"}
# The mask's Exposure, and the slider's reach either side of zero (ParameterSpec's localExposure).
EXPOSURE, REACH = -1.00, 4
TITLE = w.wrapped(EPISODE["title"].upper())
CAPTION_RESULT = "BEFORE AND AFTER"


class Click(NamedTuple):
    """The pointer presses a button on `press` and lets go on `release`."""
    button: str
    press: float
    release: float


class Drag(NamedTuple):
    """The pointer presses the Exposure knob on `press`, moves it a step on each of `ticks`, the last at
    the edit's value, and lets go on `release`."""
    press: float
    ticks: tuple
    release: float


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
# The pointer comes in from the right with the first step's words and clicks SUBJECT two beats later;
# with the third step's words it moves down to INVERT and clicks it on the next beat.
ENTER = s1
CLICKS = [Click("SUBJECT", s1 + 2, s1 + 2.5), Click("INVERT", s3 + 1, s3 + 1.5)]
CLICK_SUBJECT, CLICK_INVERT = CLICKS
DRAG = Drag(s4, (s4 + 1, s4 + 2, s4 + 3), s4 + 3.5)
# The overlay fills up the boy from his shirt to the top of his hair in three sixteenths from the second
# step's cue, so the fill sound's four notes land as it starts, a third and two thirds of the way, and
# as it reaches his hair.
FILL = (s2, s2 + 0.75)
# A knob's step eases in over the frames before its tick and lands on it; the overlay turns from the boy
# to the background over the frames after INVERT's click, and the thumbnail turns over in twice that.
EASE = 3 / w.PER_BEAT
TURN = 4 / w.PER_BEAT
CAPTIONS = [(s1, "CLICK SUBJECT"), (s2, ["SELECTED", "ACCURATELY"]), (s3, ["INVERT IT FOR", "THE BACKGROUND"]),
            (s4, ["DARKEN THE", "BACKGROUND"]), (CUE["result"], CAPTION_RESULT)]


# ---------------------------------------------------------------- the photo

FULL = Image.open(SOURCE).convert("RGB")
# The top of his hair and the bottom of his chin, in the photo's rows.
HAIR, CHIN = 336, 1130
# VNGenerateForegroundInstanceMaskRequest's mask for the whole photo, 192 × 256, a bit a pixel, packed
# and compressed.
VISION = (
    "eNrt1ktyhCAUBVApBw7NMDOX4tJkIVkMS2EJDBkQXvoT2w/3qi/VpiqVZnhKeXKRT1W92qu92j9s75i7D+x9xj4IZCMiDnh9cfRG"
    "c3VJhbc3L9/o7u6IR+JFR73gjsbnA/FIPBHPShdL3Cndn+NjbuuAmA+Cg2M+8jpQpZuH51O8fric7fYMb37u7ojX+25/0w3JWev7"
    "85VP8Yb85/seiXviljjcnrnnCvdz0Guy3JkbpVdk+2Fu9jwo3ZO6zB1xq/TyGN/0RPwNn6flXYF5t3nuR6UHcq9g7pXunuT2sLfE"
    "e3wtMnjWx/XFrkueTG+s8LLLFVnulpzunuyqkewmGV8qVgUmXhSYHUaLArNuFgVk3iza4xfRtQsP5VVp9UsPCxdcdipgVh7g50wF"
    "mpVn+JnTyDrBhQv3ZWrzSAtPcLiPD2IuRYMxjAMA7oh7FNuGBxTnhkcY83cQzLvSs9IFxr/hFsW/4Q5OC3fP3SAPMH7uEcbPPcH4"
    "uWccM3XBMXO3MOarQ74ETdxg90oPSo/MybgSySHh/C9BkwIVKcAngE1YS7whXhM3Gk/EycJIeB+7rTtD1jvz+o94o3D7RF//D59K"
    "TzveneXD3fun+Bdpni1q"
)
MASK = Image.fromarray(
    np.unpackbits(np.frombuffer(zlib.decompress(base64.b64decode(VISION)), np.uint8)).reshape(256, 192) * 255
).resize(FULL.size, Image.BILINEAR)
# The EDGE card shows the hair's edge at three times the photo panel's size, from the photo's own pixels:
# where his hair meets the trees at the left of his head, its left and top in them.
ZOOM, LOUPE_AT = 3, (566, 396)


def crop(size):
    """The part of the photo a picture of `size` shows, in its pixels: its whole width, from a little
    above his hair, keeping his chin."""
    h = round(FULL.width * size[1] / size[0])
    top = HAIR - min(70, (h - (CHIN - HAIR)) * 45 // 100)
    return 0, top, FULL.width, top + h


def loupe():
    """The part of the photo the EDGE card shows, in its pixels."""
    x0, top, x1, _ = crop(EDITOR)
    scale = (x1 - x0) / EDITOR[0] / ZOOM
    x, y = LOUPE_AT
    return x, y, x + round((CARD.w - 8) * scale), y + round((CARD.h - 16) * scale)


def developed(img, mask, size, ev):
    """`img` at `size` with `ev` stops of exposure where the inverted `mask` selects it, in linear light:
    a drawing of the mask's edit, before it's pixel art."""
    a = np.asarray(img.resize(size, Image.BOX), dtype=np.float64) / 255
    m = np.asarray(mask.resize(size, Image.BOX), dtype=np.float64)[..., None] / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** (ev * (1 - m))
    v = np.clip(lin, 0, 1)
    v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.rint(v * 255).astype(np.uint8))


@cache
def palette(colors=32):
    """The photo's own colours, as it opens and with the edit, at each panel's size: the centres of its
    pixels' clusters in Oklab, so its small bright parts, the lenses' rainbow and the frame's cyan, keep
    a colour each."""
    shots = [developed(FULL.crop(crop(size)), MASK.crop(crop(size)), size, ev) for size in (EDITOR, RESULT)
             for ev in (0, EXPOSURE)]
    rgb = np.concatenate([np.asarray(img).reshape(-1, 3) for img in shots]).astype(np.float64)
    lab = oklab(rgb)

    def nearest(centres):
        return ((lab**2).sum(1)[:, None] - 2 * lab @ centres.T + (centres**2).sum(1)[None]).argmin(1)

    rng = np.random.default_rng(3)
    centres = lab[[rng.integers(len(lab))]]
    far = ((lab - centres[0]) ** 2).sum(1)
    while len(centres) < colors:
        centres = np.vstack([centres, lab[rng.choice(len(lab), p=far / far.sum())]])
        far = np.minimum(far, ((lab - centres[-1]) ** 2).sum(1))
    for _ in range(20):
        near = nearest(centres)
        centres = np.array([lab[near == k].mean(0) if (near == k).any() else centres[k] for k in range(colors)])
    near = nearest(centres)
    return list(dict.fromkeys(tuple(int(v) for v in np.rint(rgb[near == k].mean(0))) for k in range(colors)
                              if (near == k).any()))


@cache
def picture(ev, size):
    """The photo at `size`, cropped about the boy, with `ev` stops on the background, as pixel art."""
    box = crop(size)
    return w.lock(developed(FULL.crop(box), MASK.crop(box), size, ev), palette(), dither=0.15).convert("RGB")


@cache
def subject(size):
    """Where the mask selects the boy in a picture of `size`: the pixels mostly his."""
    return np.asarray(MASK.crop(crop(size)).resize(size, Image.BOX)) >= 128


@cache
def magnified():
    """The EDGE card's view of the hair, as pixel art, and where the mask selects him in it."""
    box, size = loupe(), (CARD.w - 8, CARD.h - 16)
    view = w.lock(FULL.crop(box).resize(size, Image.BOX), palette(), dither=0.15).convert("RGB")
    return view, np.asarray(MASK.crop(box).resize(size, Image.BOX)) >= 128


# ---------------------------------------------------------------- the clicks and the drag

def steps_done(b):
    """How many of the drag's steps have landed by beat b, with the next one's share as it eases in."""
    k = sum(1 for t in DRAG.ticks if t <= b)
    if k < len(DRAG.ticks) and b > DRAG.ticks[k] - EASE:
        return k, w.ease((b - DRAG.ticks[k] + EASE) / EASE)
    return k, 0.0


def exposure_at(b):
    """The mask's Exposure at beat b, as its knob shows it."""
    k, part = steps_done(b)
    return EXPOSURE * (k + part) / len(DRAG.ticks)


def developed_at(b):
    """The Exposure the photo shows at beat b: it follows each tick."""
    return EXPOSURE * steps_done(b)[0] / len(DRAG.ticks)


def value_text(v):
    return "0.00" if round(v, 2) == 0 else f"{v:+.2f}"


def chosen(b):
    return b >= CLICK_SUBJECT.press


def inverted(b):
    return b >= CLICK_INVERT.press


def pressed(button, b):
    return any(click.button == button and click.press <= b < click.release for click in CLICKS)


def level(b):
    """How far up the overlay has filled at beat b, as a row of the photo panel's photo: from under its
    bottom row to his hair's top row over the fill."""
    top = int(np.argmax(subject(EDITOR).any(axis=1)))
    return EDITOR[1] - (EDITOR[1] - top) * w.between(b, *FILL)


def _chips():
    """Where the Masks panel's buttons are: the AI masks in a row under its title, INVERT under them."""
    small = w.FONTS["small"]
    out, x = {}, MASKS.x + 4
    for label in AI_MASKS:
        out[label] = w.Rect(x, MASKS.y + 12, small.measure(label) + 8, 9)
        x = out[label].x2 + 3
    out["INVERT"] = w.Rect(MASKS.x + 4, MASKS.y + 24, small.measure("INVERT") + 8, 9)
    return out


CHIPS = _chips()
# The mask's Exposure, beside INVERT: its name, the meter, and its value at the panel's right.
LABEL_X = CHIPS["INVERT"].x2 + 6
TRACK = (LABEL_X + w.FONTS["small"].measure("EXPOSURE") + 5, MASKS.x2 - 4 - w.FONTS["small"].measure("-1.00") - 5)


def knob(v):
    """Where the Exposure meter's knob is at value v."""
    t0, t1 = TRACK
    return round(t0 + (0.5 + v / (2 * REACH)) * (t1 - t0)), CHIPS["INVERT"].y + 4


def target(button):
    """Where the pointer's tip goes to click a button: low at its right, so it doesn't hide the label."""
    r = CHIPS[button]
    return r.x2 - 5, r.y + 6


def pointer_at(b):
    """Where the pointer's tip is at beat b and whether it's pressed, or None while it's off screen: it
    comes in from the right with the first step's words, clicks SUBJECT, moves down to INVERT and clicks
    it, then glides to the Exposure knob on the beat before the drag, moves with it and lets go."""
    if b < ENTER:
        return None

    def glide(a, z, t):
        return round(a[0] + (z[0] - a[0]) * t), round(a[1] + (z[1] - a[1]) * t)

    subject_at, invert_at = target("SUBJECT"), target("INVERT")
    if b < CLICK_SUBJECT.press:
        return glide((w.W + 6, MASKS.y + 20), subject_at, w.ease(w.between(b, ENTER, CLICK_SUBJECT.press))), False
    if b < s3:
        return subject_at, b < CLICK_SUBJECT.release
    if b < CLICK_INVERT.press:
        return glide(subject_at, invert_at, w.ease(w.between(b, s3, CLICK_INVERT.press))), False
    if b < DRAG.press - 1:
        return invert_at, b < CLICK_INVERT.release
    if b < DRAG.press:
        return glide(invert_at, knob(0), w.ease(w.between(b, DRAG.press - 1, DRAG.press))), False
    return knob(exposure_at(b)), b < DRAG.release


# ---------------------------------------------------------------- the cards

def model(c, r, b):
    """The model on the Mac, with nothing to download: a chip whose cores run from SUBJECT's click until
    the overlay fills."""
    c.chip(r.x + 1, r.y + 1, 16, 16, "AI", "cyan")
    running = CLICK_SUBJECT.press <= b < FILL[0]
    for i in range(4):
        on = b >= FILL[0] or running and int((b - CLICK_SUBJECT.press) * 4) % 4 == i
        c.rect(r.x + 3 + 3 * i, r.y + 13, 2, 2, "cyan.light" if on else "raised")
    c.text(r.x + 22, r.y + 2, "DOWNLOAD", "dim")
    c.text(r.x + 22, r.y + 10, "0 B", "white", font="large")
    c.text(r.cx, r.y + 26, "ON YOUR MAC", "text", align="center")


def zoom_box(r):
    """Where the EDGE card's view is on the photo panel's photo `r`."""
    x0, top, x1, _ = crop(EDITOR)
    scale = (x1 - x0) / r.w
    lx0, ly0, lx1, ly1 = loupe()
    return w.Rect(r.x + round((lx0 - x0) / scale), r.y + round((ly0 - top) / scale), round((lx1 - lx0) / scale),
                  round((ly1 - ly0) / scale))


def edge(c, r, b):
    """The hair's edge three times the size, under the overlay as it fills, row for row with the photo's."""
    view, mask = magnified()
    c.img.paste(view, (r.x, r.y))
    x0, top, x1, _ = crop(EDITOR)
    rows = loupe()[1] + (np.arange(r.h)[:, None] + 0.5) * (x1 - x0) / EDITOR[0] / ZOOM
    w.mask_overlay(c, r, mask & ((rows - top) / ((x1 - x0) / EDITOR[0]) >= level(b)))


def thumbnail(c, r, b):
    """The mask's thumbnail, as the Masks panel lists it, white where it selects, turning over on INVERT's
    click to the background, with what it selects under it."""
    size = (36, 20)
    mask = np.asarray(MASK.crop(crop(EDITOR)).resize(size, Image.BOX)) >= 128
    t = w.between(b, CLICK_INVERT.press, CLICK_INVERT.press + 2 * TURN)
    turned = t >= 0.5
    width = max(1, round(size[0] * abs(1 - 2 * t)))
    cells = np.where(~mask if turned else mask, 1, 0)[:, np.arange(width) * size[0] // width]
    x, y = r.cx - width // 2, r.y + 1
    c.rect(x - 1, y - 1, width + 2, size[1] + 2, "line")
    for j, row in enumerate(cells):
        for i, on in enumerate(row):
            c.px(x + i, y + j, "white" if on else "shadow")
    label, colour = ("BACKGROUND", "green") if turned else ("SUBJECT", "cyan")
    c.text(r.cx, r.y + 26, label, colour, align="center")


def levels(c, r, b):
    """How bright the background and the boy are in the photo as it is, as LED rows: the background's
    falls with each tick of the drag while his stays."""
    img = np.asarray(picture(developed_at(b), EDITOR), dtype=np.float64) / 255
    luma = img @ [0.2126, 0.7152, 0.0722]
    mask = subject(EDITOR)
    n = (r.w + 1) // 3
    for i, (label, colour, share) in enumerate((("BACKGROUND", "green", luma[~mask].mean()),
                                                ("SUBJECT", "cyan", luma[mask].mean()))):
        y = r.y + 1 + i * 17
        c.text(r.x, y, label, colour)
        lit = round(min(1.0, share * 2) * n)
        for k in range(n):
            c.rect(r.x + 3 * k, y + 8, 2, 4, colour if k < lit else "raised")


# Each card, from the beat it comes up on to the beat it goes: what the bar's words say, drawn.
CARDS = [(s1, s2, "AI MODEL", "cyan", model), (s2, s3, "EDGE ×3", "orange", edge),
         (s3, s4, "INVERT", "green", thumbnail), (s4, CUE["result"], "LEVEL", "gold", levels)]


# ---------------------------------------------------------------- the dashboard

def chip(c, r, label, colour, state):
    """A button as the dashboards draw one: its label in its accent on a dark key, lit in the accent with
    dark ink once on, sunk a row while pressed, and dim while there's nothing for it to do."""
    if state == "on":
        c.rect(*r, colour)
        c.hline(r.x, r.y, r.w, f"{colour}.light")
        c.hline(r.x, r.y2 - 1, r.w, f"{colour}.dark")
        ink = "shadow"
    elif state == "pressed":
        c.rect(*r, f"{colour}.dark")
        ink = f"{colour}.light"
    else:
        c.rect(*r, "raised")
        c.hline(r.x, r.y2 - 1, r.w, "shadow")
        ink = "dim" if state == "dim" else colour
    c.text(r.x + 4, r.y + 2 + (state == "pressed"), label, ink)


def masks(c, b):
    """The Masks panel: the AI masks, SUBJECT pressed and then on, and the mask's INVERT and Exposure,
    dim until there's a mask, the meter lit while it's dragged."""
    made = chosen(b)
    c.panel(*MASKS, "MASKS", color="sky", right="1 MASK" if made else "NO MASKS", right_color="dim")
    for label, colour in AI_MASKS.items():
        on = label == "SUBJECT" and b >= CLICK_SUBJECT.release
        chip(c, CHIPS[label], label, colour, "pressed" if pressed(label, b) else "on" if on else "off")
    state = "pressed" if pressed("INVERT", b) else "on" if inverted(b) else "off" if made else "dim"
    chip(c, CHIPS["INVERT"], "INVERT", "green", state)
    v, lit = exposure_at(b), DRAG.press <= b < DRAG.release
    y, (t0, t1) = CHIPS["INVERT"].y + 2, TRACK
    if lit:
        c.rect(LABEL_X - 2, y - 2, MASKS.x2 - 2 - LABEL_X, 10, "raised")
    c.text(LABEL_X, y, "EXPOSURE", "white" if lit else "gold" if made else "dim")
    c.rect(t0, y + 1, t1 - t0, 3, "shadow")
    mid, kx = knob(0)[0], knob(v)[0]
    lo, hi = sorted((mid, kx))
    if made:
        c.rect(lo, y + 1, hi - lo + 1, 3, "gold.light" if lit else "gold")
    c.vline(mid, y, 5, "dim")
    c.rect(kx - 1, y - 1, 3, 7, "white" if made else "dim")
    c.text(MASKS.x2 - 4, y, value_text(v), "white" if made else "dim", align="right")


def overlay(c, r, b):
    """The editor's red overlay on the photo `r` at beat b: filling up the boy from his shirt to his hair,
    a lighter row leading, on him until INVERT is clicked, then turning to the background, and gone from
    the Exposure knob's press, so the drag's edit shows."""
    mask = subject(EDITOR)
    if b < FILL[0] or b >= DRAG.press:
        return
    if b < FILL[1]:
        row = level(b)
        w.mask_overlay(c, r, mask & (np.arange(r.h)[:, None] >= row))
        lead = math.floor(row)
        if 0 <= lead < r.h:
            for x in np.flatnonzero(mask[lead]):
                c.px(r.x + int(x), r.y + lead, "red.light")
        return
    turn = w.between(b, CLICK_INVERT.press, CLICK_INVERT.press + TURN)
    order = w.bayer(8)[(r.y + np.arange(r.h))[:, None] % 8, (r.x + np.arange(r.w))[None, :] % 8]
    w.mask_overlay(c, r, np.where(order < turn, ~mask, mask) if inverted(b) else mask)


def dashboard(c, b):
    """Bars 1 to 5: the photo with the overlay, its histogram and level, the Masks panel with the pointer,
    and the bar's card."""
    w.header(c, FEATURE)
    img = picture(developed_at(b), EDITOR)
    r = w.photo_panel(c, PHOTO_PANEL, img, b, FILE, horizon=None)
    overlay(c, r, b)
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 2.2), "gold", seg=2, gap=1)
    for start, end, title, colour, body in CARDS:
        if start <= b < end:
            def drawn(c, title=title, colour=colour, body=body):
                if body is edge:
                    box = zoom_box(r)
                    c.box(*box, "orange.light")
                    c.hline(CARD.x2, box.cy, box.x - CARD.x2, "orange.light")
                w.card(c, CARD.x, CARD.y, title, colour, lambda c, content: body(c, content, b), w=CARD.w, h=CARD.h)

            w.appear(c, w.between(b, start, start + 6 / w.PER_BEAT), drawn)
            if b < start + 0.5:
                c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, [f"{colour}.light", "white"],
                           seed=int(b * w.PER_BEAT))
    masks(c, b)
    at = pointer_at(b)
    if at:
        w.pointer(c, *at[0], pressed=at[1])
    w.caption(c, caption_at(b))
    return []


def result(c, b):
    """Bar 6: the photo fills the stage, as opened, then developing into the edit on the flip."""
    w.header(c, FEATURE)
    before = picture(0, RESULT)
    if b < CUE["flip"]:
        w.photo_panel(c, RESULT_PANEL, before, b, FILE, right="BEFORE", right_color="text", horizon=None)
    else:
        flat = w.canvas()
        w.header(flat, FEATURE)
        w.photo_panel(flat, RESULT_PANEL, before, b, FILE, right="BEFORE", right_color="text", horizon=None)
        r = w.photo_panel(c, RESULT_PANEL, picture(EXPOSURE, RESULT), b, FILE, right="AFTER", right_color="gold",
                          horizon=None)
        w.develop(c, flat.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
        if b < CUE["flip"] + 1:
            c.sparkles(r.x, r.y, r.w, r.h, 26, ["gold.light", "white", "orange.light"], seed=int(b * w.PER_BEAT))
    w.caption(c, CAPTION_RESULT)
    return []


def end_card(c, b):
    """Bars 7 and 8: the lamp comes on with the end line, the call to action from its cue, then the fade."""
    light = math.ceil(6 * w.ease(w.between(b, CUE["endLine"], CUE["endLine"] + 1))) / 6
    w.cta_card(c, EPISODE["endLine"], cta=b >= CUE["cta"], light=light)
    w.fade(c, w.between(b, CUE["fade"], CUE["end"]))
    return []


def caption_at(b):
    """The caption at beat b: the title held from the opener, then each step's words."""
    lines = TITLE
    for start, words in CAPTIONS:
        if b >= start:
            lines = words
    return lines


def frame(c, b, hook="a"):
    """The picture at beat b, drawn on c; the hook is the opener's. All pixel art, so no overlays."""
    if b < CUE["result"]:
        return dashboard(c, b)
    if b < CUE["endLine"]:
        return result(c, b)
    return end_card(c, b)


# ---------------------------------------------------------------- its sounds

def pan(x):
    return round((x / w.W - 0.5) * 0.8, 2)


def sounds():
    """Each sound on screen, (beat, kind, pan): a click on SUBJECT and on INVERT, panned with the button,
    a rising run as the overlay fills, a press, a tick a step and a release for the Exposure drag, panned
    with its knob, and a tick on the flip to after."""
    out = []
    for click in CLICKS:
        x = CHIPS[click.button].cx
        out += [(click.press, "press", pan(x)), (click.release, "release", pan(x))]
    out.append((FILL[0], "fill", pan(PHOTO_PANEL.cx)))
    out.append((DRAG.press, "press", pan(knob(0)[0])))
    for k, t in enumerate(DRAG.ticks, 1):
        out.append((t, "tick", pan(knob(EXPOSURE * k / len(DRAG.ticks))[0])))
    out += [(DRAG.release, "release", pan(knob(EXPOSURE)[0])), (CUE["flip"], "flip", 0.0)]
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(TITLE),
            "A deep hit, then the arpeggio over a kick muffled as if through a wall. The photo and the Masks panel."),
    w.Panel(2, 2.4, at(CLICK_SUBJECT.press + 0.25), "CLICK SUBJECT",
            "The riff starts; the pointer comes in and a click lands two beats later on SUBJECT; the AI MODEL card's "
            "chip runs."),
    w.Panel(3, 4.8, at(s2 + 1.5), " / ".join(CAPTIONS[1][1]),
            "A soft run of four blips rising as the overlay fills up the boy to his hair; the EDGE card magnifies it."),
    w.Panel(4, 7.2, at(CLICK_INVERT.press + 1), " / ".join(CAPTIONS[2][1]),
            "The riff's answer and the full beat; a click on INVERT a beat in, and the INVERT card's mask turns over."),
    w.Panel(5, 9.6, at(s4 + 3.2), " / ".join(CAPTIONS[3][1]),
            "A click as the Exposure knob is pressed and a tick a beat as it goes down; toms fall into the stop."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), CAPTION_RESULT + "; before, then after at 13.2 s",
            "The drop and the sting; a tick and a burst of sparkles as the photo develops on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
