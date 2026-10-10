"""
E01, Free alternative to Lightroom, in the series' look, drawn as the pixelkit's dashboards are (the
DAW, the fruit music player, the system monitor), from the owner's idea of 10 October 2026. The
editor's panels are in the kit's navy with an accent each, a pixel-art dusk stands in for the photo,
the four sliders are coloured meters over a live histogram, and what each bar says comes up as a card:
a plan at $0 a month, a network panel with nothing uploaded, the licence over a heatmap of commits.
The result is the dusk before and after, in pixel art. The beats, the words and the sounds are those
of E01 with the owner's real photo (boards/e01-photo.py), which this takes them from.
"""

import importlib.util

import numpy as np

from features import world as w

_spec = importlib.util.spec_from_file_location("board_e01_photo", w.VIDEO / "scripts/features/boards/e01-photo.py")
e01 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e01)

EPISODE, FEATURE = e01.EPISODE, e01.FEATURE
PHOTO = ("NO PHOTO: A PIXEL-ART DUSK STANDS IN FOR IT, DEVELOPED BY THE FOUR SLIDERS AT E01'S VALUES (EXPOSURE "
         "+1.00, HIGHLIGHTS -40, SHADOWS -60, VIBRANCE +30)")
FILE = "DUSK.ARW"
sounds = e01.sounds
CUE = w.CUE

PHOTO_PANEL = w.Rect(4, 106, 208, 90)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 198, 208, 20)
BASIC = w.Rect(4, 220, 178, 66)
LEVEL = w.Rect(190, 224, 18, 58)
TRACK = (52, 140)
# Each slider's accent, as the kit gives each layer one.
ACCENT = {"EXPOSURE": "gold", "HIGHLIGHTS": "cyan", "SHADOWS": "violet", "VIBRANCE": "orange"}
CAPTION_RESULT = "BEFORE AND AFTER"


def values_at(b):
    """Each slider's value at beat b, stepping as E01's drags do: the photo follows each tick."""
    done = e01.state_at(b)
    out, k = {}, 0
    for drag in e01.DRAGS:
        n = len(drag.ticks)
        out[drag.slider.label] = e01.TARGET[drag.slider.label] * max(0, min(n, done - k)) / n
        k += n
    return out


def picture(values, size):
    return w.scene(w.dusk, values, size, e01.TARGET)


# ---------------------------------------------------------------- the cards

def plan(c, r):
    c.text(r.cx, r.y + 2, "$0", "green.light", font="large", scale=2, align="center")
    c.text(r.cx, r.y + 21, "PER MONTH", "text", align="center")


def network(c, r):
    c.sprite(r.x + 6, r.y + 4, w.CLOUD, {"#": "cyan"})
    c.icon(r.x + 12, r.y + 2, "cross", "red")
    c.text(r.x + 26, r.y + 3, "UPLOADS", "dim")
    c.text(r.x + 26, r.y + 11, "0 B", "white", font="large")
    c.text(r.cx, r.y + 22, "ON YOUR MAC", "text", align="center")


def source(c, r):
    commits = [[0, 2, 1, 3, 2, 4, 3, 1, 2, 4, 3], [1, 3, 4, 2, 4, 3, 4, 2, 3, 2, 4], [2, 1, 3, 4, 3, 4, 2, 4, 4, 3, 2]]
    c.heatmap(r.x + 3, r.y + 2, commits, cell=4, gap=1, colors=["raised", "violet.dark", "violet", "violet.light"])
    c.text(r.cx, r.y + 22, "MPL-2.0", "white", align="center")


# Each card, with the beat its bar starts on: what the bar's words say, drawn.
CARDS = [(e01.s1, "PLAN", "green", plan), (e01.s2, "NETWORK", "cyan", network), (e01.s3, "SOURCE", "violet", source)]


# ---------------------------------------------------------------- the dashboard

def meter_x(slider, v):
    """Where a meter's knob is at value v."""
    t0, t1 = BASIC.x + TRACK[0], BASIC.x + TRACK[1]
    return round(t0 + (0.5 + v / (2 * slider.reach)) * (t1 - t0))


def basic(c, b):
    """The Basic panel as meters, the one being dragged lit."""
    active = next((d.slider for d in e01.DRAGS if d.press <= b < d.release), None)
    rows = []
    for s in e01.SLIDERS:
        v = e01.value_at(s, b)
        rows.append((s.label, ACCENT[s.label], e01.value_text(s.reach, v), 0.5 + v / (2 * s.reach), s == active))
    return w.meters(c, BASIC, rows, right="4 SLIDERS", track=TRACK)


