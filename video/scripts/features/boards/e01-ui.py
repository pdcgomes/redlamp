"""
E01 drawn as the pixelkit's dashboards are (the DAW, the fruit music player, the system monitor), to
see whether it's more enticing than the editor with the real photo: the owner's idea of 10 October
2026. The beats, the words and the sounds are E01's own (boards/e01.py); the editor's panels are in
the kit's navy with an accent each, a pixel-art dusk stands in for the photo, the four sliders are
coloured meters over a live histogram, and what each bar says comes up as a card: a plan at $0 a
month, a network panel with nothing uploaded, the licence over a heatmap of commits. The result is
the dusk before and after, in pixel art, where E01 shows the real photo.
"""

import importlib.util

import numpy as np
from PIL import Image

from features import world as w

_spec = importlib.util.spec_from_file_location("board_e01", w.VIDEO / "scripts/features/boards/e01.py")
e01 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e01)

EPISODE, FEATURE, VARIANT = e01.EPISODE, e01.FEATURE, "UI VARIATION"
PHOTO = ("NO PHOTO: A PIXEL-ART DUSK STANDS IN FOR IT, DEVELOPED BY E01'S FOUR SLIDERS AT E01'S VALUES (EXPOSURE "
         "+1.00, HIGHLIGHTS -40, SHADOWS -60, VIBRANCE +30)")
FILE = "DUSK.ARW"
sounds = e01.sounds
CUE = w.CUE

PHOTO_PANEL = w.Rect(4, 106, 208, 90)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 198, 208, 20)
BASIC = w.Rect(4, 220, 178, 66)
LEVEL = w.Rect(190, 224, 18, 58)
# Each slider's accent, as the kit gives each layer one.
ACCENT = {"EXPOSURE": "gold", "HIGHLIGHTS": "cyan", "SHADOWS": "violet", "VIBRANCE": "orange"}
CAPTION_RESULT = "BEFORE AND AFTER"


# ---------------------------------------------------------------- the dusk

def _hex(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)]) / 255


def _linear(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def _encode(v):
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)


SKY = [(0.0, "#0b0d2e"), (0.3, "#1f1650"), (0.55, "#53206a"), (0.78, "#b03f5c"), (1.0, "#f4893f")]
HORIZON, SUN = 0.64, (0.68, 0.53, 0.1)


