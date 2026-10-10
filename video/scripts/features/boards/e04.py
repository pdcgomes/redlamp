"""
E04, Lightroom shortcuts, in the series' look (boards/e01.py): Lightroom Classic's keyboard shortcuts,
panel order and slider names, working in Redlamp, with no pointer anywhere. The editor is drawn as
E01's dashboard is: the owner's photo of a man in a green shirt in the photo panel as pixel art, its
histogram and level under it, and a keyboard panel with the four keys the video presses, R, K,
backslash and V, each going down on its bar's first beat as its words come up. R brings up the crop
frame, K the brush's ring, backslash shows the photo before and, pressed again, after, and V turns it
black and white; a card for each shows what the tool brings with it, as Lightroom's does: the crop's
overlays, the brush's settings, the before and after split, and the treatment. The result is the
editor's panels in Lightroom's order down the side of the photo, each with the keys that open it, then
its shortcut list as dashboard panels, with the four keys lit among them.

The photo is the owner's DSC03301 (2).jpg (in ~/src/redlamp-social/photos), labelled as the raw it
would be from his Sony, DSC03301.ARW, cropped to each panel and reduced to pixel art with a palette of
its own colours. Every picture of it is Redlamp's render (features/results.py): his photo as Redlamp
opens it is the edit; BEFORE stands in for the raw as opened, rendered flatter, lighter and duller; and
the black and white is Redlamp's Black & White treatment, on a ramp of its own greys. The panels' names
and keys are the app's (PanelID, ShortcutAction), the shortcut list's entries are the README's Keyboard
shortcuts table's, and the count is the README's (Workspace), read from it.
"""

import math
import re
from functools import cache
from pathlib import Path
from typing import NamedTuple

import numpy as np
from PIL import Image

from features import results
from features import world as w
from pixelkit.art import oklab

EPISODE = w.episode("e04")
FEATURE = "LIGHTROOM SHORTCUTS"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC03301 (2).jpg"
FILE = "DSC03301.ARW"
FOLDER = w.VIDEO / "public/features/e04/results"
CUE = w.CUE

# The README's count of Lightroom Classic's shortcuts in Redlamp (Workspace): its actions, and the key
# bindings they're on, which are the shortcuts the video counts.
ACTIONS, BINDINGS = map(int, re.search(r"keyboard shortcuts\*\*: (\d+) actions on (\d+) key bindings",
                                       (w.REPO / "README.md").read_text()).groups())
# BEFORE stands in for the raw as opened: his edit rendered flatter, lighter and with less colour.
BEFORE_SETS = (("basic.exposure", 0.35), ("basic.contrast", -50), ("basic.shadows", 35), ("basic.blacks", 30),
               ("basic.saturation", -40))
MONO = {"version": 3, "treatment": "blackAndWhite"}
PHOTO = ("THE OWNER'S DSC03301 (2).JPG (THE MAN IN THE GREEN SHIRT), LABELLED AS ITS RAW, DSC03301.ARW, AS PIXEL ART "
         "WITH ITS OWN PALETTE. EVERY PICTURE IS REDLAMP'S RENDER: THE EDIT IS THE PHOTO AS REDLAMP OPENS IT; BEFORE "
         "STANDS IN FOR THE RAW AS OPENED (EXPOSURE +0.35, CONTRAST -50, SHADOWS +35, BLACKS +30, SATURATION -40); THE "
         f"BLACK AND WHITE IS REDLAMP'S BLACK & WHITE TREATMENT. {BINDINGS} SHORTCUTS: THE README'S {ACTIONS} ACTIONS "
         f"ON {BINDINGS} KEY BINDINGS")

