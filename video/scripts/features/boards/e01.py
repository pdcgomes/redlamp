"""
E01, Free: a free raw photo editor for Mac. The editor opens the owner's raw as Redlamp opens it; the
pointer drags the Basic panel's sliders to his edit's values, one or two a bar, while the words say
what Redlamp costs and where it runs; backslash shows before and after; then the real photo, before
and after, and the end card. frame() draws any moment of it from the beat; scripts/features-frames.py
draws every frame with it, and the storyboard's panels are moments of it.

The photo is the owner's cosplayer with orange hair, DSC02372.ARW in ~/src/redlamp-social/photos, and
every picture of it is Redlamp's render (features/results.py): BEFORE is the raw with his edit's crop
alone, AFTER is his edit, and each step of a drag is the crop with the sliders moved so far, so the
pixel photo changes as the real one does. The editor shows a 4:5 part of it about his face, to fill
its canvas, and the result shows the same part at full resolution.

Until his edit is saved beside the raw (DSC02372.ARW.redlamp), STAND_IN takes its place: his JPEG's
crop, found by matching the JPEG against Redlamp's render of the whole frame, and the four sliders the
video moves, set to read well. His JPEG's own grade needs more than these four sliders.
"""

import math
from pathlib import Path
from typing import NamedTuple

from PIL import Image

from features import results
from features import world as w

EPISODE = w.episode("e01")
FEATURE = "FREE"
RAW = Path.home() / "src/redlamp-social/photos/DSC02372.ARW"
FILE = RAW.name
FOLDER = w.VIDEO / "public/features/e01/results"
STAND_IN = {
    "version": 3,
    "processVersion": 14,
    "crop": {"left": 0.4571, "top": 0.2705, "right": 0.9011, "bottom": 0.7148},
    "values": {"basic.exposure": 1.0, "basic.highlights": -40, "basic.shadows": -60, "basic.vibrance": 30},
}
EDIT = results.sidecar(RAW) or STAND_IN
STANDING_IN = EDIT is STAND_IN
# The 4:5 part of the photo the editor shows, as shares of its width and height, about his face and
# leaving out most of the shoulder at the left.
BOX = (0.1685, 0.1318, 0.9744, 0.8032)
ASPECT = 4 / 5
PANEL, RESULT_PANEL = 58, 8
PHOTO = ("THE OWNER'S DSC02372.ARW (THE COSPLAYER), EVERY PICTURE OF IT REDLAMP'S OWN RENDER: BEFORE WITH THE EDIT'S "
         "CROP ALONE, AFTER WITH THE EDIT, AND EACH STEP OF A DRAG WITH THE SLIDERS MOVED SO FAR, SHOWN 4:5 ABOUT HIS "
         "FACE. " + ("THE EDIT IS A STAND-IN UNTIL HIS IS SAVED BESIDE THE RAW: HIS JPEG'S CROP AND THE FOUR SLIDERS SHOWN"
                     if STANDING_IN else "THE EDIT IS HIS, FROM DSC02372.ARW.REDLAMP"))


class Slider(NamedTuple):
    label: str
    key: str
    reach: float


class Drag(NamedTuple):
    """The pointer presses a slider's knob on `press`, moves it a step on each of `ticks`, the last at
    the edit's value, and lets go on `release`."""
    slider: Slider
    press: float
    ticks: tuple
    release: float


# The Basic panel's sliders this edit moves, in the panel's order, and how far each reaches either side
# of zero (ParameterSpec).
SLIDERS = [Slider("EXPOSURE", "basic.exposure", 5), Slider("HIGHLIGHTS", "basic.highlights", 100),
           Slider("SHADOWS", "basic.shadows", 100), Slider("VIBRANCE", "basic.vibrance", 100)]
EXPOSURE, HIGHLIGHTS, SHADOWS, VIBRANCE = SLIDERS
VALUES = results.recipe_of(EDIT).get("values", {})
TARGET = {s.label: VALUES.get(s.key, 0) for s in SLIDERS}

s1, s2, s3, s4 = (w.CUE[f"step{i}"] for i in range(1, 5))
DRAGS = [
    Drag(EXPOSURE, s1, (s1 + 1, s1 + 2, s1 + 3), s1 + 3.5),
    Drag(HIGHLIGHTS, s2, (s2 + 0.5, s2 + 1), s2 + 1.25),
    Drag(SHADOWS, s2 + 2, (s2 + 2.5, s2 + 3), s2 + 3.25),
    Drag(VIBRANCE, s3, (s3 + 1, s3 + 2, s3 + 3), s3 + 3.5),
]
# The pointer comes in from the right two beats before the first press.
ENTER = s1 - 2
# Backslash is held from the fourth step's cue to two beats later.
KEY_DOWN, KEY_UP = s4, s4 + 2
# A knob's step eases in over the frames before its tick and lands on it.
EASE = 3 / w.PER_BEAT
# The pixel photo resolves into the real one over this many beats from the result's cue.
REVEAL = 1.0
CAPTIONS = [(s1, "NO SUBSCRIPTION"), (s2, "NO CLOUD"), (s3, "OPEN SOURCE"), (s4, ["FAMILIAR LAYOUT", "AND SHORTCUTS"]),
            (w.CUE["result"], w.REAL_PHOTO)]


