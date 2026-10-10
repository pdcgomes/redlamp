"""
E06, Folders: no import step and no catalogue. The editor opens empty; + adds a folder, and the
filmstrip fills with its photos at once, with the measured time to list 50,000 of them; an edit
saves IMG_1234.ARW.REDLAMP next to IMG_1234.ARW, which stays as it was; then the real app's window,
and the end card.

The folder is the owner's: his eleven photos in ~/src/redlamp-social/photos, under their own file names,
in name order. The filmstrip shows them all, and the one being edited is the cosplayer with orange hair,
DSC02372.jpg, cropped to the head and shoulders; its sidecar is named as the README names one, the
photo's name with .redlamp after it. The real app is docs/images/editor.png, the window with its
filmstrip, until a capture of the app with his folder is taken. The time is the README's Measured
performance: all 50,000 photos in 500 folders listed in 209 ms.
"""

from pathlib import Path

from features import world as w

EPISODE = w.episode("e06")
FEATURE = "FOLDERS"
APP = "docs/images/editor.png"
SHOOT = Path.home() / "src/redlamp-social/photos"
PHOTO = ("THE FOLDER IS THE OWNER'S ELEVEN PHOTOS UNDER THEIR OWN NAMES: ALL OF THEM IN THE FILMSTRIP, AND "
         "DSC02372.JPG, THE COSPLAYER, OPEN IN BARS 4 AND 5. THE REAL APP IS DOCS/IMAGES/EDITOR.PNG, A STAND-IN "
         "UNTIL A CAPTURE OF THE APP WITH HIS FOLDER IS TAKEN WITH SCRIPTS/CAPTURE-PROMO.SH")
OPEN = "DSC02372.jpg"
NAMES = sorted(p.name for p in SHOOT.glob("*.jpg"))
FILE = OPEN.upper()
SIDECAR = f"{FILE}.REDLAMP"
FOLDER = "PHOTOS"
EDITED = w.crop(SHOOT / OPEN, (200, 300, 1300, 1950))
ASPECT = EDITED.width / EDITED.height
PANEL, STRIP = 40, 22
THUMB = (round((STRIP - 4) * 2 / 3), STRIP - 4)

_cache = {}


def cached(key, make):
    if key not in _cache:
        _cache[key] = make()
    return _cache[key]


def thumbs(size):
    return cached(("thumbs", size), lambda: [w.pixel_photo(SHOOT / name, *size) for name in NAMES])


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
    """The editor: empty, then with the folder added, its photos listed, and DSC02372.JPG open."""
    w.header(c, FEATURE)
    lay = w.layout(panel=PANEL, strip=STRIP, aspect=ASPECT)
    image = cached(("photo", lay.photo[2:]), lambda: w.pixel_photo(EDITED, *lay.photo[2:])) if photo else None
    ed = w.editor(c, image, file=FILE if photo else "REDLAMP", panel=PANEL, strip=STRIP, aspect=ASPECT)
    if listed:
        w.filmstrip(c, ed.strip, thumbs(THUMB), selected=NAMES.index(OPEN) if photo else None, cell=THUMB[0])
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
    """The folder in the Finder around the photo being edited, with its sidecar after it."""
    ed = edit(c, folder=True, listed=True, photo=True)
    i = NAMES.index(OPEN)
    names = [FILE, SIDECAR, NAMES[i + 1].upper()]
    rect = w.Rect(ed.canvas.x + 3, ed.panel.y - 5 - (15 + 13 * len(names)), w.READ_RIGHT - 4 - (ed.canvas.x + 3),
                  14 + 13 * len(names))
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
