"""
E09, Remove by name: the name of what to remove typed into Find, and Redlamp finds and removes it on
the Mac. The editor opens a street photo crossed by power lines with the Remove panel's Find field;
POWER LINES is typed in, each line is outlined and the panel counts 4 FOUND, a click on Remove All takes
them out one a beat, and the photo is left clean; then the real photo, edited in Redlamp, and the end
card.

There is no photo yet: the street is drawn here, its four lines over the sky between the buildings, so
the outlines and the removal can be shown line by line. The result is a placeholder until the owner's
street photo and its render without the lines arrive.
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e09")
FEATURE = "REMOVE BY NAME"
FILE = "DSC_2214.NEF"
PHOTO = "NONE YET: THE STREET IS DRAWN IN PIXEL ART AND THE RESULT IS A PLACEHOLDER UNTIL THE OWNER'S PHOTO ARRIVES"
PANEL = 58
ASPECT = 1.5
QUERY = "POWER LINES"
LINES = 4
OUTLINE = w.GREY["thumb"]

_scenes = {}


def street(size):
    """The street at the photo's size: sky, a building each side with windows, the road running away
    to the middle, and LINES power lines sagging across the sky. Returns the photo with each number of
    lines left (lines[k] has the first k), and each line's pixels."""
    if size in _scenes:
        return _scenes[size]
    pw, ph = size
    c = w.canvas(pw, ph, 1)
    horizon = round(ph * 0.68)
    sky = ["#cfe0ec", "#b8d1e4", "#a3c3dc", "#8fb4d4"]
    for i, col in enumerate(sky):
        c.rect(0, 0, pw, round(horizon * (len(sky) - i) / len(sky)), col)
    far = [(0.34, 0.52, 0.12, w.WARM[4]), (0.46, 0.56, 0.10, w.GREY["fill"]), (0.55, 0.50, 0.12, w.WARM[3])]
    for fx, fy, fw, col in far:
        x, y, bw = round(pw * fx), round(ph * fy), round(pw * fw)
        c.rect(x, y, bw, horizon - y, col)
        for wy in range(y + 3, horizon - 2, 4):
            for wx in range(x + 2, x + bw - 2, 4):
                c.rect(wx, wy, 2, 2, w.WARM[1])
    c.rect(0, horizon, pw, ph - horizon, w.GREY["dim"])
    vx = pw // 2
    c.polygon([(vx - 2, horizon), (vx + 2, horizon), (pw * 0.78, ph), (pw * 0.22, ph)], fill=w.GREY["light"])
    for k in range(4):
        y0 = horizon + 3 + k * k * 3 + k * 2
        if y0 < ph - 1:
            c.rect(vx - 1, y0, 2, 1 + k, w.GREY["key"])
    left, right = round(pw * 0.30), round(pw * 0.70)
    roofs = [(0, ph * 0.34, left, ph * 0.46, w.WARM[2]), (pw, ph * 0.30, right, ph * 0.44, w.WARM[3])]
    for x_out, y_out, x_in, y_in, col in roofs:
        c.polygon([(x_out, y_out), (x_in, y_in), (x_in, ph), (x_out, ph)], fill=col)
        for col_i in range(3):
            t = (col_i + 0.6) / 3.4
            x = round(x_out + (x_in - x_out) * t)
            top = y_out + (y_in - y_out) * t
            for row in range(5):
                y = round(top + 4 + row * 9 * (1 - 0.25 * t))
                if y + 6 < ph:
                    lit = (row + col_i + (x_out > 0)) % 3 == 0
                    c.rect(x - 2, y, 5, 6, w.WARM[5] if lit else w.WARM[0])
        c.vline(x_in, round(y_in), ph, w.WARM[1])
    clean = np.asarray(c.img).copy()

    xs = np.arange(pw)
    masks = []
    for i in range(LINES):
        y_left, y_right, sag = ph * (0.06 + 0.105 * i), ph * (0.04 + 0.105 * i), ph * (0.06 + 0.01 * i)
        t = xs / (pw - 1)
        ys = np.rint(y_left + (y_right - y_left) * t + sag * 4 * t * (1 - t)).astype(int)
        m = np.zeros((ph, pw), bool)
        for x, y in zip(xs, ys):
            m[y, x] = True
            if x and abs(ys[x - 1] - y) > 1:
                lo, hi = sorted((ys[x - 1], y))
                m[lo:hi, x] = True
        masks.append(m)
    ink = np.array(w.THEME.rgb(w.WARM[0]), np.uint8)
    photos = []
    for k in range(LINES + 1):
        a = clean.copy()
        for m in masks[:k]:
            a[m] = ink
        photos.append(Image.fromarray(a))
    _scenes[size] = (photos, masks)
    return _scenes[size]


