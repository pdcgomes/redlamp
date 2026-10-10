"""
E06, Folders: no import step and no catalogue. The editor opens empty; + adds a folder, and the
filmstrip fills with its photos at once, with the measured time to list 50,000 of them; an edit
saves IMG_1234.ARW.REDLAMP next to IMG_1234.ARW, which stays as it was; then the real app's window,
and the end card.

The photos stand in until the owner's own shoot arrives: the photo being edited is DSC04439.ARW, from
a Sony α7R V, as the app shows it in docs/images/hero.png (cropped to the photo, above the canvas's
toolbar), named IMG_1234.ARW as the README names a photo and its sidecar. The filmstrip's thumbnails
are the photos in the repository's other captures. The real app is docs/images/editor.png, the window
with its filmstrip. The time is the README's Measured performance: all 50,000 photos in 500 folders
listed in 209 ms.
"""

from features import world as w

EPISODE = w.episode("e06")
FEATURE = "FOLDERS"
APP = "docs/images/editor.png"
PHOTO = ("IMG_1234.ARW STANDS IN FOR DSC04439.ARW (SONY ILCE-7RM5), DOCS/IMAGES/HERO.PNG; "
         "THE REAL APP IS DOCS/IMAGES/EDITOR.PNG")
FILE = "IMG_1234.ARW"
SIDECAR = "IMG_1234.ARW.REDLAMP"
FOLDER = "PHOTOS"
EDITED = w.crop("docs/images/hero.png", (686, 78, 1627, 1405))
ASPECT = EDITED.width / EDITED.height
PANEL, STRIP = 40, 18
# The other photos in the repository's captures, cropped inside each window's canvas.
THUMBS = [
    ("docs/images/hero.png", (686, 78, 1627, 1405)),
    ("docs/images/before-after.png", (880, 275, 1577, 709)),
    ("docs/images/recipes.png", (300, 150, 1400, 800)),
    ("docs/images/black-and-white.png", (300, 150, 1400, 800)),
    ("docs/images/color-grading.png", (300, 150, 1400, 800)),
    ("docs/images/proraw.png", (650, 250, 1150, 700)),
    ("docs/images/film-editor.png", (300, 150, 1400, 800)),
    ("docs/images/detail.png", (300, 150, 1400, 800)),
]

_cache = {}


def cached(key, make):
    if key not in _cache:
        _cache[key] = make()
    return _cache[key]


def thumbs(size):
    return cached(("thumbs", size), lambda: [w.pixel_photo(w.crop(p, box), *size) for p, box in THUMBS])


def readout(c, cx, y, text):
    """A measured figure over the canvas in the large font, centred on cx. Returns its rect."""
    tw = c.measure(text, "large")
    r = w.Rect(cx - (tw + 12) // 2, y, tw + 12, 15)
    c.rect(r.x + 1, r.y + 1, r.w, r.h, "shadow")
    c.rect(*r, w.GREY["raised"])
    c.box(*r, w.GREY["light"])
    c.text(r.x + 6, r.y + 4, text, w.GREY["value"], font="large")
    c.claim(r, "readout")
    return r


def finder(c, rect, title, names, *, badges=None, mark=None):
    """A Finder window listing files in the large font, the row `mark` selected, with a dim badge
    right-aligned on a row (NEW, UNCHANGED)."""
    x, y, ww, hh = rect
    c.rect(x + 1, y + 1, ww, hh, "shadow")
    c.rect(x, y, ww, hh, w.GREY["panel"])
    c.box(x, y, ww, hh, w.GREY["rim"])
    c.rect(x + 1, y + 1, ww - 2, 9, w.GREY["chrome"])
    for i in range(3):
        c.rect(x + 4 + i * 5, y + 4, 3, 3, w.GREY["light"])
    c.icon(x + 22, y + 2, "folder", w.GREY["fill"])
    c.text(x + 34, y + 3, title, w.GREY["label"])
    for i, name in enumerate(names):
        ry = y + 15 + i * 13
        on = i == mark
        if on:
            c.rect(x + 2, ry - 3, ww - 4, 13, w.GREY["light"])
        c.icon(x + 5, ry - 1, "file", w.GREY["value"] if on else w.GREY["fill"])
        c.text(x + 16, ry, name, w.GREY["thumb"] if on else w.GREY["label"], font="large")
        if badges and badges[i]:
            c.text(x + ww - 5, ry, badges[i], w.GREY["value"] if on else w.GREY["dim"], font="large",
                   align="right")
    c.claim(w.Rect(*rect), "finder")


def edit(c, *, folder=False, listed=False, photo=False, press=False):
    """The editor: empty, then with the folder added, its photos listed, and IMG_1234.ARW open."""
    w.header(c, FEATURE)
    lay = w.layout(panel=PANEL, strip=STRIP, aspect=ASPECT)
    image = cached(("photo", lay.photo[2:]), lambda: w.pixel_photo(EDITED, *lay.photo[2:])) if photo else None
    ed = w.editor(c, image, file=FILE if photo else "REDLAMP", panel=PANEL, strip=STRIP, aspect=ASPECT)
    if listed:
        w.filmstrip(c, ed.strip, thumbs((round((STRIP - 4) * 1.5), STRIP - 4)), selected=0 if photo else None)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w - 12, "FOLDERS")
    add = w.button(c, p.x2 - 9, p.y - 1, "+", w=9, pressed=press)
    if folder:
        w.rows(c, p.x + 2, y, p.w - 4, [FOLDER], selected=0, icon="folder", right=["50,000" if listed else ""])
    if press:
        w.pointer(c, add.x2 - 2, add.y2 - 2, pressed=True)
    return ed


