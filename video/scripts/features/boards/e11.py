"""
E11, Command palette, in the series' look (boards/e01.py): every action and Develop slider from the
keyboard, with no pointer anywhere. The editor is drawn as E01's dashboard is: a pixel-art tulip field
in the photo panel, developed live by the sliders the keys set, its histogram and level under it, and
the Basic panel's meters, which give way to a keyboard panel showing each bar's keys as they go down.
Command and K open the palette over the photo: its search field, then pickers, sliders with their
values and actions with their shortcuts. E, X and P narrow it to Exposure above the actions that
match; Return shrinks it to the slider bar, where Shift and the right arrow step Exposure up and the
field brightens; the down arrow moves the bar to Contrast, 20 is typed and Return sets it, and a card
shows the run of presses kept as one history step. The result is the field before and after.

The palette's rows are the app's (packages/RedlampUI/Sources/CommandPalette): with nothing typed it
shows a few of the pickers, Basic sliders and actions, in the order the palette lists them; what each
letter finds is the first four rows PaletteCatalog ranks for it; and the slider bar's neighbours and
hints are PaletteSliderBar's. Exposure steps 0.05 a press, too little to see here, so Shift is held for
its ten-times step of 0.50.
"""

import math
from typing import NamedTuple

import numpy as np

from features import world as w

EPISODE = w.episode("e11")
FEATURE = "COMMAND PALETTE"
FILE = "TULIPS.NEF"
PHOTO = ("NO PHOTO: A PIXEL-ART TULIP FIELD STANDS IN FOR IT, DEVELOPED BY THE TWO SLIDERS AT THE VALUES SET FROM "
         "THE KEYBOARD (EXPOSURE +1.50 IN THREE STEPS OF SHIFT AND THE RIGHT ARROW, CONTRAST +20 TYPED)")
CUE = w.CUE

PHOTO_PANEL = w.Rect(4, 106, 208, 120)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 228, 208, 12)
BOTTOM = w.Rect(4, 242, 178, 46)
LEVEL = w.Rect(190, 246, 18, 38)
EDITOR = (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16)
RESULT = (RESULT_PANEL.w - 8, RESULT_PANEL.h - 16)
TRACK = (52, 140)
# The palette and the slider bar float over the top of the photo, left of the apps' side buttons.
FLOAT = w.Rect(12, 121, 168, 29)
ROW = 9
CARD = w.Rect(12, 166, 80, 36)
KEYCAP = 25
TITLE = w.wrapped(EPISODE["title"].upper())
CAPTION_RESULT = ["ALL FROM THE", "KEYBOARD"]


# ---------------------------------------------------------------- the photo

def lin(h):
    """A colour in linear light, from its hex."""
    v = np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)]) / 255
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


SKY = [(0.0, "#1b56c2"), (0.6, "#4a90e6"), (1.0, "#a9d3f5")]
HORIZON = 0.47
# Where the rows meet on the horizon, as a share of the width; each colour's band is this wide, in
# the ground's own units, and holds two rows of tulips.
VANISH, BAND = 0.36, 0.75
TULIPS = ["#ff0f2a", "#ffd000", "#8a1fe0", "#fff6ea", "#ff6a00", "#ff2b95"]
LEAF = "#1f5c1c"
# Each cloud: its middle, a share of the width, its flat base, a share of the height, and its puffs,
# (x, y, radius) from there in shares of the height, so it keeps its shape in any frame.
CLOUDS = [(0.2, 0.22, [(-0.11, -0.02, 0.035), (-0.06, -0.045, 0.055), (0.0, -0.07, 0.07), (0.07, -0.045, 0.055),
                       (0.12, -0.02, 0.035)]),
          (0.56, 0.12, [(-0.06, -0.012, 0.025), (-0.025, -0.032, 0.04), (0.02, -0.028, 0.035), (0.055, -0.01, 0.02)])]
# The windmill's foot, its tower's height and its sails' reach, in shares of the height.
MILL, TOWER, SAIL = (0.76, HORIZON + 0.02), 0.25, 0.19