def dusk(width, height):
    """The dusk as the eye saw it, in linear light: a sky from night to orange over two ridges of hills,
    a low sun with its glow, still water that mirrors the sky and the sun, and a few stars."""
    x = (np.arange(width) + 0.5) / width
    y = (np.arange(height) + 0.5) / height
    X, Y = np.meshgrid(x, y)
    aspect = width / height
    img = np.zeros((height, width, 3))
    stops = [s for s, _ in SKY]
    cols = np.array([_linear(_hex(c)) for _, c in SKY])
    sky_t = np.clip(np.where(Y < HORIZON, Y, 2 * HORIZON - Y) / HORIZON, 0, 1)
    for k in range(3):
        img[..., k] = np.interp(sky_t, stops, cols[:, k])
    sx, sy, sr = SUN
    d = np.hypot((X - sx) * aspect, np.where(Y < HORIZON, Y, 2 * HORIZON - Y) - sy)
    glow = np.exp(-np.maximum(d - sr, 0) / 0.13)
    img += glow[..., None] * _linear(_hex("#ff8a4a")) * 0.55
    img[(d < sr) & (Y < HORIZON)] = _linear(_hex("#ffe39a"))
    ridge_far = HORIZON - 0.1 - 0.045 * np.sin(x * 9 + 1.3) - 0.03 * np.sin(x * 23 + 0.4)
    ridge_near = HORIZON - 0.035 - 0.05 * np.sin(x * 6 + 4.1) - 0.02 * np.sin(x * 17 + 2)
    img[(Y > ridge_far[None, :]) & (Y < HORIZON)] = _linear(_hex("#40205e")) + 0.04 * glow[(Y > ridge_far[None, :]) & (Y < HORIZON)][:, None]
    img[(Y > ridge_near[None, :]) & (Y < HORIZON)] = _linear(_hex("#1d0e33"))
    water = Y >= HORIZON
    img[water] *= 0.55
    rows = np.arange(height)[:, None] * np.ones((1, width))
    column = (np.abs(X - sx) * aspect < sr * (0.9 - 0.5 * (Y - HORIZON) / (1 - HORIZON))) & water & (rows % 3 != 0)
    img[column] = img[column] * 0.4 + _linear(_hex("#ffc27a")) * 0.75
    rng = np.random.default_rng(4)
    for _ in range(width * height // 260):
        px, py = rng.integers(0, width), rng.integers(0, int(height * HORIZON * 0.55))
        if np.hypot((px / width - sx) * aspect, py / height - sy) > sr * 2.5:
            img[py, px] = _linear(_hex("#f3f4f9"))
    return img


def develop(lin, values):
    """The dusk as a raw opens it, flat and dark, then developed by the sliders' values (labels to values)."""
    grey = lin @ [0.2126, 0.7152, 0.0722]
    v = (grey[..., None] + (lin - grey[..., None]) * 0.5) * 0.4
    v = v * 2 ** values.get("EXPOSURE", 0)
    top = np.clip((v - 0.3) / 0.7, 0, 1)
    v = v * (1 + values.get("HIGHLIGHTS", 0) / 100 * 0.6 * top)
    low = np.clip(1 - v / 0.22, 0, 1)
    v = v * (1 + values.get("SHADOWS", 0) / 100 * 0.7 * low)
    v = np.clip(v, 0, 1)
    grey = v @ [0.2126, 0.7152, 0.0722]
    sat = np.abs(v - grey[..., None]).max(axis=-1, keepdims=True)
    v = grey[..., None] + (v - grey[..., None]) * (1 + values.get("VIBRANCE", 0) / 100 * 4.2 * (1 - sat))
    return Image.fromarray(np.rint(_encode(v) * 255).astype(np.uint8))


_scenes, _palette = {}, []


def palette():
    if not _palette:
        tiles = [develop(dusk(96, 72), vals) for vals in ({}, e01.TARGET)]
        sheet = Image.new("RGB", (192, 72))
        sheet.paste(tiles[0], (0, 0))
        sheet.paste(tiles[1], (96, 0))
        flat = sheet.quantize(colors=40, method=Image.Quantize.MEDIANCUT).getpalette()[:120]
        _palette.extend(dict.fromkeys(tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)))
    return _palette


def scene(values, size):
    """The dusk at `size`, developed by `values`, locked to its palette as pixel art."""
    key = (tuple(sorted(values.items())), size)
    if key not in _scenes:
        _scenes[key] = w.lock(develop(dusk(*size), values), palette(), dither=0.45).convert("RGB")
    return _scenes[key]


def values_at(b):
    """Each slider's value at beat b, stepping as E01's drags do; the photo follows each tick."""
    done = e01.state_at(b)
    out, k = {}, 0
    for drag in e01.DRAGS:
        n = len(drag.ticks)
        out[drag.slider.label] = e01.TARGET[drag.slider.label] * max(0, min(n, done - k)) / n
        k += n
    return out


# ---------------------------------------------------------------- the dashboard

CLOUD = ["..####......", ".######.##..", "###########.", "############", ".##########."]


def card(c, x, y, title, color, body):
    """A widget card: a panel with its accent title, a shadow, and `body` drawn in its content."""
    c.rect(x + 2, y + 2, 76, 46, "shadow")
    r = c.panel(x, y, 76, 46, title, color=color)
    body(c, r)


def plan(c, r):
    c.text(r.cx, r.y + 2, "$0", "green.light", font="large", scale=2, align="center")
    c.text(r.cx, r.y + 21, "PER MONTH", "text", align="center")


def network(c, r):
    c.sprite(r.x + 6, r.y + 4, CLOUD, {"#": "cyan"})
    c.icon(r.x + 12, r.y + 2, "cross", "red")
    c.text(r.x + 26, r.y + 3, "UPLOADS", "dim")
    c.text(r.x + 26, r.y + 11, "0 B", "white", font="large")
    c.text(r.cx, r.y + 22, "ON YOUR MAC", "text", align="center")


