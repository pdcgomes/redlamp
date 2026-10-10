"""
E05, Presets and LUTs: Lightroom develop presets dropped on the Recipes panel, the report of what came
across exactly, approximately or not at all, a .cube LUT dropped the same way, then a click on an
imported preset; then the real photo with it, and the end card.

The photo stands in until the owner's own photo and preset arrive: DSC04439.ARW, from a Sony α7R V, in
Redlamp's before and after view (docs/images/hero-compare.png), cropped below the view's Before and
After labels. The preset clicked is the edit that view shows. The report's rows are real Camera Raw
settings and the outcome docs/recipes/lightroom-presets.md gives each: Exposure, Contrast and
Highlights map one to one, a Color Priority vignette style renders as Highlight Priority, and a
profile isn't converted.
"""

from features import world as w

EPISODE = w.episode("e05")
FEATURE = "PRESETS AND LUTS"
SOURCE = "docs/images/hero-compare.png"
PHOTO = "DSC04439.ARW (SONY ILCE-7RM5) IN REDLAMP'S BEFORE AND AFTER VIEW, DOCS/IMAGES/HERO-COMPARE.PNG"
FILE = "DSC04439.ARW"
BEFORE = w.crop(SOURCE, (399, 272, 1151, 1346))
AFTER = w.crop(SOURCE, (1162, 272, 1914, 1346))
ASPECT = BEFORE.width / BEFORE.height
PANEL = 70

PRESETS = ["PARADE.XMP", "AUTUMN.XMP", "HARBOUR.XMP"]
LUT = "SLATE.CUBE"
# The import report for PARADE.XMP: each setting and how it came across.
REPORT = [
    ("EXPOSURE", "EXACT"),
    ("CONTRAST", "EXACT"),
    ("HIGHLIGHTS", "EXACT"),
    ("VIGNETTE STYLE", "APPROXIMATE"),
    ("PROFILE", "NOT AT ALL"),
]
OUTCOME = {"EXACT": "green.light", "APPROXIMATE": "yellow.light", "NOT AT ALL": w.GREY["fill"]}

_photos = {}


def photos(size):
    """The pixel photo before and after the preset."""
    if size not in _photos:
        _photos[size] = [w.pixel_photo(img, *size) for img in (BEFORE, AFTER)]
    return _photos[size]


def finder(c, rect, title, names, *, mark=None):
    """A Finder window holding files: its title bar and a file per row, the row `mark` selected."""
    x, y, ww, hh = rect
    c.rect(x + 1, y + 1, ww, hh, "shadow")
    c.rect(x, y, ww, hh, w.GREY["panel"])
    c.box(x, y, ww, hh, w.GREY["rim"])
    c.rect(x + 1, y + 1, ww - 2, 8, w.GREY["chrome"])
    for i in range(3):
        c.rect(x + 3 + i * 4, y + 4, 2, 2, w.GREY["light"])
    c.text(x + 16, y + 3, title, w.GREY["label"])
    w.files(c, x + 4, y + 13, ww - 8, names, mark=mark)
    c.claim(w.Rect(*rect), "finder")


def ghost(c, x, y, count):
    """Files being dragged, a little below and right of the pointer at (x, y)."""
    for i in reversed(range(count)):
        fx, fy = x + 7 + 2 * i, y + 9 + 2 * i
        c.rect(fx - 1, fy - 1, 9, 11, w.GREY["edge"])
        c.rect(fx, fy, 7, 9, w.GREY["key"])
        c.icon(fx, fy, "file", w.GREY["dim"])


def recipes(c, p, imported=(), *, selected=None, drop=False):
    """The Recipes panel: the Imported group, open with what has been imported, and the bundled groups
    under it. `selected` names the highlighted item; `drop` marks the panel as a drop target."""
    y = w.panel_title(c, p.x, p.y, p.w, "RECIPES")
    entries = [("IMPORTED", str(len(imported)) if imported else "", True)]
    entries += [(name.rsplit(".", 1)[0], name.rsplit(".", 1)[1], False) for name in imported]
    entries += [(g, "", True) for g in ("ESSENTIALS", "PORTRAIT", "LANDSCAPE", "STREET")]
    rows = {}
    for i, (name, note, group) in enumerate(entries[:5]):
        ry = y + i * 9
        on = name == selected or (drop and i == 0)
        if on:
            c.rect(p.x - 2, ry - 2, p.w + 4, 9, w.GREY["raised"])
        tx = p.x + 12
        if group:
            c.icon(p.x, ry - 1, "folder", w.GREY["value"] if on else w.GREY["fill"])
        else:
            tx += 10
        c.text(tx, ry, name, w.GREY["value"] if on else w.GREY["label"])
        if note:
            c.text(p.x + p.w, ry, note, w.GREY["dim"], align="right")
        rows[name] = w.Rect(tx, ry, c.measure(name), 5)
    if drop:
        c.box(p.x - 4, p.y - 3, p.w + 7, p.h + 2, w.ACCENT)
    return rows