def tulips(width, height):
    """A tulip field in spring as the eye saw it, in linear light: bands of red, yellow, purple, white,
    orange and pink tulips running to the horizon, a windmill beyond them, and a blue sky with clouds."""
    x = (np.arange(width) + 0.5) / width
    y = (np.arange(height) + 0.5) / height
    X, Y = np.meshgrid(x, y)
    aspect = width / height
    img = np.zeros((height, width, 3))
    stops = [s for s, _ in SKY]
    cols = np.array([lin(c) for _, c in SKY])
    for k in range(3):
        img[..., k] = np.interp(np.clip(Y / HORIZON, 0, 1), stops, cols[:, k])
    for middle, base, puffs in CLOUDS:
        cloud = np.zeros((height, width), bool)
        for dx, dy, r in puffs:
            cloud |= np.hypot((X - middle) * aspect - dx, Y - base - dy) < r
        cloud &= Y < base
        under = np.clip((Y - base + 0.06) / 0.06, 0, 1)[cloud][:, None]
        img[cloud] = lin("#ffffff") * (1 - under) + lin("#9fb6d8") * under

    treetops = HORIZON - 0.03 - 0.012 * np.sin(x * 47 + 1) - 0.01 * np.sin(x * 19)
    img[(Y > treetops[None, :]) & (Y <= HORIZON + 0.01)] = lin("#24502a")
    ground = Y > HORIZON + 0.01
    d = np.maximum(Y - HORIZON, 1e-3)
    u = (X - VANISH) * aspect / d / BAND
    tulip = np.array([lin(c) for c in TULIPS])
    colour = tulip[np.floor(u).astype(int) % len(TULIPS)]
    # Far off, where a band is only a few pixels wide, its rows and then its colours blend, so they
    # don't break up into noise.
    band = d * height / np.hypot(1 / BAND, u)
    blend, rows = np.clip((2.5 - band) / 2, 0, 1)[..., None], np.clip((5 - band) / 3, 0, 1)[..., None]
    colour = colour * (1 - blend) + tulip.mean(0) * blend
    planted = np.where(((u * 2) % 1 < 0.8)[..., None], colour, lin(LEAF))
    field = planted * (1 - rows) + (colour * 0.8 + lin(LEAF) * 0.2) * rows
    haze = np.exp(-d / 0.05)[..., None] * 0.55
    img[ground] = (field * (1 - haze) + lin(SKY[-1][1]) * haze)[ground]

    mx, foot = MILL
    top = foot - TOWER
    half = 0.036 + (0.022 - 0.036) * np.clip((foot - Y) / TOWER, 0, 1)
    off = (X - mx) * aspect
    tower = (np.abs(off) < half) & (Y > top) & (Y < foot)
    img[tower] = np.where((off < -half * 0.2)[tower][:, None], lin("#6b4f3a"), lin("#3e2c22"))
    door = (np.abs(off) < 0.009) & (Y > foot - 0.035) & (Y < foot)
    img[door] = lin("#1a120d")
    cap = (np.hypot(off / 0.032, (Y - top) / 0.026) < 1) & (Y <= top + 0.004)
    img[cap] = lin("#2a1d17")
    hub = top + 0.004
    for angle in (35, 125, 215, 305):
        a = math.radians(angle)
        along = off * math.cos(a) + (Y - hub) * math.sin(a)
        across = -off * math.sin(a) + (Y - hub) * math.cos(a)
        blade = (along > 0.012) & (along < SAIL) & (np.abs(across) < 0.012)
        lattice = (np.abs(across) < 0.0035) | ((along * 34) % 1 < 0.28)
        img[blade] = np.where(lattice[blade][:, None], lin("#5a4030"), lin("#efe6d6"))
    return img


def picture(values, size):
    return w.scene(tulips, values, size, TARGET)


# ---------------------------------------------------------------- the keys

class Key(NamedTuple):
    """A key in the keyboard panel: its legend and each (down, up) of its presses."""
    legend: str
    presses: tuple


# A key tapped comes up a sixteenth after it goes down.
TAP = 0.25


