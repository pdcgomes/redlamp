"""
E10, Focus stacking: Redlamp finds a focus stack and merges it into one sharp photo that edits like a
raw. The editor opens the first of 25 near-identical close-ups of a flower, the filmstrip showing the
others; the banner FOCUS STACK DETECTED · 25 FRAMES · MERGE slides in, the pointer clicks Merge, the
frames' sharp bands combine into one photo a band a beat, and the Basic sliders move on the result;
then the real stack, merged in Redlamp, and the end card.

There is no stack yet: the flower is drawn here, seen from the side so its depth runs up the picture,
and each frame is it with the focus on a different band, front (the bottom) to back (the top), and
the background out of focus in all of them. The result is a placeholder until the owner's stack
arrives; the number of frames, the file names and the slider values are to match it.
"""

import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from features import world as w

EPISODE = w.episode("e10")
FEATURE = "FOCUS STACKING"
FRAMES = 25
FIRST = 401
PHOTO = ("NONE YET: THE FLOWER AND ITS 25 FRAMES ARE DRAWN IN PIXEL ART, AND THE RESULT IS A PLACEHOLDER UNTIL "
         "THE OWNER'S STACK ARRIVES. ITS FRAME COUNT, FILE NAMES AND SLIDER VALUES ARE TO MATCH IT")
PANEL, STRIP = 40, 18
ASPECT = 1.5
BANDS = 4
UP = 4
STACK_FILE = f"DSC_0{FIRST}.REDLAMPSTACK"
# The Basic sliders moved on the merge: name, reach either side of zero, value. Stand-ins for the edit
# the owner makes on his stack.
SLIDERS = [("EXPOSURE", 5, 0.30), ("VIBRANCE", 100, 20)]


def frame_name(i):
    return f"DSC_0{FIRST + i}.NEF"


def flower(size):
    """The flower in focus everywhere over its blurred background, and its depth: 0 at the front (the
    bottom of the picture) to 1 at the back, and None where there is only background."""
    W, H = size[0] * UP, size[1] * UP
    bg = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(46 + 30 * t), int(74 + 40 * (1 - t)), int(44 + 10 * t)))
    rng = np.random.default_rng(3)
    for _ in range(14):
        x, y, r = rng.uniform(0, W), rng.uniform(0, H), rng.uniform(H * 0.05, H * 0.14)
        tone = rng.choice([(120, 150, 80), (90, 120, 64), (160, 170, 110)])
        d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(int(v) for v in tone))
    bg = bg.filter(ImageFilter.GaussianBlur(H * 0.06))

    img = bg.copy()
    d = ImageDraw.Draw(img)
    mask = Image.new("L", (W, H))
    m = ImageDraw.Draw(mask)
    cx, cy = W * 0.5, H * 0.50
    stem = [(cx - W * 0.01, cy), (cx + W * 0.02, H * 0.80), (cx + W * 0.01, H)]
    for draw_, fill in ((d, (64, 110, 52)), (m, 255)):
        draw_.line(stem, fill=fill, width=int(W * 0.025))
        draw_.polygon([(cx + W * 0.02, H * 0.86), (cx + W * 0.24, H * 0.74), (cx + W * 0.30, H * 0.80),
                       (cx + W * 0.04, H * 0.92)], fill=fill)

    def petal(a, length, width):
        tip = (cx + length * math.cos(a), cy + length * 0.5 * math.sin(a))
        side = a + math.pi / 2
        mid = (cx + 0.55 * length * math.cos(a), cy + 0.55 * length * 0.5 * math.sin(a))
        dx, dy = width * math.cos(side), width * 0.5 * math.sin(side) + width * 0.25
        return [(cx, cy), (mid[0] + dx, mid[1] + dy), tip, (mid[0] - dx, mid[1] - dy)], tip

    angles = [2 * math.pi * k / 14 + 0.1 for k in range(14)]
    for a in sorted(angles, key=math.sin):
        shape, tip = petal(a, W * 0.36, W * 0.055)
        shade = 0.82 + 0.18 * math.sin(a)
        d.polygon(shape, fill=(int(218 * shade), int(210 * shade), int(242 * shade)), outline=(118, 104, 170))
        d.line([(cx, cy), tip], fill=(150, 136, 200), width=max(1, UP // 2))
        m.polygon(shape, fill=255)
    r = W * 0.085
    d.ellipse([cx - r, cy - r * 0.55, cx + r, cy + r * 0.55], fill=(196, 150, 40), outline=(110, 74, 20))
    m.ellipse([cx - r, cy - r * 0.55, cx + r, cy + r * 0.55], fill=255)
    for i in range(-6, 7):
        for j in range(-4, 5):
            x, y = cx + i * r / 6, cy + j * r * 0.55 / 4
            if ((x - cx) / r) ** 2 + ((y - cy) / (r * 0.55)) ** 2 < 0.8 and (i + j) % 2 == 0:
                d.rectangle([x, y, x + UP / 2, y + UP / 2], fill=(110, 70, 24))

    top, bottom = cy - W * 0.18, cy + W * 0.18
    v = np.clip((bottom - np.arange(H)[:, None]) / (bottom - top), 0, 1) + np.zeros((1, W))
    depth = np.where(np.asarray(mask) > 0, v, np.nan)
    return img, depth, (top / UP, bottom / UP)


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
    sharp, depth, rows = flower(size)
    radii = [0, 3, 6, 10, 14]
    blurred = [np.asarray(sharp.filter(ImageFilter.GaussianBlur(r)) if r else sharp, np.float64) for r in radii]

    def at(focus):
        dist = np.nan_to_num(np.abs(depth - focus), nan=1.0)
        k = np.clip(np.rint(dist * 8), 0, len(radii) - 1).astype(int)
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
        "thumbs": [small(f, round(th * 1.5), th) for f in frames],
        "merges": [small(m_, *size) for m_ in merges],
        "rows": rows,
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
    w.filmstrip(c, ed.strip, s["thumbs"], selected=0 if strip else None)
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
    top, bottom = stack(ed.photo[2:])["rows"]
    c.dots(ed.photo.x, ed.photo.y + round((top + bottom) / 2), ed.photo.w, w.GREY["thumb"])
    w.tag(c, ed.photo, f"MERGING {FRAMES} FRAMES")
    w.caption(c, "ONE SHARP PHOTO")


def develop(c):
    edit(c, "merge", merged=BANDS, file=STACK_FILE, sliders=True, active="EXPOSURE", strip=False)
    w.caption(c, ["EDIT IT LIKE", "A RAW"])


def placeholder(c, photo, lines):
    """Where the real photo goes until it arrives: the photo's frame, dashed, with what's to come."""
    c.rect(*photo, w.GREY["well"])
    for x0, y0, length, vertical in ((photo.x, photo.y, photo.w, False), (photo.x, photo.y2 - 1, photo.w, False),
                                     (photo.x, photo.y, photo.h, True), (photo.x2 - 1, photo.y, photo.h, True)):
        c.dashes(x0, y0, length, w.GREY["dim"], vertical=vertical)
    for i, line in enumerate(lines):
        c.text(photo.cx, photo.cy - 6 + i * 8, line, w.GREY["label"], align="center")


def result(c):
    ed = edit(c, "merge", merged=BANDS, file=STACK_FILE, sliders=True, strip=False)
    placeholder(c, ed.photo, ["OWNER'S STACK", "TO COME"])
    w.caption(c, w.REAL_PHOTO)


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
