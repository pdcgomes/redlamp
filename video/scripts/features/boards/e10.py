"""
E10, Focus stacking: Redlamp finds a focus stack and merges it into one sharp photo that edits like a
raw. The editor opens the first of 25 near-identical close-ups of a snail on a leaf, the filmstrip
showing the others; the banner FOCUS STACK DETECTED · 25 FRAMES · MERGE slides in, the pointer clicks
Merge, the frames' sharp bands combine into one photo a band a beat, and the Basic sliders move on the
result; then the real photo, and the end card.

The subject is the owner's snail on a leaf (DSC00983.jpg in ~/src/redlamp-social/photos), his finished
JPEG, cropped square in the editor to the snail. There is no focus-bracketed series of it yet, so the
frames are drawn from it: each is the pixel photo blurred away from one band of focus, front (the
bottom) to back (the top), and the merge takes each band from its sharp frame. The result is the photo
as it is, labelled BEFORE, in Redlamp's before and after view, beside the frame Redlamp's merge goes in.
The number of frames, the frames' file names after the first and the slider values stand in for the
owner's stack.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from features import world as w

EPISODE = w.episode("e10")
FEATURE = "FOCUS STACKING"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC00983.jpg"
FRAMES = 25
FIRST = 983
PHOTO = ("DSC00983.JPG, THE OWNER'S SNAIL ON A LEAF, IN EVERY PANEL: BARS 1 TO 5 IN PIXEL ART, CROPPED SQUARE TO "
         "THE SNAIL (THE 25 FRAMES, THE MERGE AND THE EDIT ARE DRAWN FROM IT), AND BAR 6 THE WHOLE JPEG "
         "UNTOUCHED, AS BEFORE. TO COME FROM REDLAMP: THE MERGE OF A FOCUS-BRACKETED SERIES, FOR AFTER. ITS "
         "FRAME COUNT, FILE NAMES AND SLIDER VALUES ARE TO MATCH IT")
REAL = w.crop(SOURCE)
CROP = w.crop(SOURCE, (60, 160, 1365, 1465))
PANEL, STRIP = 40, 18
ASPECT = CROP.width / CROP.height
BANDS = 4
UP = 4
STACK_FILE = f"DSC{FIRST:05d}.REDLAMPSTACK"
# The Basic sliders moved on the merge: name, reach either side of zero, value. Stand-ins for the edit
# the owner makes on his stack.
SLIDERS = [("EXPOSURE", 5, 0.30), ("VIBRANCE", 100, 20)]


def frame_name(i):
    return f"DSC{FIRST + i:05d}.JPG"


def subject(size):
    """The photo, sharp everywhere it is in the JPEG, at UP times the photo's size, and its depth: 0 at
    the front (the bottom of the picture) to 1 at the back (the top)."""
    W, H = size[0] * UP, size[1] * UP
    img = CROP.resize((W, H), Image.LANCZOS)
    depth = np.repeat(np.linspace(1, 0, H)[:, None], W, axis=1)
    return img, depth


_stacks = {}


def develop_like_raw(img):
    """The merge with SLIDERS applied, roughly: Exposure in linear light, then Vibrance as a gentle
    saturation."""
    a = np.asarray(img, np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** SLIDERS[0][2]
    a = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.clip(lin, 0, 1) ** (1 / 2.4) - 0.055)
    y = a @ [0.2126, 0.7152, 0.0722]
    a = y[..., None] + (a - y[..., None]) * (1 + SLIDERS[1][2] / 200)
    return Image.fromarray(np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8))


def stack(size):
    """Each frame at the photo's size, sharp in its band, and the merge after each band."""
    if size in _stacks:
        return _stacks[size]
    sharp, depth = subject(size)
    radii = [0, 2, 4, 7, 10]
    blurred = [np.asarray(sharp.filter(ImageFilter.GaussianBlur(r)) if r else sharp, np.float64) for r in radii]

    def at(focus):
        dist = np.nan_to_num(np.abs(depth - focus), nan=1.0)
        k = np.clip(np.rint(dist * 6), 0, len(radii) - 1).astype(int)
        out = np.choose(k[..., None], blurred)
        return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))

    def small(img, w_, h_):
        return w.pixel_photo(img, w_, h_)

    frames = [at(f) for f in np.linspace(0.02, 0.98, FRAMES)]
    first = np.asarray(frames[0], np.float64)
    merges = []
    for b in range(BANDS + 1):
        front = np.nan_to_num(depth, nan=2.0) <= b / BANDS
        out = np.where(front[..., None], blurred[0], first)
        merges.append(Image.fromarray(out.astype(np.uint8)))
    th = STRIP - 4
    _stacks[size] = {
        "edited": small(develop_like_raw(merges[-1]), *size),
        "frames": [small(f, *size) for f in frames[:1]],
        "thumbs": [small(f, th, th) for f in frames],
        "merges": [small(m_, *size) for m_ in merges],
    }
    return _stacks[size]


def value(reach, v):
    if v == 0:
        return "0.00" if reach < 10 else "0"
    return f"{v:+.2f}" if reach < 10 else f"{v:+.0f}"