def tap(legend, *beats):
    return Key(legend, tuple((b, b + TAP) for b in beats))


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
# Command goes down a beat after the words that ask for it and K on the next, which opens the palette;
# K comes up first. E, X and P are typed a beat apart from the third bar's first beat. Return on the
# fourth bar's first beat shrinks the palette to the slider bar, Shift goes down half a beat later and
# the right arrow steps on each of the next three beats. The down arrow on the fifth bar's first beat
# moves to Contrast, then 2, 0 and Return a beat apart.
COMMAND, K = Key("⌘", ((s1 + 1, s1 + 3.5),)), Key("K", ((s1 + 2, s1 + 3.25),))
TYPED = [tap(letter, s2 + i) for i, letter in enumerate("EXP")]
RETURN, SHIFT, RIGHT = tap("↵", s3), Key("⇧", ((s3 + 0.5, s3 + 3.5),)), tap("→", s3 + 1, s3 + 2, s3 + 3)
DOWN, TWO, ZERO, SET = tap("↓", s4), tap("2", s4 + 1), tap("0", s4 + 2), tap("↵", s4 + 3)
BARS = [(s1, [COMMAND, K]), (s2, TYPED), (s3, [RETURN, SHIFT, RIGHT]), (s4, [DOWN, TWO, ZERO, SET])]
OPEN, ADJUST, NEXT, SET_AT = K.presses[0][0], RETURN.presses[0][0], DOWN.presses[0][0], SET.presses[0][0]
# The palette unrolls over the frames after K and shrinks over those after Return; the slider bar
# turns to Contrast over the frames after the down arrow.
UNROLL, SHRINK, TURN = 6 / w.PER_BEAT, 6 / w.PER_BEAT, 4 / w.PER_BEAT
# Exposure's step with Shift held, ten times its 0.05 (ParameterSpec); Contrast's value as typed.
STEP, CONTRAST = 0.5, 20
TARGET = {"EXPOSURE": STEP * len(RIGHT.presses), "CONTRAST": CONTRAST}
CAPTIONS = [(s1, "PRESS COMMAND K"), (s2, ["EVERY SLIDER", "AND ACTION"]), (s3, ["STEP IT WITH", "THE ARROW KEYS"]),
            (s4, ["NEXT SLIDER,", "TYPE A VALUE"]), (CUE["result"], CAPTION_RESULT)]


def down(key, b):
    return any(d <= b < u for d, u in key.presses)


def shown(key, b):
    return b >= key.presses[0][0]


def values_at(b):
    """Each slider's value at beat b, as the keys have set it: the photo follows each press."""
    exposure = STEP * sum(1 for d, _ in RIGHT.presses if d <= b)
    return {k: v for k, v in (("EXPOSURE", exposure), ("CONTRAST", CONTRAST if b >= SET_AT else 0)) if v}


def query_at(b):
    """What's typed in the palette's search at beat b."""
    return "".join(k.legend for k in TYPED if shown(k, b))


def typed_at(b):
    """What's typed in the slider bar at beat b, until Return sets it."""
    return "" if b >= SET_AT else "".join(k.legend for k in (TWO, ZERO) if shown(k, b))


# ---------------------------------------------------------------- the palette

class Row(NamedTuple):
    """A row of the palette: what it is (a picker, a slider or an action), its title, and what's at its
    right: a slider's value or an action's keys; a picker has a chevron."""
    kind: str
    title: str
    right: object = None


PICKER, SLIDER, ACTION = "picker", "slider", "action"
# Each kind's accent, and each slider's own, as the kit gives each channel one.
KINDS = {PICKER: "green", SLIDER: "orange", ACTION: "violet"}
ACCENT = {"EXPOSURE": "gold", "CONTRAST": "cyan", "HIGHLIGHTS": "violet"}
# What ↵ does to the selected row, as the palette's hint says it (PaletteItemKind.verb).
VERBS = {PICKER: "OPEN", SLIDER: "ADJUST", ACTION: "RUN"}
EXPOSURE = Row(SLIDER, "EXPOSURE", "0.00")
CALIBRATE = Row(ACTION, "CALIBRATE FROM TARGET", ())
EXPORT = Row(ACTION, "EXPORT…", ("⇧", "⌘", "E"))
BROWSING = [Row(PICKER, "WHITE BALANCE"), Row(PICKER, "TREATMENT"), EXPOSURE, Row(SLIDER, "CONTRAST", "0"),
            Row(ACTION, "BEFORE / AFTER", ("\\",)), EXPORT]