def hook(c):
    edit(c)
    w.caption(c, EPISODE["hooks"]["a"])


def add(c):
    edit(c, folder=True, press=True)
    w.caption(c, "ADD A FOLDER")


def listed(c):
    ed = edit(c, folder=True, listed=True)
    readout(c, ed.canvas.cx, ed.canvas.cy - 7, "50,000 PHOTOS · 0.2 S")
    w.caption(c, ["50,000 PHOTOS", "LISTED IN 0.2 S"])


def files(c, badges, mark):
    ed = edit(c, folder=True, listed=True, photo=True)
    names = [FILE, SIDECAR, "IMG_1235.ARW"]
    rect = w.Rect(ed.canvas.x + 3, ed.panel.y - 5 - (15 + 13 * len(names)), w.READ_RIGHT - 4 - (ed.canvas.x + 3),
                  12 + 13 * len(names))
    finder(c, rect, FOLDER, names, badges=badges, mark=mark)


def sidecar(c):
    files(c, [None, "NEW", None], 1)
    w.caption(c, ["EDITS SAVED NEXT", "TO THE PHOTO"])


def original(c):
    files(c, ["UNCHANGED", None, None], 0)
    w.caption(c, ["THE ORIGINAL IS", "NEVER CHANGED"])


def result(c, progress=1.0):
    """The real app's window across the stage, resolving out of its pixel version."""
    w.header(c, FEATURE)
    app = w.crop(APP)
    s = w.STAGE
    h = round(s.w * app.height / app.width)
    r = w.Rect(s.x, s.y + (s.h - h) // 2, s.w, h)
    c.rect(r.x + 2, r.y + 2, r.w, r.h, "shadow")
    pixels = cached(("app", r.w, r.h), lambda: w.pixel_photo(app, r.w, r.h))
    c.img.paste(pixels, (r.x, r.y))
    c.claim(r, "app")
    w.caption(c, w.REAL_APP)
    return [w.Overlay(r, app, None, progress)]


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]),
            "A soft chord and a gentle hit on frame 0; the theme's intro."),
    w.Panel(2, 2.4, add, "ADD A FOLDER", "The motif starts; a click on the beat."),
    w.Panel(3, 4.8, listed, "50,000 PHOTOS / LISTED IN 0.2 S",
            "A quick run of soft ticks as the thumbnails arrive."),
    w.Panel(4, 7.2, sidecar, "EDITS SAVED NEXT / TO THE PHOTO", "A soft click as the sidecar appears; the drums come in."),
    w.Panel(5, 9.6, original, "THE ORIGINAL IS / NEVER CHANGED", "The motif's answer."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_APP), "The develop sting: the motif's head over struck glass."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