def edit(c, photo="frame", *, merged=0, file=None, sliders=False, active=None, strip=True):
    """The editor on the first frame (or the merge after `merged` bands), the filmstrip under it and
    the Basic panel, its sliders at zero or at the edit's values."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL, strip=STRIP).photo[2:]
    s = stack(size)
    img = s["frames"][0] if photo == "frame" else s["edited"] if sliders else s["merges"][merged]
    ed = w.editor(c, img, file=file or frame_name(0), aspect=ASPECT, panel=PANEL, strip=STRIP)
    w.filmstrip(c, ed.strip, s["thumbs"], selected=0 if strip else None, cell=STRIP - 4)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "BASIC")
    knobs = {}
    for i, (name, reach, target) in enumerate(SLIDERS):
        v = target if sliders else 0
        knobs[name] = w.slider(c, p.x, y + i * 10, p.w, name, value(reach, v), 0.5 + v / (2 * reach),
                               active=name == active)
    if active:
        w.pointer(c, *knobs[active], pressed=True)
    return ed


def banner(c, ed, *, pressed=False):
    """The banner across the top of the photo's canvas, which is clear of the side buttons up there."""
    r = ed.canvas
    return w.banner(c, r.x + 3, r.y + 3, r.w - 6, ["FOCUS STACK DETECTED", f"{FRAMES} FRAMES"], action="MERGE",
                    pressed=pressed)


def hook(c):
    edit(c)
    w.caption(c, EPISODE["hooks"]["a"])


def detected(c):
    ed = edit(c)
    banner(c, ed)
    w.caption(c, ["IT FINDS THE", "STACK FOR YOU"])


def merge(c):
    ed = edit(c)
    button = banner(c, ed, pressed=True)
    w.pointer(c, button.x2 - 6, button.cy + 1, pressed=True)
    w.caption(c, "CLICK MERGE")


def merging(c):
    ed = edit(c, "merge", merged=2, file=STACK_FILE, strip=False)
    c.dots(ed.photo.x, ed.photo.y + ed.photo.h // 2, ed.photo.w, w.GREY["thumb"])
    w.tag(c, ed.photo, f"MERGING {FRAMES} FRAMES")
    w.caption(c, "ONE SHARP PHOTO")


def develop(c):
    edit(c, "merge", merged=BANDS, file=STACK_FILE, sliders=True, active="EXPOSURE", strip=False)
    w.caption(c, ["EDIT IT LIKE", "A RAW"])


def placeholder(c, frame, lines, note=()):
    """The frame a Redlamp render goes in until it arrives: dashed, with what's to come in it."""
    c.rect(*frame, w.GREY["well"])
    for x0, y0, length, vertical in ((frame.x, frame.y, frame.w, False), (frame.x, frame.y2 - 1, frame.w, False),
                                     (frame.x, frame.y, frame.h, True), (frame.x2 - 1, frame.y, frame.h, True)):
        c.dashes(x0, y0, length, w.GREY["dim"], vertical=vertical)
    top = frame.cy - (8 * (len(lines) + len(note)) + (3 if note else 0)) // 2
    for i, line in enumerate(lines):
        c.text(frame.cx, top + i * 8, line, w.GREY["value"], align="center")
    for i, line in enumerate(note):
        c.text(frame.cx, top + 3 + (len(lines) + i) * 8, line, w.GREY["dim"], align="center")


def compare(c, file, real, lines, note=(), *, progress=1.0):
    """Redlamp's before and after view across the stage: the owner's photo as it is, labelled BEFORE,
    and beside it the frame Redlamp's render goes in, labelled AFTER. Returns the overlay that resolves
    the pixel photo into the real one."""
    w.header(c, FEATURE)
    ed = w.editor(c, None, file=file, panel=8)
    pw, ph, gap = 100, 150, 3
    cv = ed.canvas
    before = w.Rect(cv.x + (cv.w - 2 * pw - gap) // 2, cv.y + (cv.h - ph) // 2, pw, ph)
    after = w.Rect(before.x2 + gap, before.y, pw, ph)
    c.img.paste(w.pixel_photo(real, pw, ph), (before.x, before.y))
    pixels = np.asarray(c.img)[before.y:before.y2, before.x:before.x2].copy()
    placeholder(c, after, lines, note)
    w.tag(c, before, "BEFORE")
    w.tag(c, after, "AFTER")
    w.caption(c, w.REAL_PHOTO)
    return [w.Overlay(before, real, pixels, progress)]


def result(c, progress=1.0):
    return compare(c, frame_name(0), REAL, ["REDLAMP'S", "MERGE", "GOES HERE"], [f"{FRAMES} FRAMES"],
                   progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, detected, "IT FINDS THE / STACK FOR YOU", "The motif starts; a soft chime with the banner."),
    w.Panel(3, 4.8, merge, "CLICK MERGE", "A click on beat 1."),
    w.Panel(4, 7.2, merging, "ONE SHARP PHOTO",
            "A soft blip a band, front to back (two of four drawn); the drums come in."),
    w.Panel(5, 9.6, develop, "EDIT IT LIKE / A RAW", "Slider ticks."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to the merge at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