# The first four rows each query finds, as PaletteCatalog ranks them: sliders above actions, each in
# the catalogue's order. CYCLE INFO OVERLAY is found by its keyword "exif", CALIBRATE FROM TARGET by
# "exposure".
FOUND = {
    "E": [EXPOSURE, Row(SLIDER, "SHARPENING MASKING", "0"), Row(SLIDER, "VIGNETTE AMOUNT", "0"),
          Row(SLIDER, "VIGNETTE MIDPOINT", "50")],
    "EX": [EXPOSURE, Row(ACTION, "CYCLE INFO OVERLAY", ("I",)), CALIBRATE, EXPORT],
    "EXP": [EXPOSURE, CALIBRATE, EXPORT, Row(ACTION, "EXPORT WITH PREVIOUS", ("⌥", "⇧", "⌘", "E"))],
}
PLACEHOLDER = "SEARCH COMMANDS, SLIDERS AND LOOKS…"
MAGNIFIER = [".###...", "#...#..", "#...#..", "#...#..", ".###...", "....#..", ".....#."]


def keys(c, x, y, legends, *, lit=None, align="left"):
    """Keys as the palette shows a shortcut, side by side from x, or ending at x: each legend in the small
    font on a key 8 rows tall, in the accent `lit` while it's held. Returns their width."""
    widths = [c.measure(legend) + 4 for legend in legends]
    total = sum(widths) + len(widths) - 1 if widths else 0
    kx = x - total if align == "right" else x
    for legend, kw in zip(legends, widths):
        c.rect(kx, y, kw, 7, lit or "line")
        c.hline(kx, y + 7, kw, f"{lit}.dark" if lit else "shadow")
        c.text(kx + 2, y + 1, legend, "shadow" if lit else "text")
        kx += kw + 1
    return total


def hints(c, x, y, items, *, lit=None):
    """The palette's hints, ending at x: each a dim label and its keys, its label in the accent `lit`
    while it applies. `items` is (label, legends, applies)."""
    for label, legends, applies in reversed(items):
        x -= keys(c, x, y, legends, lit=lit if applies else None, align="right") + 2
        x -= c.text(x, y + 1, label, lit if applies else "dim", align="right") + 6


def field(c, r, query, b):
    """The search field: the magnifier, what's typed in the large font, or the placeholder, and the caret,
    on for the first half of each beat, when the keys go down."""
    c.rect(*r, "shadow")
    c.box(*r, "sky")
    c.sprite(r.x + 3, r.y + 3, MAGNIFIER, {"#": "sky"})
    if query:
        caret = r.x + 13 + c.text(r.x + 13, r.y + 3, query, "white", font="large") + 2
    else:
        c.text(r.x + 15, r.y + 4, PLACEHOLDER, "dim")
        caret = r.x + 13
    if b % 1 < 0.5:
        c.vline(caret, r.y + 2, 9, "sky")


def row(c, x, y, wd, item, selected):
    """A row: its kind's swatch, its title, and its value, keys or chevron at the right; the selected one
    raised with the system accent at its edge."""
    colour = ACCENT.get(item.title, KINDS[item.kind])
    if selected:
        c.rect(x - 3, y, wd + 6, ROW, "raised")
        c.vline(x - 3, y, ROW, "sky")
    c.rect(x, y + 3, 3, 3, colour)
    c.text(x + 6, y + 2, item.title, "white" if selected else "text")
    if item.kind == SLIDER:
        c.text(x + wd, y + 2, item.right, "white", align="right")
    elif item.kind == PICKER:
        c.text(x + wd, y + 2, ">", colour, align="right")
    else:
        keys(c, x + wd, y + 1, item.right, align="right")


def rows_at(b):
    """The palette's rows at beat b: what the query finds, or with nothing typed, its browsing list."""
    query = query_at(b)
    return FOUND[query] if query else BROWSING


def palette_rect(rows):
    return w.Rect(FLOAT.x, FLOAT.y, FLOAT.w, 36 + ROW * len(rows))