PHOTO_PANEL = w.Rect(4, 106, 208, 128)
HIST = w.Rect(4, 236, 208, 12)
KEYBOARD = w.Rect(4, 250, 178, 38)
LEVEL = w.Rect(190, 252, 18, 34)
EDITOR = (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16)
# Bar 6, as the Develop module lays it out: the photo down the stage's left, and down its right the
# histogram over the panels, each 16 rows tall.
SIDE_PHOTO = w.Rect(4, 106, 100, 182)
SIDE = (SIDE_PHOTO.w - 8, SIDE_PHOTO.h - 16)
COLUMN = w.Rect(108, 106, 104, 182)
SIDE_HIST = w.Rect(COLUMN.x, COLUMN.y, COLUMN.w, 20)
ROW = 18
# The cards come up over the dark wall at the photo's left, clear of his face.
CARD = w.Rect(9, 122, 58, 48)
KEYCAP = 22
# Words keep left of the apps' side buttons, which cover the stage's right edge.
READ_RIGHT = 202
TITLE = w.wrapped(EPISODE["title"].upper())


# ---------------------------------------------------------------- the photo

FULL = Image.open(SOURCE).size
# Where the photo panel's crop starts, in the photo's rows: through the top of his hair, so his chin and
# the green shirt's shoulder fit in; and where the side panel's starts, in its columns.
TOP, LEFT = 290, 160


@cache
def render(state):
    """Redlamp's render of the photo at full size: as it opens ("edit"), "before", or in black and white
    ("mono")."""
    if state == "before":
        return results.render(SOURCE, FOLDER, "before", sets=BEFORE_SETS)
    if state == "mono":
        return results.render(SOURCE, FOLDER, "mono", edit=MONO)
    return results.render(SOURCE, FOLDER, "edit")


def crop(size):
    """The part of the photo a picture of `size` shows, in its pixels: across its whole width from his
    hair for a wide one, and down its whole height about him for a tall one."""
    fw, fh = FULL
    if size[0] >= size[1]:
        return 0, TOP, fw, TOP + round(fw * size[1] / size[0])
    return LEFT, 0, LEFT + round(fh * size[0] / size[1]), fh


def shot(state, size):
    return render(state).crop(crop(size)).resize(size, Image.BOX)


@cache
def palette(colors=32):
    """The photo's own colours, edited and before, at each panel's size: the centres of its pixels'
    clusters in Oklab, so the green shirt, his skin and the teal behind him keep a colour each."""
    rgb = np.concatenate([np.asarray(shot(state, size)).reshape(-1, 3) for size in (EDITOR, SIDE)
                          for state in ("edit", "before")]).astype(np.float64)
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
def greys(n=14):
    """The black and white's own greys: its tones at even steps through its pixels, at each panel's size."""
    v = np.concatenate([np.asarray(shot("mono", size))[..., 0].ravel() for size in (EDITOR, SIDE)])
    return list(dict.fromkeys((int(g),) * 3 for g in np.rint(np.quantile(v, np.linspace(0.01, 0.99, n)))))


@cache
def picture(state, size):
    """The photo at `size` in `state`, as pixel art: in its own colours, or its own greys once it's
    black and white."""
    return w.lock(shot(state, size), greys() if state == "mono" else palette(), dither=0.15).convert("RGB")


# ---------------------------------------------------------------- the keys

class Key(NamedTuple):
    """A key in the keyboard panel: its legend, its colour, and each (down, up) of its presses."""
    legend: str
    accent: str
    presses: tuple


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
# Each key goes down on its bar's first beat, as its words come up, and up an eighth later; backslash
# goes down again on the bar's third beat, back to the edit.
TAP = 0.5
R = Key("R", "gold", ((s1, s1 + TAP),))
K = Key("K", "violet", ((s2, s2 + TAP),))
BACKSLASH = Key("\\", "cyan", ((s3, s3 + TAP), (s3 + 2, s3 + 2 + TAP)))
V = Key("V", "green", ((s4, s4 + TAP),))
KEYS = [R, K, BACKSLASH, V]
CAPTIONS = [(s1, "R  CROP"), (s2, "K  BRUSH"), (s3, "\\  BEFORE / AFTER"), (s4, "V  BLACK & WHITE"),
            (CUE["result"], "SAME PANEL ORDER"), (CUE["flip"], f"{BINDINGS} SHORTCUTS")]