# ---------------------------------------------------------------- the photo, from Redlamp

def states():
    """The slider values after each tick, from the photo as opened (none) to the whole edit."""
    out, done = [{}], {}
    for drag in DRAGS:
        for k in range(1, len(drag.ticks) + 1):
            out.append({**done, drag.slider.key: TARGET[drag.slider.label] * k / len(drag.ticks)})
        done[drag.slider.key] = TARGET[drag.slider.label]
    return out


_renders = {}


def real(state):
    """Redlamp's render after `state` ticks: 0 is BEFORE, the last is AFTER, at full size; those
    between are smaller, for the pixel photo only."""
    if state not in _renders:
        last = len(states()) - 1
        if state == 0:
            _renders[state] = results.render(RAW, FOLDER, "before", edit=results.geometry(EDIT))
        elif state == last:
            _renders[state] = results.render(RAW, FOLDER, "after", edit=EDIT)
        else:
            sets = [(k, round(v, 4)) for k, v in states()[state].items()]
            _renders[state] = results.render(RAW, FOLDER, f"step-{state}", edit=results.geometry(EDIT), sets=sets,
                                             size=512)
    return _renders[state]


def shown(img):
    """The 4:5 part of a render the editor shows."""
    l, t, r, b = BOX
    return img.crop((round(l * img.width), round(t * img.height), round(r * img.width), round(b * img.height)))


_palette = []


def palette():
    """A palette taken from the photo before and after, with the editor's greys, so his skin, the orange
    hair and the jacket's red keep their own colours in the pixel photo."""
    if not _palette:
        tiles = [shown(real(s)).resize((96, 120), Image.BOX) for s in (0, len(states()) - 1)]
        sheet = Image.new("RGB", (96 * len(tiles), 120))
        for i, tile in enumerate(tiles):
            sheet.paste(tile, (96 * i, 0))
        flat = sheet.quantize(colors=40, method=Image.Quantize.MEDIANCUT).getpalette()[:120]
        found = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
        _palette.extend(dict.fromkeys(found + [w.THEME.rgb(g) for g in w.GREY.values()]))
    return _palette


_pixels = {}


def pixel(state, size):
    if (state, size) not in _pixels:
        _pixels[state, size] = w.lock(w.fit(shown(real(state)), *size, Image.BOX), palette(), dither=0.4).convert("RGB")
    return _pixels[state, size]


# ---------------------------------------------------------------- the drags

def value_text(reach, v):
    if round(v, 2 if reach < 10 else 0) == 0:
        return "0.00" if reach < 10 else "0"
    return f"{v:+.2f}" if reach < 10 else f"{v:+.0f}"


def steps_done(drag, b):
    """How many of the drag's steps have landed by beat b, with the next one's share as it eases in."""
    k = sum(1 for t in drag.ticks if t <= b)
    if k < len(drag.ticks) and b > drag.ticks[k] - EASE:
        return k, w.ease((b - drag.ticks[k] + EASE) / EASE)
    return k, 0.0


def value_at(slider, b):
    for drag in DRAGS:
        if drag.slider == slider:
            k, part = steps_done(drag, b)
            return TARGET[slider.label] * (k + part) / len(drag.ticks)
    return 0.0


def state_at(b):
    """The photo's state at beat b: how many ticks have landed."""
    return sum(steps_done(drag, b)[0] for drag in DRAGS)


def knob(panel, slider, v):
    """Where a slider's knob is at value v, as w.slider draws it in the Basic panel."""
    i = SLIDERS.index(slider)
    x, y = panel.x, panel.y + 12 + i * 10
    t0, t1 = x + 46, x + panel.w - 24
    return t0 + round((0.5 + v / (2 * slider.reach)) * (t1 - t0 - 1)), y + 2


def pointer_at(panel, b):
    """Where the pointer's tip is at beat b and whether it's pressed, or None while it's off screen."""
    if b < ENTER:
        return None
    first = DRAGS[0]
    if b < first.press:
        start = (w.W + 6, panel.y + 40)
        end = knob(panel, first.slider, 0)
        t = w.ease(w.between(b, ENTER, first.press))
        return (round(start[0] + (end[0] - start[0]) * t), round(start[1] + (end[1] - start[1]) * t)), False
    for drag, following in zip(DRAGS, DRAGS[1:] + [None]):
        if b < drag.release:
            return knob(panel, drag.slider, value_at(drag.slider, b)), b >= drag.press
        if following and b < following.press:
            start = knob(panel, drag.slider, TARGET[drag.slider.label])
            end = knob(panel, following.slider, 0)
            t = w.ease(w.between(b, drag.release, following.press))
            return (round(start[0] + (end[0] - start[0]) * t), round(start[1] + (end[1] - start[1]) * t)), False
    return knob(panel, DRAGS[-1].slider, TARGET[DRAGS[-1].slider.label]), False


def caption_at(b, hook):
    lines = EPISODE["hooks"][hook]
    for start, words in CAPTIONS:
        if b >= start:
            lines = words
    return lines