def palette(c, b):
    """The palette over the photo: the search field, the rows the query finds or, with nothing typed,
    some of what it lists (pickers, sliders with their values, actions with their keys), the first
    selected, and the hints under them, ↵'s lit while it's down."""
    rows = rows_at(b)
    r = palette_rect(rows)
    c.rect(r.x + 2, r.y + 2, r.w, r.h, "shadow")
    c.panel(*r)
    field(c, w.Rect(r.x + 4, r.y + 4, r.w - 8, 13), query_at(b), b)
    for i, item in enumerate(rows):
        row(c, r.x + 7, r.y + 20 + i * ROW, r.w - 14, item, i == 0)
    y = r.y + 22 + len(rows) * ROW
    c.hline(r.x + 1, y, r.w - 2, "line")
    hints(c, r.x2 - 5, y + 3, [(VERBS[rows[0].kind], ["↵"], down(RETURN, b)), ("CLOSE", ["ESC"], False)],
          lit="sky")


def unrolled(c, r, p, draw):
    """Draws `draw(c)` over `r`, keeping only its top share p, never less than its search field, and
    closing its border under it: the palette unrolling as it opens, or rolling up into the slider bar."""
    before = c.img.copy()
    draw(c)
    cut = r.y + max(18, round(r.h * p))
    if cut < r.y2:
        c.img.paste(before.crop((r.x, cut, r.x2 + 2, r.y2 + 2)), (r.x, cut))
        c.hline(r.x, cut - 1, r.w, "line")
        c.rect(r.x + 2, cut, r.w, 2, "shadow")


def crossed(c, p, old, new):
    """Draws `new(c)` developed in to the share p over what `old` draws, which goes on a copy of the
    canvas so its words don't meet the new ones: the palette turning into the slider bar, and the bar
    into the next slider."""
    if p >= 1:
        new(c)
        return
    scratch = w.canvas()
    scratch.img.paste(c.img)
    old(scratch)
    new(c)
    w.develop(c, scratch.img, p)


# ---------------------------------------------------------------- the slider bar

class Slider(NamedTuple):
    label: str
    reach: float
    above: str
    below: str


# The Basic panel's sliders the video shows, how far each reaches either side of zero (ParameterSpec),
# and the sliders either side of it, which ↑ and ↓ move the slider bar to.
EXPOSURE_BAR = Slider("EXPOSURE", 5, "TINT", "CONTRAST")
CONTRAST_BAR = Slider("CONTRAST", 100, "EXPOSURE", "HIGHLIGHTS")
HIGHLIGHTS = Slider("HIGHLIGHTS", 100, "CONTRAST", "SHADOWS")


def value_text(slider, v):
    if slider.reach < 10:
        return "0.00" if round(v, 2) == 0 else f"{v:+.2f}"
    return "0" if round(v) == 0 else f"{v:+.0f}"


def meter_x(slider, v):
    """Where the slider bar's knob is at value v."""
    t0, t1 = bar_track()
    return round(t0 + (0.5 + v / (2 * slider.reach)) * (t1 - t0))


def bar_track():
    """Where the slider bar's meter runs, between its ← and → keys, clear of the longest name."""
    x = FLOAT.x + 5 + w.FONTS["small"].measure("CONTRAST") + 5 + 8 + 3
    return x, x + 60


def slider_bar(c, b, slider):
    """The palette shrunk to one slider over the photo: its name, ← and → about its meter, lit while
    pressed, and its value; the sliders above and below it, and what's typed; the hints under it."""
    r, accent = FLOAT, ACCENT[slider.label]
    v = values_at(b).get(slider.label, 0)
    typed = typed_at(b) if slider is CONTRAST_BAR else ""
    c.rect(r.x + 2, r.y + 2, r.w, r.h, "shadow")
    c.panel(*r)
    y = r.y + 5
    c.text(r.x + 5, y + 1, slider.label, accent)
    t0, t1 = bar_track()
    keys(c, t0 - 3 - 8, y, ["←"])
    keys(c, t1 + 3, y, ["→"], lit=accent if down(RIGHT, b) and slider is EXPOSURE_BAR else None)
    c.rect(t0, y + 3, t1 - t0, 3, "shadow")
    mid, kx = round((t0 + t1) / 2), meter_x(slider, v)
    lo, hi = sorted((mid, kx))
    c.rect(lo, y + 3, hi - lo + 1, 3, accent)
    c.vline(mid, y + 2, 5, "dim")
    c.rect(kx - 1, y + 1, 3, 7, "white")
    c.text(r.x2 - 5, y, value_text(slider, v), "white", font="large", align="right")
    y += 11
    x = r.x + 5
    for legend, name, pressed in (("↑", slider.above, False),
                                  ("↓", slider.below, down(DOWN, b) and slider is EXPOSURE_BAR)):
        x += keys(c, x, y, [legend], lit="sky" if pressed else None) + 3
        x += c.text(x, y + 1, name, "text") + 7
    if typed:
        caret = r.x2 - 6
        c.text(caret - 2, y, typed, "white", font="large", align="right")
        c.vline(caret, y - 1, 9, "sky")
    else:
        c.text(r.x2 - 5, y + 1, "TYPE A VALUE", "dim", align="right")
    capsule = w.Rect(r.x, r.y2 + 2, 96, 12)
    c.rect(*capsule, "panel")
    c.box(*capsule, "line")
    hints(c, capsule.x2 - 4, capsule.y + 2, [("×10", ["⇧"], down(SHIFT, b)), ("FINE", ["⌥"], False),
                                              ("SET" if typed else "DONE", ["↵"], bool(typed))], lit=accent)