SHOWN, AFTER = BACKSLASH.presses[0][0], BACKSLASH.presses[1][0]
# The brush's settings, as its card shows them, and where its ring is: on his cheek. Size 50 is
# Lightroom's radius of 7.8 % of the photo's height.
BRUSH = {"SIZE": 50, "FEATHER": 50, "FLOW": 100}
CHEEK = (0.42, 0.52)
# A tool's overlay and a card come up over the frames after their key goes down.
APPEAR = 4 / w.PER_BEAT


def down(key, b):
    return any(d <= b < u for d, u in key.presses)


def bar_of(key):
    """The beats a key's bar runs over: from its first press to the next key's."""
    i = KEYS.index(key)
    return key.presses[0][0], (KEYS[i + 1].presses[0][0] if i + 1 < len(KEYS) else CUE["result"])


def state_at(b):
    """What the photo shows at beat b: the edit, before while backslash shows it, and black and white
    from V."""
    if b >= V.presses[0][0]:
        return "mono"
    return "before" if SHOWN <= b < AFTER else "edit"


def keycap_xs():
    """Where each keycap is, spread across the keyboard panel."""
    gap = 14
    x = KEYBOARD.x + (KEYBOARD.w - len(KEYS) * KEYCAP - (len(KEYS) - 1) * gap) // 2
    return [x + i * (KEYCAP + gap) for i in range(len(KEYS))]


def keyboard(c, b):
    """The keyboard panel: the four keys, the one whose bar it is ringed in its colour, sunk and ringed
    brighter while it's held."""
    p = c.panel(*KEYBOARD, "KEYBOARD", color="sky")
    y = p.y + (p.h - KEYCAP) // 2
    for key, x in zip(KEYS, keycap_xs()):
        start, end = bar_of(key)
        if start <= b < end:
            c.box(x - 2, y - 2, KEYCAP + 4, KEYCAP + 4, f"{key.accent}.light" if down(key, b) else key.accent)
        w.keycap(c, x, y, key.legend, pressed=down(key, b), size=KEYCAP, scale=2)


# ---------------------------------------------------------------- what each key does to the photo

def tool(c, r, b):
    """What the key of the bar does on the photo `r`: the crop frame, the brush's ring, the BEFORE and
    AFTER tags; each comes up as its key goes down."""
    start, end = bar_of(R)
    if start <= b < end:
        w.appear(c, w.between(b, start, start + APPEAR), lambda c: w.crop_frame(c, r))
    start, end = bar_of(K)
    if start <= b < end:
        radius = round((0.003 + 0.3 * (BRUSH["SIZE"] / 100) ** 2) * r.h)
        cx, cy = r.x + round(CHEEK[0] * r.w), r.y + round(CHEEK[1] * r.h)
        w.appear(c, w.between(b, start, start + APPEAR), lambda c: w.brush_ring(c, cx, cy, radius))
    if SHOWN <= b < s4:
        w.tag(c, r, "BEFORE" if b < AFTER else "AFTER")


# ---------------------------------------------------------------- the cards

def overlay(c, g, kind, colour):
    """One of the crop's overlays drawn small in `g`: Thirds, Grid, Diagonal or Golden Triangle."""
    c.rect(*g, "shadow")
    if kind == "THIRDS":
        for k in (1, 2):
            c.vline(g.x + round(k * g.w / 3), g.y, g.h, colour)
            c.hline(g.x, g.y + round(k * g.h / 3), g.w, colour)
    elif kind == "GRID":
        for x in range(g.x + 3, g.x2 - 1, 3):
            c.vdots(x, g.y + 1, g.h - 2, colour)
        for y in range(g.y + 3, g.y2 - 1, 3):
            c.dots(g.x + 1, y, g.w - 2, colour)
    elif kind == "DIAGONAL":
        side = g.h - 1
        for x0, x1 in ((g.x, g.x + side), (g.x2 - 1, g.x2 - 1 - side)):
            c.line(x0, g.y, x1, g.y2 - 1, colour)
            c.line(x0, g.y2 - 1, x1, g.y, colour)
    else:
        c.line(g.x, g.y2 - 1, g.x2 - 1, g.y, colour)
        c.line(g.x, g.y, g.x + 4, g.y + 6, colour)
        c.line(g.x2 - 1, g.y2 - 1, g.x2 - 5, g.y2 - 7, colour)
    c.box(*g, colour)