def pointer_at(knobs, b):
    """E01's pointer on these meters: it comes in from the right, presses each knob on its beat, moves
    with it and glides to the next."""
    if b < e01.ENTER:
        return None

    def at(slider, v):
        return meter_x(slider, v), knobs[slider.label][1]

    def glide(a, z, t):
        return round(a[0] + (z[0] - a[0]) * t), round(a[1] + (z[1] - a[1]) * t)

    first = e01.DRAGS[0]
    if b < first.press:
        return glide((w.W + 6, BASIC.y + 40), at(first.slider, 0), w.ease(w.between(b, e01.ENTER, first.press))), False
    for drag, following in zip(e01.DRAGS, e01.DRAGS[1:] + [None]):
        if b < drag.release:
            return at(drag.slider, e01.value_at(drag.slider, b)), b >= drag.press
        if following and b < following.press:
            t = w.ease(w.between(b, drag.release, following.press))
            return glide(at(drag.slider, e01.TARGET[drag.slider.label]), at(following.slider, 0), t), False
    last = e01.DRAGS[-1]
    return at(last.slider, e01.TARGET[last.slider.label]), False


def dashboard(c, b):
    """Bars 1 to 5: the photo, its histogram, its level, the meters with the pointer, and the bar's card;
    backslash held shows the photo as opened."""
    w.header(c, FEATURE)
    held = e01.KEY_DOWN <= b < e01.KEY_UP
    img = picture({} if held else values_at(b), (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16))
    r = w.photo_panel(c, PHOTO_PANEL, img, b, FILE, mark="BEFORE" if held else None)
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 2.2), "gold", seg=2, gap=1)
    for start, title, colour, body in CARDS:
        if start <= b < start + 4:
            grown = w.between(b, start, start + 6 / w.PER_BEAT)
            w.appear(c, grown, lambda c, t=title, col=colour, bd=body: w.card(c, r.x + 4, r.y + 8, t, col, bd))
            if b < start + 0.5:
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
    """Bar 6: the photo fills the stage, as opened, then developing into the edit on the flip."""
    w.header(c, FEATURE)
    size = (RESULT_PANEL.w - 8, RESULT_PANEL.h - 16)
    if b < CUE["flip"]:
        w.photo_panel(c, RESULT_PANEL, picture({}, size), b, FILE, right="BEFORE", right_color="text")
    else:
        flat = w.canvas()
        w.header(flat, FEATURE)
        w.photo_panel(flat, RESULT_PANEL, picture({}, size), b, FILE, right="BEFORE", right_color="text")
        r = w.photo_panel(c, RESULT_PANEL, picture(e01.TARGET, size), b, FILE, right="AFTER", right_color="gold")
        w.develop(c, flat.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
        if b < CUE["flip"] + 1:
            c.sparkles(r.x, r.y, r.w, r.h, 26, ["gold.light", "white", "orange.light"], seed=int(b * w.PER_BEAT))
    w.caption(c, CAPTION_RESULT)
    return []


def frame(c, b, hook="a"):
    """The picture at beat b, drawn on c; the hook is the opener's. All pixel art, so no overlays."""
    if b < CUE["result"]:
        return dashboard(c, b)
    if b < CUE["endLine"]:
        return result(c, b)
    return e01.end_card(c, b)


def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(e01.TITLE), "A deep hit, then the arpeggio over a kick muffled as if through a wall."),
    w.Panel(2, 2.4, at(e01.s1 + 3.2), "NO SUBSCRIPTION",
            "The riff starts; a click as Exposure's knob is pressed and a tick a beat; the PLAN card pops up."),
    w.Panel(3, 4.8, at(e01.s2 + 1.2), "NO CLOUD", "A click and two ticks for each slider; the NETWORK card."),
    w.Panel(4, 7.2, at(e01.s3 + 3.2), "OPEN SOURCE", "The beat comes in, gated snare and all; the SOURCE card."),
    w.Panel(5, 9.6, at(e01.s4 + 0.5), "FAMILIAR LAYOUT / AND SHORTCUTS",
            "Backslash down and up two beats later; toms fall into the stop."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), CAPTION_RESULT + "; before, then after at 13.2 s",
            "The drop and the sting; a tick and a burst of sparkles as the dusk develops on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