def source(c, r):
    commits = [[0, 2, 1, 3, 2, 4, 3, 1, 2, 4, 3], [1, 3, 4, 2, 4, 3, 4, 2, 3, 2, 4], [2, 1, 3, 4, 3, 4, 2, 4, 4, 3, 2]]
    c.heatmap(r.x + 3, r.y + 2, commits, cell=4, gap=1, colors=["raised", "violet.dark", "violet", "violet.light"])
    c.text(r.cx, r.y + 22, "MPL-2.0", "white", align="center")


CARDS = [(e01.s1, "PLAN", "green", plan), (e01.s2, "NETWORK", "cyan", network), (e01.s3, "SOURCE", "violet", source)]


def histogram(c, img, r):
    """The photo's red, green and blue as three interleaved bar graphs, as the app's histogram shows them."""
    c.rect(*r, "panel")
    c.box(*r, "line")
    a = np.asarray(img)
    bins = (r.w - 4) // 3
    counts = [np.histogram(a[..., k], bins=bins, range=(0, 256))[0] for k in range(3)]
    top = max(1, max(int(n.max()) for n in counts))
    for k, (n, colour) in enumerate(zip(counts, ("red", "green", "sky"))):
        for i, v in enumerate(n):
            h = round((r.h - 4) * (v / top) ** 0.5)
            if h:
                c.vline(r.x + 2 + 3 * i + k, r.y2 - 2 - h, h, colour)


def meter_x(slider, v):
    """Where a meter's knob is at value v, from its centre."""
    t0, t1 = BASIC.x + 52, BASIC.x + 140
    return round(t0 + (0.5 + v / (2 * slider.reach)) * (t1 - t0))


def basic(c, b):
    """The Basic panel as meters, each in its accent, filled from zero to its value; the one being
    dragged lit, with the pointer on its knob."""
    r = c.panel(*BASIC, "BASIC", color="sky", right="4 SLIDERS", right_color="dim")
    active = next((d.slider for d in e01.DRAGS if d.press <= b < d.release), None)
    knobs = {}
    for i, s in enumerate(e01.SLIDERS):
        y = r.y + 2 + i * 12
        v = e01.value_at(s, b)
        lit = s == active
        if lit:
            c.rect(r.x - 2, y - 2, r.w + 4, 10, "raised")
        accent = ACCENT[s.label]
        c.text(r.x, y, s.label, "white" if lit else accent)
        t0, t1 = BASIC.x + 52, BASIC.x + 140
        c.rect(t0, y + 1, t1 - t0, 3, "shadow")
        mid, kx = meter_x(s, 0), meter_x(s, v)
        lo, hi = sorted((mid, kx))
        c.rect(lo, y + 1, hi - lo + 1, 3, f"{accent}.light" if lit else accent)
        c.vline(mid, y, 5, "dim")
        c.rect(kx - 1, y - 1, 3, 7, "white")
        c.text(r.x2, y, e01.value_text(s.reach, v), "white", align="right")
        knobs[s.label] = (kx, y + 2)
    return knobs


def pointer_at(knobs, b):
    """E01's pointer, on this panel's knobs: it comes in from the right, presses each knob on its beat,
    moves with it and glides to the next."""
    if b < e01.ENTER:
        return None
    first = e01.DRAGS[0]
    start = (w.W + 6, BASIC.y + 40)

    def at(slider, v):
        return meter_x(slider, v), knobs[slider.label][1]

    if b < first.press:
        end = at(first.slider, 0)
        t = w.ease(w.between(b, e01.ENTER, first.press))
        return (round(start[0] + (end[0] - start[0]) * t), round(start[1] + (end[1] - start[1]) * t)), False
    for drag, following in zip(e01.DRAGS, e01.DRAGS[1:] + [None]):
        if b < drag.release:
            return at(drag.slider, e01.value_at(drag.slider, b)), b >= drag.press
        if following and b < following.press:
            a, z = at(drag.slider, e01.TARGET[drag.slider.label]), at(following.slider, 0)
            t = w.ease(w.between(b, drag.release, following.press))
            return (round(a[0] + (z[0] - a[0]) * t), round(a[1] + (z[1] - a[1]) * t)), False
    last = e01.DRAGS[-1]
    return at(last.slider, e01.TARGET[last.slider.label]), False