def overlays(c, r, b):
    """The crop's overlays, which O cycles through as in Lightroom, Thirds lit: the one on the photo."""
    for i, kind in enumerate(("THIRDS", "GRID", "DIAGONAL", "TRIANGLE")):
        g = w.Rect(r.x + (i % 2) * 26, r.y + 1 + (i // 2) * 15, 24, 13)
        overlay(c, g, kind, "gold.light" if kind == "THIRDS" else "line")


def brush(c, r, b):
    """The brush's settings as Lightroom names them, as meters, at the ring's size and feather."""
    for i, (label, value) in enumerate(BRUSH.items()):
        y = r.y + 1 + i * 10
        c.text(r.x, y, label, "text")
        t0, t1 = r.x + 31, r.x2
        c.rect(t0, y + 1, t1 - t0, 3, "shadow")
        kx = t0 + round(value / 100 * (t1 - t0 - 1))
        c.rect(t0, y + 1, kx - t0 + 1, 3, "violet")
        c.rect(kx - 1, y, 3, 5, "white")


def split(c, r, b):
    """Before and after in one picture, as Redlamp's diagonal split shows them."""
    size = (r.w, r.h - 2)
    before, after = (np.asarray(picture(state, size)) for state in ("before", "edit"))
    yy, xx = np.mgrid[0:size[1], 0:size[0]]
    edge = xx * size[1] + yy * size[0] - size[0] * size[1]
    pic = np.where((edge < 0)[..., None], before, after)
    c.img.paste(Image.fromarray(pic.astype(np.uint8)), (r.x, r.y + 1))
    c.line(r.x2 - 1, r.y + 1, r.x, r.y + size[1], "white")


def treatment(c, r, b):
    """The Basic panel's Treatment, Color until V and Black & White after it, and the photo's own
    colours turning to their greys with it."""
    mono = b >= V.presses[0][0]
    x = r.x
    for label, on in (("COLOR", not mono), ("B&W", mono)):
        wd = c.measure(label) + 6
        c.rect(x, r.y, wd, 9, "green" if on else "raised")
        c.text(x + 3, r.y + 2, label, "shadow" if on else "dim")
        x += wd + 3
    lab = oklab(np.array(palette(), dtype=np.float64))
    vivid = sorted(range(len(lab)), key=lambda k: -np.hypot(lab[k, 1], lab[k, 2]))[:6]
    for i, k in enumerate(sorted(vivid, key=lambda k: lab[k, 0])):
        c.rect(r.x + i * 8, r.y + 14, 7, 7, grey(palette()[k]) if mono else palette()[k])


def grey(rgb):
    """A colour's grey: its luminance in linear light."""
    v = np.array(rgb) / 255
    y = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4) @ [0.2126, 0.7152, 0.0722]
    return (round(255 * (y * 12.92 if y <= 0.0031308 else 1.055 * y ** (1 / 2.4) - 0.055)),) * 3


# Each card, by the key whose bar it comes up in: what the bar's words say, drawn.
CARDS = [(R, "CROP", "gold", overlays), (K, "BRUSH", "violet", brush), (BACKSLASH, "BEFORE/AFTER", "cyan", split),
         (V, "TREATMENT", "green", treatment)]


# ---------------------------------------------------------------- the dashboard

def dashboard(c, b):
    """Bars 1 to 5: the photo with what the key does to it, its histogram and level, the bar's card, and
    the keyboard."""
    w.header(c, FEATURE)
    img = picture(state_at(b), EDITOR)
    r = w.photo_panel(c, PHOTO_PANEL, img, b, FILE, horizon=None)
    tool(c, r, b)
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 2.2), "gold", seg=2, gap=1)
    for key, title, colour, body in CARDS:
        start, end = bar_of(key)
        if start <= b < end:
            def drawn(c, title=title, colour=colour, body=body):
                w.card(c, CARD.x, CARD.y, title, colour, lambda c, content: body(c, content, b), w=CARD.w, h=CARD.h)

            w.appear(c, w.between(b, start, start + APPEAR), drawn)
            if b < start + 0.5:
                c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, [f"{colour}.light", "white"],
                           seed=int(b * w.PER_BEAT))
    keyboard(c, b)
    w.caption(c, caption_at(b))
    return []


