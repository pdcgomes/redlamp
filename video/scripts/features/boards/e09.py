"""
E09, Remove by name: the name of what to remove typed into Find, and Redlamp finds and removes it on
the Mac. The editor opens a street photo crossed by power lines with the Remove panel's Find field;
POWER LINES is typed in, the lines are outlined and the panel counts 4 FOUND, a click on Remove All takes
them out one a beat, and the photo is left clean; then the real photo, edited in Redlamp, and the end
card.

The photo is the owner's flooded street (DSC01898.jpg in ~/src/redlamp-social/photos), his finished
JPEG, cropped square in the editor to the poles, the cables and the birds on them. The pixel photo's
lines are found here, roughly, as thin dark strokes across the bright sky, away from the poles, and
grouped into four from the top down; the photo without them is the sky closed over them, a drawing of
what the removal will look like. The result is the photo as it is, labelled BEFORE, in Redlamp's before
and after view, beside the frame Redlamp's render without the lines goes in.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from features import world as w

EPISODE = w.episode("e09")
FEATURE = "REMOVE BY NAME"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC01898.jpg"
FILE = "DSC01898.JPG"
PHOTO = ("DSC01898.JPG, THE OWNER'S FLOODED STREET, IN EVERY PANEL: BARS 1 TO 5 IN PIXEL ART, CROPPED SQUARE TO "
         "THE POLES AND CABLES (THE OUTLINES AND THE REMOVAL ARE DRAWN), AND BAR 6 THE WHOLE JPEG UNTOUCHED, AS "
         "BEFORE. TO COME FROM REDLAMP: THE PHOTO WITH ITS POWER LINES REMOVED, FOR AFTER, AND THE NUMBER FIND "
         "COUNTS, WHICH THE PANEL'S 4 FOUND IS TO MATCH")
REAL = w.crop(SOURCE)
CROP = w.crop(SOURCE, (0, 40, 1365, 1405))
PANEL = 58
ASPECT = CROP.width / CROP.height
QUERY = "POWER LINES"
LINES = 4
OUTLINE = w.GREY["thumb"]
# Where the lines are looked for: above the trees and roofs, and clear of the three poles in the sky
# (left and right edges as shares of the photo's width), which stay.
SKY = 0.62
POLES = [(0.343, 0.390), (0.448, 0.495), (0.524, 0.552)]
UP = 4

_scenes = {}


def grow(mask, r):
    """`mask` widened by r pixels each way."""
    h, wd = mask.shape
    pad = np.pad(mask, r)
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= pad[r + dy:r + dy + h, r + dx:r + dx + wd]
    return out


def components(mask):
    """Each 8-connected group of set pixels in `mask`, as a list of masks."""
    h, wd = mask.shape
    label = np.zeros(mask.shape, int)
    found = []
    for y, x in zip(*np.nonzero(mask)):
        if label[y, x]:
            continue
        label[y, x] = len(found) + 1
        stack, part = [(y, x)], np.zeros(mask.shape, bool)
        while stack:
            cy, cx = stack.pop()
            part[cy, cx] = True
            for yy in range(max(0, cy - 1), min(h, cy + 2)):
                for xx in range(max(0, cx - 1), min(wd, cx + 2)):
                    if mask[yy, xx] and not label[yy, xx]:
                        label[yy, xx] = len(found) + 1
                        stack.append((yy, xx))
        found.append(part)
    return found


def street(size):
    """The street at the photo's size with each number of line groups removed (photos[k] has the first k
    gone), and each group's pixels. The lines are what a closing of the sky fills: strokes darker than
    the sky around them and thinner than a few pixels, which takes the birds on them too."""
    if size in _scenes:
        return _scenes[size]
    pw, ph = size
    big = CROP.resize((pw * UP, ph * UP), Image.BOX)

    def close(img, k=11):
        return img.filter(ImageFilter.MaxFilter(k)).filter(ImageFilter.MinFilter(k))

    grey = big.convert("L")
    closed = close(grey)
    sky = np.asarray(closed.filter(ImageFilter.MinFilter(15)), float) > 140
    thin = np.asarray(closed, float) - np.asarray(grey, float) > 25
    found = thin & sky
    found[round(SKY * ph * UP):] = False
    for x0, x1 in POLES:
        found[:, round(x0 * pw * UP):round(x1 * pw * UP)] = False
    filled = np.asarray(big).copy()
    filled[found] = np.asarray(Image.merge("RGB", [close(ch) for ch in big.split()]))[found]
    clean = np.asarray(w.pixel_photo(Image.fromarray(filled), pw, ph))
    photo = np.asarray(w.pixel_photo(CROP, pw, ph))

    lines = found.reshape(ph, UP, pw, UP).mean(axis=(1, 3)) >= 0.2
    parts = [p for p in components(lines) if p.sum() >= 14]
    parts.sort(key=lambda p: np.nonzero(p)[0].mean())
    total, groups, run = sum(p.sum() for p in parts), [np.zeros((ph, pw), bool) for _ in range(LINES)], 0
    for p in parts:
        groups[min(LINES - 1, run * LINES // total)] |= p
        run += p.sum()
    photos = []
    for k in range(LINES + 1):
        a = photo.copy()
        for g in groups[:k]:
            near = grow(g, 1)
            a[near] = clean[near]
        photos.append(Image.fromarray(a))
    _scenes[size] = (photos, groups)
    return _scenes[size]


def outline(c, photo, mask):
    """The outline Find draws round a thing it found: a white rim a pixel out from it."""
    ring = grow(mask, 1) & ~mask
    a = np.asarray(c.img).copy()
    a[photo.y:photo.y2, photo.x:photo.x2][ring] = w.THEME.rgb(OUTLINE)
    c.img.paste(Image.fromarray(a), (0, 0))


def edit(c, lines, *, text="", typing=False, found=None, outlined=0, press=False):
    """The editor with the Remove panel: the tool's three modes, the Find field with `text`, and the
    count and Remove All once something is found. The last `lines` groups of power lines are in the
    photo, the first `outlined` of those outlined."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    photos, groups = street(size)
    ed = w.editor(c, photos[LINES - lines], file=FILE, aspect=ASPECT, panel=PANEL)
    for g in groups[LINES - lines:][:outlined]:
        outline(c, ed.photo, g)
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
    return compare(c, FILE, REAL, ["REDLAMP'S", "RENDER", "GOES HERE"], ["POWER LINES", "REMOVED"],
                   progress=progress)


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