def photo(c, panel, values, b, *, right="RAW", right_color="dim", mark=None):
    """The photo panel with the dusk developed by `values`: its stars twinkle and its water glints."""
    r = c.panel(*panel, FILE, color="orange", right=right, right_color=right_color)
    img = scene(values, (r.w, r.h))
    c.img.paste(img, (r.x, r.y))
    water = round(r.h * HORIZON)
    c.shimmer(r.x, r.y + water + 1, r.w, r.h - water - 1, (b / 8) % 1, "orange.light", n=10, seed=5)
    if mark:
        w.tag(c, r, mark)
    return r, img


def dashboard(c, b):
    """Bars 1 to 5: the photo, its histogram, the meters, the pointer and the bar's card."""
    w.header(c, FEATURE)
    held = e01.KEY_DOWN <= b < e01.KEY_UP
    values = {} if held else values_at(b)
    r, img = photo(c, PHOTO_PANEL, values, b, mark="BEFORE" if held else None)
    histogram(c, img, HIST)
    level = float(np.asarray(img).mean()) / 255
    c.seg_column(*LEVEL, min(1.0, level * 2.2), "gold", seg=2, gap=1)
    for start, title, colour, body in CARDS:
        if start <= b < start + 4:
            grown = w.between(b, start, start + 6 / w.PER_BEAT)
            w.appear(c, grown, lambda c, t=title, col=colour, bd=body: card(c, r.x + 4, r.y + 8, t, col, bd))
            if grown < 1 or b < start + 0.5:
                c.sparkles(r.x + 2, r.y + 6, 82, 52, 8, [f"{colour}.light", "white"], seed=int(b * w.PER_BEAT))
    if b >= e01.KEY_DOWN:
        p = c.panel(*BASIC, "SHORTCUTS", color="gold")
        label = "BEFORE / AFTER"
        width = 25 + 6 + c.measure(label, "large")
        w.keycap(c, p.cx - width // 2, p.y + 8, "\\", label, pressed=held, size=25, scale=2)
    else:
        knobs = basic(c, b)
        at = pointer_at(knobs, b)
        if at:
            w.pointer(c, *at[0], pressed=at[1])
    w.caption(c, e01.caption_at(b))
    return []


def result(c, b):
    """Bar 6: the photo fills the stage, before, then developing into after on the flip."""
    w.header(c, FEATURE)
    if b < CUE["flip"]:
        photo(c, RESULT_PANEL, {}, b, right="BEFORE", right_color="text")
    else:
        flat = w.canvas()
        w.header(flat, FEATURE)
        photo(flat, RESULT_PANEL, {}, b, right="BEFORE", right_color="text")
        r, _ = photo(c, RESULT_PANEL, e01.TARGET, b, right="AFTER", right_color="gold")
        w.develop(c, flat.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
        if b < CUE["flip"] + 1:
            c.sparkles(r.x, r.y, r.w, r.h, 26, ["gold.light", "white", "orange.light"], seed=int(b * w.PER_BEAT))
    w.caption(c, CAPTION_RESULT)
    return []


def frame(c, b, hook="a"):
    """The picture at beat b, drawn on c. Returns the overlays to render over it (none: it's all pixel art)."""
    if b < CUE["result"]:
        return dashboard(c, b)
    if b < CUE["endLine"]:
        return result(c, b)
    return e01.end_card(c, b)


def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(e01.TITLE), "As E01."),
    w.Panel(2, 2.4, at(e01.s1 + 3.2), "NO SUBSCRIPTION", "As E01; the PLAN card pops up with a burst of sparkles."),
    w.Panel(3, 4.8, at(e01.s2 + 1.2), "NO CLOUD", "As E01; the NETWORK card."),
    w.Panel(4, 7.2, at(e01.s3 + 3.2), "OPEN SOURCE", "As E01; the SOURCE card."),
    w.Panel(5, 9.6, at(e01.s4 + 0.5), "FAMILIAR LAYOUT / AND SHORTCUTS", "As E01."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), CAPTION_RESULT + "; before, then after at 13.2 s",
            "The sting; a tick and a burst of sparkles as the dusk develops on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "As E01."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "As E01."),
]