# ---------------------------------------------------------------- the card

def history(c, r):
    """The run of presses kept as one history step: the three steps of → equal one step, Exposure's."""
    x = r.x + keys(c, r.x, r.y, ["→", "→", "→"], lit="gold") + 4
    x += c.text(x, r.y + 1, "=", "text") + 4
    c.text(x, r.y, "1 STEP", "white", font="large")
    c.text(r.x, r.y + 13, "EXPOSURE", "gold")
    c.text(r.x2, r.y + 13, value_text(EXPOSURE_BAR, TARGET["EXPOSURE"]), "white", align="right")


# ---------------------------------------------------------------- the dashboard

def bar_keys(b):
    """The keys of the bar beat b is in."""
    keys_ = []
    for start, bar in BARS:
        if b >= start:
            keys_ = bar
    return keys_


def keycap_xs(bar):
    """Where each of a bar's keycaps is, centred in the keyboard panel."""
    width = len(bar) * KEYCAP + (len(bar) - 1) * 4
    x = BOTTOM.x + BOTTOM.w // 2 - width // 2
    return [x + i * (KEYCAP + 4) for i in range(len(bar))]


def keyboard(c, b):
    """The keyboard panel, in the Basic panel's place from the moment ⌘ goes down: the bar's keys as
    they come, each sunk and ringed in the panel's accent while it's held."""
    p = c.panel(*BOTTOM, "KEYBOARD", color="violet")
    bar = bar_keys(b)
    y = p.y + (p.h - KEYCAP) // 2
    for key, x in zip(bar, keycap_xs(bar)):
        if shown(key, b):
            if down(key, b):
                c.box(x - 2, y - 2, KEYCAP + 4, KEYCAP + 4, "violet.light")
            w.keycap(c, x, y, key.legend, pressed=down(key, b), size=KEYCAP, scale=2)


def basic(c):
    """The Basic panel's first tone sliders as meters at zero, the two the keys will set among them."""
    sliders = (EXPOSURE_BAR, CONTRAST_BAR, HIGHLIGHTS)
    w.meters(c, BOTTOM, [(s.label, ACCENT[s.label], value_text(s, 0), 0.5, False) for s in sliders], track=TRACK)