# ---------------------------------------------------------------- the result

def keys(c, x, y, legends, *, lit=None, align="left"):
    """Keys as the shortcut list shows them, side by side from x, or ending at x: each legend in the small
    font on a key 7 rows tall, in the colour `lit` for a key the video pressed. Returns their width."""
    widths = [c.measure(legend) + 4 for legend in legends]
    total = sum(widths) + len(widths) - 1
    kx = x - total if align == "right" else x
    for legend, kw in zip(legends, widths):
        c.rect(kx, y, kw, 7, lit or "line")
        c.hline(kx, y + 7, kw, f"{lit}.dark" if lit else "shadow")
        c.text(kx + 2, y + 1, legend, "shadow" if lit else "text")
        kx += kw + 1
    return total


# The Develop module's panels, in Lightroom's order (PanelID), each with the keys that open it.
PANEL_ORDER = [("BASIC", "sky"), ("TONE CURVE", "orange"), ("COLOR MIXER", "lime"), ("COLOR GRADING", "yellow"),
               ("DETAIL", "blue"), ("LENS CORRECTIONS", "purple"), ("TRANSFORM", "gold"), ("EFFECTS", "violet"),
               ("CALIBRATION", "cyan")]
# The panels come up one after another down the column over the beat from the drop.
CASCADE = 1.0


def panels(c, b):
    """The first half of bar 6: the black and white photo down the left, and down the right its histogram
    over the panels in Lightroom's order, coming up one after another, each with its keys."""
    w.header(c, FEATURE)
    img = picture("mono", SIDE)
    w.photo_panel(c, SIDE_PHOTO, img, b, FILE, horizon=None)
    w.histogram(c, img, SIDE_HIST)
    for i, (title, accent) in enumerate(PANEL_ORDER):
        y = SIDE_HIST.y2 + 2 + i * ROW
        start = CUE["result"] + CASCADE * i / len(PANEL_ORDER)

        def drawn(c, i=i, title=title, accent=accent, y=y):
            c.panel(COLUMN.x, y, COLUMN.w, ROW - 2, title, color=accent)
            keys(c, READ_RIGHT, y + 4, ["⌘", str(i + 1)], align="right")

        w.appear(c, w.between(b, start, start + 3 / w.PER_BEAT), drawn)
    w.caption(c, "SAME PANEL ORDER")


# The shortcut list: some of each area's keys, as the README's Keyboard shortcuts table names them, in
# two columns; the keys the video pressed are lit in their colours.
LIT = {key.legend: key.accent for key in KEYS}
SHEET = [
    [("VIEW", "sky", [(["\\"], "BEFORE / AFTER"), (["Z"], "FIT / 100%"), (["J"], "CLIPPING"),
                      (["I"], "INFO OVERLAY"), (["L"], "LIGHTS OUT"), (["F"], "FULL SCREEN")]),
     ("TOOLS", "orange", [(["D"], "EDIT"), (["R"], "CROP"), (["Q"], "HEALING"), (["⇧", "W"], "MASKING"),
                          (["K"], "BRUSH"), (["M"], "LINEAR GRADIENT"), (["⇧", "M"], "RADIAL GRADIENT")]),
     ("PANELS", "purple", [(["TAB"], "HIDE SIDE PANELS"), (["F6"], "FILMSTRIP"), (["⌘", "1"], "BASIC PANEL")])],
    [("DEVELOP", "lime", [(["V"], "BLACK & WHITE"), (["W"], "WHITE BALANCE"), (["⌘", "U"], "AUTO SETTINGS"),
                          (["⇧", "⌘", "C"], "COPY SETTINGS"), (["⇧", "⌘", "V"], "PASTE SETTINGS"),
                          (["⌘", "Z"], "UNDO"), (["⇧", "⌘", "Z"], "REDO"), (["⌘", "N"], "NEW SNAPSHOT")]),
     ("RATING & FLAGS", "yellow", [(["P"], "PICK"), (["X"], "REJECT"), (["U"], "UNFLAG"), (["5"], "5 STARS"),
                                   (["6"], "RED LABEL")]),
     ("FILE", "blue", [(["⇧", "⌘", "E"], "EXPORT"), (["⌘", "K"], "COMMAND PALETTE"), (["⌘", "/"], "SHORTCUTS")])],
]
LINE = 8