def edit(c, *, after=False, imported=(), selected=None, drop=False):
    w.header(c, FEATURE)
    size = w.layout(panel=PANEL, aspect=ASPECT).photo[2:]
    ed = w.editor(c, photos(size)[after], file=FILE, panel=PANEL, aspect=ASPECT)
    return ed, recipes(c, ed.panel, imported, selected=selected, drop=drop)


def files_window(c, ed, title, names, *, mark=None):
    """The Finder window, on the canvas left of the photo."""
    cv = ed.canvas
    rect = w.Rect(cv.x + 3, cv.y + 4, ed.photo.x - cv.x - 6, 13 + 10 * len(names))
    finder(c, rect, title, names, mark=mark)


def hook(c):
    ed, _ = edit(c)
    files_window(c, ed, "PRESETS", PRESETS)
    w.caption(c, EPISODE["hooks"]["a"])


def drop(c):
    ed, rows = edit(c, drop=True)
    files_window(c, ed, "PRESETS", PRESETS)
    r = rows["IMPORTED"]
    px, py = r.x2 + 14, r.y + 2
    ghost(c, px, py, len(PRESETS))
    w.pointer(c, px, py)
    w.caption(c, ["DROP IN .XMP", "PRESETS"])


def report(c):
    """The import report, as a sheet over the photo: each setting and how it came across."""
    ed, _ = edit(c, imported=PRESETS)
    cv = ed.canvas
    sheet = w.Rect(cv.x + 4, cv.y, w.READ_RIGHT - 2 - (cv.x + 4), 21 + 11 * len(REPORT) + 2)
    c.rect(sheet.x + 1, sheet.y + 1, sheet.w, sheet.h, "shadow")
    c.rect(*sheet, w.GREY["raised"])
    c.box(*sheet, w.GREY["light"])
    c.text(sheet.x + 6, sheet.y + 5, PRESETS[0], w.GREY["value"], font="large")
    c.hline(sheet.x + 1, sheet.y + 16, sheet.w - 2, w.GREY["light"])
    for i, (name, outcome) in enumerate(REPORT):
        ry = sheet.y + 21 + i * 11
        c.text(sheet.x + 6, ry, name, w.GREY["label"], font="large")
        c.text(sheet.x2 - 6, ry, outcome, OUTCOME[outcome], font="large", align="right")
    c.claim(sheet, "report")
    w.caption(c, ["IT SHOWS WHAT", "CAME ACROSS"])


def lut(c):
    ed, rows = edit(c, imported=[*PRESETS, LUT], selected="SLATE")
    files_window(c, ed, "LUTS", [LUT], mark=0)
    r = rows["SLATE"]
    w.pointer(c, r.x2 + 6, r.y + 2)
    w.caption(c, [".CUBE AND .3DL", "LUTS TOO"])


def apply(c):
    _, rows = edit(c, after=True, imported=[*PRESETS, LUT], selected="PARADE")
    r = rows["PARADE"]
    w.pointer(c, r.x2 + 10, r.y + 2, pressed=True)
    w.caption(c, "CLICK TO APPLY")


def result(c, progress=1.0):
    ed, _ = edit(c, after=True, imported=[*PRESETS, LUT], selected="PARADE")
    return w.result_frame(c, ed, AFTER, mark="AFTER", progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]),
            "A soft chord and a gentle hit on frame 0; the theme's intro."),
    w.Panel(2, 2.4, drop, "DROP IN .XMP / PRESETS", "The motif starts; a soft drop sound on the beat."),
    w.Panel(3, 4.8, report, "IT SHOWS WHAT / CAME ACROSS", "A tick for each row of the report, one a beat."),
    w.Panel(4, 7.2, lut, ".CUBE AND .3DL / LUTS TOO", "A drop sound as the LUT joins the list; the drums come in."),
    w.Panel(5, 9.6, apply, "CLICK TO APPLY", "A click on the beat as the photo changes."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