def dashboard(c, b):
    """Bars 1 to 5: the photo, its histogram, its level, the palette or the slider bar over the photo,
    the keyboard in the Basic panel's place, and the history card."""
    w.header(c, FEATURE)
    img = picture(values_at(b), EDITOR)
    w.photo_panel(c, PHOTO_PANEL, img, b, FILE, horizon=None)
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 2.2), "gold", seg=2, gap=1)
    if OPEN <= b < ADJUST:
        r = palette_rect(rows_at(b))
        unrolled(c, r, w.ease(w.between(b, OPEN, OPEN + UNROLL)), lambda c: palette(c, b))
        if b < OPEN + 0.5:
            c.sparkles(r.x - 2, r.y - 2, r.w + 4, r.h + 4, 10, ["sky.light", "white"], seed=int(b * w.PER_BEAT))
    elif ADJUST <= b < NEXT:
        shrink = w.ease(w.between(b, ADJUST, ADJUST + SHRINK))
        r = palette_rect(rows_at(b))
        crossed(c, shrink, lambda c: unrolled(c, r, 1 - (1 - FLOAT.h / r.h) * shrink, lambda c: palette(c, b)),
                lambda c: slider_bar(c, b, EXPOSURE_BAR))
    elif b >= NEXT:
        crossed(c, w.between(b, NEXT, NEXT + TURN), lambda c: slider_bar(c, b, EXPOSURE_BAR),
                lambda c: slider_bar(c, b, CONTRAST_BAR))
    if b >= NEXT:
        w.appear(c, w.between(b, NEXT, NEXT + 6 / w.PER_BEAT),
                 lambda c: w.card(c, CARD.x, CARD.y, "HISTORY", "orange", history, w=CARD.w, h=CARD.h))
        if b < NEXT + 0.5:
            c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, ["orange.light", "white"],
                       seed=int(b * w.PER_BEAT))
    if shown(COMMAND, b):
        keyboard(c, b)
    else:
        basic(c)
    w.caption(c, caption_at(b))
    return []


def result(c, b):
    """Bar 6: the photo fills the stage, as opened, then developing into the edit on the flip."""
    w.header(c, FEATURE)
    if b < CUE["flip"]:
        w.photo_panel(c, RESULT_PANEL, picture({}, RESULT), b, FILE, right="BEFORE", right_color="text", horizon=None)
    else:
        flat = w.canvas()
        w.header(flat, FEATURE)
        w.photo_panel(flat, RESULT_PANEL, picture({}, RESULT), b, FILE, right="BEFORE", right_color="text",
                      horizon=None)
        r = w.photo_panel(c, RESULT_PANEL, picture(TARGET, RESULT), b, FILE, right="AFTER", right_color="gold",
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
    """Each sound on screen, (beat, kind, pan): every key down and up, panned with its keycap, air rising
    as the palette unrolls and falling as it rolls up into the slider bar, a tick for each step of
    Exposure and as Return sets Contrast, panned with the knob, and a tick on the flip to after."""
    out = []
    for _, bar in BARS:
        for key, x in zip(bar, keycap_xs(bar)):
            for d, u in key.presses:
                out += [(d, "key", pan(x + KEYCAP // 2)), (u, "key up", pan(x + KEYCAP // 2))]
    out += [(OPEN, "unroll", pan(FLOAT.x + FLOAT.w // 2)), (ADJUST, "roll up", pan(FLOAT.x + FLOAT.w // 2))]
    for k, (d, _) in enumerate(RIGHT.presses, 1):
        out.append((d, "tick", pan(meter_x(EXPOSURE_BAR, STEP * k))))
    out += [(SET_AT, "tick", pan(meter_x(CONTRAST_BAR, CONTRAST))), (CUE["flip"], "flip", 0.0)]
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(TITLE),
            "A deep hit, then the track's first bar. The tulip field as opened, its histogram and level, and the "
            "Basic panel's Exposure, Contrast and Highlights at zero."),
    w.Panel(2, 2.4, at(s1 + 3.2), CAPTIONS[0][1],
            "The riff starts; a key down for ⌘ a beat in and for K on the next, and air rising as the palette "
            "unrolls; K up, then ⌘, in the bar's last beat."),
    w.Panel(3, 4.8, at(s2 + 2.1), " / ".join(CAPTIONS[1][1]),
            "A key down and up for E, X and P, a beat apart from the bar's first beat; the list narrows with each."),
    w.Panel(4, 7.2, at(s3 + 3.2), " / ".join(CAPTIONS[2][1]),
            "The full beat comes in; a key for ↵ on the bar's first beat and air falling as the palette rolls up, "
            "⇧ down half a beat later, and a key and a slider tick for each → a beat apart."),
    w.Panel(5, 9.6, at(s4 + 3.2), " / ".join(CAPTIONS[3][1]),
            "A key for ↓, 2, 0 and ↵ a beat apart, and a tick as ↵ sets Contrast; toms fall into the stop, and the "
            "riff's E flat holds through it."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), " / ".join(CAPTION_RESULT) + "; before, then after at 13.2 s",
            "The drop and the sting; a tick and a burst of sparkles as the field develops on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