# ---------------------------------------------------------------- the picture

def editing(c, b, hook):
    """Bars 1 to 5: the editor, the sliders moving to the edit's values, then backslash held down."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    held = KEY_DOWN <= b < KEY_UP
    ed = w.editor(c, pixel(0 if held else state_at(b), size), file=FILE, aspect=ASPECT, panel=PANEL)
    if held:
        w.tag(c, ed.photo, "BEFORE")
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASIC")
    if b >= KEY_DOWN:
        label = "BEFORE / AFTER"
        box = w.Rect(p.x - 3, p.y + 9, p.w + 3, 43)
        c.rect(*box, w.GREY["chrome"])
        c.box(*box, w.GREY["light"])
        width = 25 + 6 + c.measure(label, "large")
        w.keycap(c, box.cx - width // 2, box.y + 9, "\\", label, pressed=held, size=25, scale=2)
    else:
        active = next((d.slider for d in DRAGS if d.press <= b < d.release), None)
        for i, s in enumerate(SLIDERS):
            v = value_at(s, b)
            w.slider(c, p.x, y + i * 10, p.w, s.label, value_text(s.reach, v), 0.5 + v / (2 * s.reach), active=s == active)
        at = pointer_at(p, b)
        if at:
            w.pointer(c, *at[0], pressed=at[1])
    w.caption(c, caption_at(b, hook))
    return []


def result(c, b):
    """Bar 6: the panel folds away and the photo resolves into Redlamp's render before the edit, then
    shows the edit from the flip."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=RESULT_PANEL).photo[2:]
    after = b >= w.CUE["flip"]
    state = len(states()) - 1 if after else 0
    ed = w.editor(c, pixel(state, size), file=FILE, aspect=ASPECT, panel=RESULT_PANEL)
    progress = 1.0 if after else w.between(b, w.CUE["result"], w.CUE["result"] + REVEAL)
    return w.result_frame(c, ed, shown(real(state)), mark="AFTER" if after else "BEFORE", progress=progress, block=2)


def end_card(c, b):
    """Bars 7 and 8: the lamp comes on with the end line, the call to action from its cue, then the fade."""
    light = math.ceil(6 * w.ease(w.between(b, w.CUE["endLine"], w.CUE["endLine"] + 1))) / 6
    w.cta_card(c, EPISODE["endLine"], cta=b >= w.CUE["cta"], light=light)
    w.fade(c, w.between(b, w.CUE["fade"], w.CUE["end"]))
    return []


def frame(c, b, hook="a"):
    """The picture at beat b with hook `hook`, drawn on c. Returns the overlays to render over it."""
    if b < w.CUE["result"]:
        return editing(c, b, hook)
    if b < w.CUE["endLine"]:
        return result(c, b)
    return end_card(c, b)


# ---------------------------------------------------------------- its sounds

def pan(x):
    return round((x / w.W - 0.5) * 0.8, 2)


def sounds():
    """Each sound on screen, (beat, kind, pan): a press and a tick a step for every drag, panned with
    its knob, backslash down and up, and a tick on the flip to after."""
    p = w.layout(aspect=ASPECT, panel=PANEL).panel
    out = []
    for drag in DRAGS:
        out.append((drag.press, "press", pan(knob(p, drag.slider, 0)[0])))
        for k, t in enumerate(drag.ticks, 1):
            out.append((t, "tick", pan(knob(p, drag.slider, TARGET[drag.slider.label] * k / len(drag.ticks))[0])))
        out.append((drag.release, "release", pan(knob(p, drag.slider, TARGET[drag.slider.label])[0])))
    out += [(KEY_DOWN, "key", 0.0), (KEY_UP, "key up", 0.0), (w.CUE["flip"], "flip", 0.0)]
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


def result_panel(c, progress=1.0):
    """The result after the flip, or the reveal partway through for features-boards.py."""
    return frame(c, w.CUE["result"] + progress * REVEAL if progress < 1 else w.CUE["flip"] + 0.5)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(EPISODE["hooks"]["a"]),
            "A soft chord and a gentle hit on frame 0. The pointer comes in from the right from 1.2 s."),
    w.Panel(2, 2.4, at(s1 + 3.2), "NO SUBSCRIPTION",
            "The motif starts; a click as Exposure's knob is pressed, then a tick on each beat of the drag."),
    w.Panel(3, 4.8, at(s2 + 3.1), "NO CLOUD",
            "The motif; a click and a tick on each half beat, for Highlights, then Shadows."),
    w.Panel(4, 7.2, at(s3 + 3.2), "OPEN SOURCE",
            "The motif's answer; the drums come in; a click as Vibrance is pressed and a tick a beat."),
    w.Panel(5, 9.6, at(s4 + 0.5), "FAMILIAR LAYOUT / AND SHORTCUTS",
            "Backslash down on the beat, and up two beats later as the photo shows the edit again."),
    w.Panel(6, 12.0, result_panel, " / ".join(w.REAL_PHOTO) + "; before, then after at 13.2 s",
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, at(w.CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD)
            + " at 15.6 s", "The theme's last phrase."),
    w.Panel(8, 16.8, at(w.CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