def outline(c, photo, mask):
    """The outline Find draws round a thing it found: a white rim two pixels out from it."""
    def grow(m, r):
        out = m.copy()
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                out |= np.roll(np.roll(m, dy, 0), dx, 1)
        return out
    ring = grow(mask, 2) & ~grow(mask, 1)
    ring[:, :2] = ring[:, -2:] = False
    a = np.asarray(c.img).copy()
    a[photo.y:photo.y2, photo.x:photo.x2][ring] = w.THEME.rgb(OUTLINE)
    c.img.paste(Image.fromarray(a), (0, 0))


def edit(c, lines, *, text="", typing=False, found=None, outlined=0, press=False):
    """The editor with the Remove panel: the tool's three modes, the Find field with `text`, and the
    count and Remove All once something is found. `lines` power lines are in the photo, the first
    `outlined` of them outlined."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    photos, masks = street(size)
    ed = w.editor(c, photos[lines], file=FILE, aspect=ASPECT, panel=PANEL)
    for m in masks[:outlined]:
        outline(c, ed.photo, m)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "REMOVE")
    x = p.x
    for mode in ("REMOVE", "HEAL", "CLONE"):
        x = w.button(c, x, y, mode, w=40, selected=mode == "REMOVE").x2 + 2
    y += 13
    c.text(p.x, y + 3, "FIND", w.GREY["label"])
    w.field(c, p.x + 22, y, p.w - 22, text, focused=typing)
    y += 15
    if found is not None:
        c.text(p.x, y + 2, f"{found} FOUND", w.GREY["value"])
        label = "REMOVE ALL"
        bw = c.measure(label) + 10
        r = w.button(c, p.x + p.w - bw, y, label, w=bw, primary=True, pressed=press)
        if press:
            w.pointer(c, r.x2 - 7, r.cy, pressed=True)
    return ed


def hook(c):
    edit(c, LINES)
    w.caption(c, EPISODE["hooks"]["a"])


def typed(c):
    edit(c, LINES, text=QUERY, typing=True)
    w.caption(c, ["TYPE WHAT TO", "REMOVE"])


def found(c):
    edit(c, LINES, text=QUERY, found=LINES, outlined=LINES)
    w.caption(c, ["REDLAMP FINDS", "EACH ONE"])


def remove_all(c):
    edit(c, 2, text=QUERY, found=LINES, outlined=2, press=True)
    w.caption(c, "REMOVE ALL")


def clean(c):
    edit(c, 0, text=QUERY)
    w.caption(c, "DONE ON YOUR MAC")


def placeholder(c, photo, lines):
    """Where the real photo goes until it arrives: the photo's frame, dashed, with what's to come."""
    c.rect(*photo, w.GREY["well"])
    for x0, y0, length, vertical in ((photo.x, photo.y, photo.w, False), (photo.x, photo.y2 - 1, photo.w, False),
                                     (photo.x, photo.y, photo.h, True), (photo.x2 - 1, photo.y, photo.h, True)):
        c.dashes(x0, y0, length, w.GREY["dim"], vertical=vertical)
    for i, line in enumerate(lines):
        c.text(photo.cx, photo.cy - 6 + i * 8, line, w.GREY["label"], align="center")


def result(c):
    ed = edit(c, 0, text=QUERY)
    placeholder(c, ed.photo, ["OWNER'S PHOTO", "TO COME"])
    w.caption(c, w.REAL_PHOTO)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, typed, "TYPE WHAT TO / REMOVE", "The motif starts; key clicks on the beats."),
    w.Panel(3, 4.8, found, "REDLAMP FINDS / EACH ONE", "A blip for each outline, one a beat."),
    w.Panel(4, 7.2, remove_all, "REMOVE ALL",
            "A click on beat 1, then a soft sound a line (two gone, drawn); the drums come in."),
    w.Panel(5, 9.6, clean, "DONE ON YOUR MAC", "The motif's answer."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