def shortcuts(c, b):
    """The second half of bar 6: the shortcut list across the stage, an area to a panel."""
    w.header(c, FEATURE)
    for column, areas in enumerate(SHEET):
        x, y = w.STAGE.x + column * 106, 106
        for title, accent, entries in areas:
            h = 4 + 8 + LINE * len(entries) + 2
            p = c.panel(x, y, 102, h, title, color=accent)
            for i, (legends, name) in enumerate(entries):
                lit = LIT.get(legends[0]) if len(legends) == 1 else None
                kx = p.x + keys(c, p.x, p.y + i * LINE, legends, lit=lit) + 3
                c.text(kx, p.y + 1 + i * LINE, name, "white" if lit else "text")
            y += h + 2
    w.caption(c, f"{BINDINGS} SHORTCUTS")


def result(c, b):
    """Bar 6: the panels in Lightroom's order, then the shortcut list developing in over them on the flip."""
    if b < CUE["flip"]:
        panels(c, b)
        return []
    before = w.canvas()
    panels(before, CUE["flip"] - 0.01)
    shortcuts(c, b)
    w.develop(c, before.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
    if b < CUE["flip"] + 1:
        c.sparkles(w.STAGE.x, 106, w.STAGE.w, 182, 26, ["gold.light", "white", "cyan.light"], seed=int(b * w.PER_BEAT))
    return []


def end_card(c, b):
    """Bars 7 and 8: the lamp comes on with the end line, the call to action from its cue, then the fade."""
    light = math.ceil(6 * w.ease(w.between(b, CUE["endLine"], CUE["endLine"] + 1))) / 6
    w.cta_card(c, EPISODE["endLine"], cta=b >= CUE["cta"], light=light)
    w.fade(c, w.between(b, CUE["fade"], CUE["end"]))
    return []


def caption_at(b):
    """The caption at beat b: the title held from the opener, then each key's words."""
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
    """Each sound on screen, (beat, kind, pan): every key down and up, panned with its keycap, and a tick
    as the shortcut list comes up on the flip."""
    out = []
    for key, x in zip(KEYS, keycap_xs()):
        for d, u in key.presses:
            out += [(d, "key", pan(x + KEYCAP // 2)), (u, "key up", pan(x + KEYCAP // 2))]
    out.append((CUE["flip"], "flip", 0.0))
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(TITLE),
            "A deep hit, and the music turns to F sharp minor: a choir and a plucked string over a kick muffled "
            "as if through a wall. His photo as edited, and the keyboard panel's R, K, backslash and V."),
    w.Panel(2, 2.4, at(s1 + 1.5), CAPTIONS[0][1],
            "A key down for R on the bar's first beat strikes the riff's first note; the bass and a half-time "
            "beat come in. The crop frame, and the CROP card's overlays."),
    w.Panel(3, 4.8, at(s2 + 1.5), CAPTIONS[1][1],
            "A key down for K on the riff's second bar, and the hats double. The brush's ring, and its size, "
            "feather and flow on the BRUSH card."),
    w.Panel(4, 7.2, at(s3 + 1.2), CAPTIONS[2][1],
            "The full beat; a key down for backslash on the bar's first beat shows before, and again on its "
            "third, after, each on a note of the riff's answer."),
    w.Panel(5, 9.6, at(s4 + 1.5), CAPTIONS[3][1],
            "A key down for V on the beat and the photo turns black and white; claps roll into the stop, the "
            "riff's G sharp held through it."),
    w.Panel(6, 12.0, at(CUE["flip"] - 0.6), "SAME PANEL ORDER, then " + CAPTIONS[5][1] + " at 13.2 s",
            "The drop and the sting as the panels come up in order; a tick as the shortcut list comes up."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
