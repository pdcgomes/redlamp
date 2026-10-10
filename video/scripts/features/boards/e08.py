"""
E08, Camera recipes: Redlamp's camera-style recipes, built from Fujifilm-style recipe cards. The editor
opens a Fujifilm raw with the Recipes panel's Camera Recipes group listed; the pointer hovers Chrome
Street and the photo previews it, then two more; a click applies Chrome Street and its Amount goes from
100 to 70; then the real photo, edited in Redlamp, and the end card.

The photo is AFXT2720.RAF, from a Fujifilm X-T3, with Chrome Street applied (docs/images/recipes.png,
the README's screenshot), cropped to the photo above the view's toolbar. There is no capture of it as
opened, nor with the other recipes: the photo as opened is Chrome Street with its muted colour and hard
shadows taken back, and the Bright Slide and Cinema Teal previews are Chrome Street carried to each
recipe by a colour fit between their golden renders on the lint chart (tests/golden/recipes), so each
preview moves the way the recipe does. The list is the Camera Recipes group in the app's order
(StarterPack.camera); Gritty Street is in the Street group, so Cinema Teal is the third recipe hovered.
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e08")
FEATURE = "CAMERA RECIPES"
SOURCE = "docs/images/recipes.png"
FILE = "AFXT2720.RAF"
PHOTO = ("AFXT2720.RAF (FUJIFILM X-T3) WITH CHROME STREET AT AMOUNT 100, DOCS/IMAGES/RECIPES.PNG. THE PHOTO AS "
         "OPENED, AMOUNT 70 AND THE OTHER RECIPES' PREVIEWS ARE MADE FROM IT UNTIL THE OWNER'S CAPTURES ARRIVE")
CHROME = w.crop(SOURCE, (218, 37, 1536, 872))
GOLDEN = w.REPO / "tests/golden/recipes/process-14"
PANEL = 86
ASPECT = CHROME.width / CHROME.height

RECIPES = ["CHROME STREET", "SNAPSHOT NEGATIVE", "NOSTALGIC SUMMER", "CINEMA TEAL", "GOLD STANDARD", "BRIGHT SLIDE"]
SLUGS = {"BRIGHT SLIDE": "bright-slide@2", "CINEMA TEAL": "cinema-teal@1"}
AMOUNT = 70
# The caption's rows raised a pixel, so the comma's tail on the second line stays inside the caption.
COMMA_ROWS = (66, 85)


def features(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    terms = [np.ones_like(r), r, g, b, r * r, g * g, b * b, r * g, r * b, g * b, r * r * r, g * g * g, b * b * b]
    return np.stack(terms, axis=-1)


def carry(img, slug):
    """`img`, which has Chrome Street, as the recipe `slug` would make it: a cubic colour map fitted from
    Chrome Street's golden render to the recipe's, on the same chart."""
    src = np.asarray(Image.open(GOLDEN / "redlamp~camera~chrome-street@3.png").convert("RGB"), np.float64) / 255
    dst = np.asarray(Image.open(GOLDEN / f"redlamp~camera~{slug}.png").convert("RGB"), np.float64) / 255
    coef, *_ = np.linalg.lstsq(features(src).reshape(-1, 13), dst.reshape(-1, 3), rcond=None)
    a = np.asarray(img, np.float64) / 255
    out = np.clip(features(a) @ coef, 0, 1)
    return Image.fromarray(np.rint(out * 255).astype(np.uint8))


def opened(img):
    """Chrome Street taken back: its colour (-2) and its harder shadows."""
    a = np.asarray(img, np.float64) / 255
    y = a @ [0.2126, 0.7152, 0.0722]
    a = y[..., None] + (a - y[..., None]) * 1.35
    a = 0.5 + (a - 0.5) * 0.9 + 0.03 * (1 - a)
    return Image.fromarray(np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8))


def blend(a, b, t):
    return Image.blend(a, b, t)


_photos = {}


def photos(size):
    if size not in _photos:
        base = opened(CHROME)
        steps = {
            "OPENED": base,
            "CHROME STREET": CHROME,
            "BRIGHT SLIDE": carry(CHROME, SLUGS["BRIGHT SLIDE"]),
            "CINEMA TEAL": carry(CHROME, SLUGS["CINEMA TEAL"]),
            "AMOUNT": blend(base, CHROME, AMOUNT / 100),
        }
        _photos[size] = {k: w.pixel_photo(v, *size) for k, v in steps.items()}
    return _photos[size]


def edit(c, shown, *, hover=None, applied=None, amount=100, press=None, mark=None):
    """The editor with the Recipes panel: the Amount slider and the Camera Recipes group. `hover` is the
    row under the pointer, `applied` the recipe applied, and `press` the pointer clicking the row
    (`"row"`) or the Amount knob (`"amount"`)."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, photos(size)[shown], file=FILE, aspect=ASPECT, panel=PANEL)
    if mark:
        w.tag(c, ed.photo, mark)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "RECIPES")
    knob = w.slider(c, p.x, y, p.w, "AMOUNT", str(amount), amount / 100, origin=0, active=press == "amount")
    y += 11
    c.text(p.x, y, "▼", w.GREY["dim"])
    c.icon(p.x + 7, y - 1, "folder", w.GREY["fill"])
    c.text(p.x + 19, y, "CAMERA RECIPES", w.GREY["label"])
    y += 10
    rx, step = p.x + 19, 8
    on = hover or applied
    w.rows(c, rx, y, p.w - 19, RECIPES, selected=RECIPES.index(on) if on else None, step=step)
    if applied:
        c.icon(p.x + p.w - 8, y + RECIPES.index(applied) * step - 2, "check", w.GREY["value"])
    if hover or press == "row":
        ry = y + RECIPES.index(on) * step
        w.pointer(c, rx + c.measure(on) - 6, ry + 2, pressed=press == "row")
    if press == "amount":
        w.pointer(c, *knob, pressed=True)
    return ed


def hook(c):
    edit(c, "OPENED")
    w.caption(c, EPISODE["hooks"]["a"], rows=COMMA_ROWS)


def hover(c):
    edit(c, "CHROME STREET", hover="CHROME STREET", mark="PREVIEW")
    w.caption(c, "HOVER TO PREVIEW")


def another(c):
    edit(c, "BRIGHT SLIDE", hover="BRIGHT SLIDE", mark="PREVIEW")
    w.caption(c, ["ONE RECIPE", "AT A TIME"])


def apply(c):
    edit(c, "CHROME STREET", applied="CHROME STREET", press="row")
    w.caption(c, "CLICK TO APPLY")


def amount(c):
    edit(c, "AMOUNT", applied="CHROME STREET", amount=AMOUNT, press="amount")
    w.caption(c, "SET THE AMOUNT")


def result(c, progress=1.0):
    ed = edit(c, "AMOUNT", applied="CHROME STREET", amount=AMOUNT)
    return w.result_frame(c, ed, CHROME, mark="AFTER", progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A deep hit on frame 0, then sixteenths under a beat held back."),
    w.Panel(2, 2.4, hover, "HOVER TO PREVIEW", "The motif starts; a soft tick as the preview changes."),
    w.Panel(3, 4.8, another, "ONE RECIPE / AT A TIME",
            "A tick for each: Bright Slide on beat 1 (drawn), Cinema Teal on beat 3."),
    w.Panel(4, 7.2, apply, "CLICK TO APPLY", "A click on beat 1; the drums come in."),
    w.Panel(5, 9.6, amount, "SET THE AMOUNT", "Slider ticks as Amount goes from 100 to 70."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
