"""
E03, Film looks, in the series' look (boards/e01.py): looks of real film stocks, each built from its
film's datasheet. The editor is drawn as E02's dashboard is: the owner's photo of a street-food cook in
the photo panel as pixel art, its histogram and level under it, and the Base Look panel below, listing
five of the 36 film looks with Redlamp's film icons. The DATASHEET card draws Portra 400's
characteristic curves, density against exposure for its red, green and blue layers; then the pointer
picks each film on the beat its name comes up, the photo develops into the look, and the card draws that
film's own curves: Tri-X 400's one curve, CineStill 800T's three, Velvia 50's falling as a slide film's
do, and HP5 Plus's. The result is the photo as opened, then from the flip the five looks across it side
by side, a sixteenth apart, since bar 6's four beats can't give five looks a beat each. The icons are
drawn from the app's, with CineStill 800T's band in cyan rather than red, which the series keeps for the
lamp.

Every picture of the photo is Redlamp's own render (features/results.py): the owner's DSC03230 (2).jpg
in ~/src/redlamp-social/photos as Redlamp opens it, and with each film's Base Look alone, as Basic ›
Base Look › Film Stocks sets it, without the grain and halation its recipe adds. Each is cropped to the
panel's shape and reduced to pixel art with a palette of its own colours. The editor labels the photo as
the raw it would be from his camera, DSC03230.ARW, as E02 does its photo. The curves are the datasheets'
characteristic curves as research/film-data digitised them.
"""

import json
import math
import subprocess
import tempfile
from functools import cache
from pathlib import Path
from typing import NamedTuple

import numpy as np
from PIL import Image

from features import results
from features import world as w
from pixelkit.art import oklab

EPISODE = w.episode("e03")
FEATURE = "FILM LOOKS"
SOURCE = Path.home() / "src/redlamp-social/photos/DSC03230 (2).jpg"
FILE = "DSC03230.ARW"
FOLDER = w.VIDEO / "public/features/e03/results"
PHOTO = ("THE OWNER'S DSC03230 (2).JPG (THE STREET-FOOD COOK), LABELLED AS ITS RAW, DSC03230.ARW, AS PIXEL ART WITH "
         "ITS OWN PALETTE. EVERY PICTURE OF IT IS REDLAMP'S RENDER: AS OPENED, AND WITH THE BASE LOOK OF PORTRA 400, "
         "TRI-X 400, CINESTILL 800T, VELVIA 50 AND HP5 PLUS, WITHOUT THEIR GRAIN AND HALATION. THE CURVES ARE THE "
         "DATASHEETS' CHARACTERISTIC CURVES FROM RESEARCH/FILM-DATA")
CUE = w.CUE

PHOTO_PANEL = w.Rect(4, 106, 208, 120)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 228, 208, 12)
BASE = w.Rect(4, 242, 178, 44)
LEVEL = w.Rect(190, 244, 18, 40)
EDITOR = (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16)
RESULT = (RESULT_PANEL.w - 8, RESULT_PANEL.h - 16)
VIEW = w.Rect(PHOTO_PANEL.x + 4, PHOTO_PANEL.y + 12, *EDITOR)
STAGE = w.Rect(RESULT_PANEL.x + 4, RESULT_PANEL.y + 12, *RESULT)
# The card comes up over the hood and the cloth at the photo's left, clear of the lamps and the cook.
CARD = w.Rect(10, 122, 72, 56)
TITLE = w.wrapped(EPISODE["title"].upper())
CAPTION_RESULT = "FIVE FILM LOOKS"
LOOKS = 36


class Film(NamedTuple):
    """A film look: its name, Redlamp's recipe for it, its accent, its icon (body, band and label colours, and
    the label; a slide film's icon is its mount), and its datasheet in research/film-data."""
    name: str
    recipe: str
    accent: str
    icon: tuple
    data: str


FILMS = [
    Film("PORTRA 400", "redlamp/stock/portra-400", "orange", ("#efe8d6", "orange", "#4a2c14", "400"), "kodak-portra-400"),
    Film("TRI-X 400", "redlamp/stock/tri-x-400", "gold", ("gold", "#1b1b1b", "gold", "400"), "kodak-tri-x-400"),
    Film("CINESTILL 800T", "redlamp/stock/cinestill-800t", "cyan", ("#1b1b1b", "cyan", "#1b1b1b", "800T"),
         "cinestill-800t"),
    Film("VELVIA 50", "redlamp/stock/velvia-50", "violet", None, "fuji-velvia-50"),
    Film("HP5 PLUS", "redlamp/stock/hp5-plus", "green", ("#1b1b1b", "#ececec", "#1b1b1b", "HP5"), "ilford-hp5-plus"),
]
PORTRA, TRI_X, CINESTILL, VELVIA, HP5 = FILMS


class Click(NamedTuple):
    """The pointer presses a film in the Base Look panel on `press` and lets go on `release`."""
    film: Film
    press: float
    release: float


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
# Each film is picked on the beat its name comes up: Portra 400 with the second step's words, Tri-X 400
# with the third's and CineStill 800T two beats later, Velvia 50 with the fourth's and HP5 Plus two beats
# later. The pointer comes in from the right over the beat before the first.
CLICKS = [Click(film, at, at + 0.5) for film, at in zip(FILMS, (s2, s3, s3 + 2, s4, s4 + 2))]
ENTER = s2 - 1
# The card's curves draw themselves over three beats from the first step's cue, and a chosen film's
# over the half beat after its click; the photo develops into a look over the frames after its click.
DRAW, REDRAW = (s1, s1 + 3), 0.5
DEVELOP = 8 / w.PER_BEAT
# On the flip the five looks develop across the photo from left to right, a sixteenth apart.
BANDS = [CUE["flip"] + i / 4 for i in range(len(FILMS))]
CAPTIONS = [(s1, ["BUILT FROM EACH", "FILM'S DATASHEET"])] + [(click.press, click.film.name) for click in CLICKS] + [
    (CUE["result"], CAPTION_RESULT)]


# ---------------------------------------------------------------- the photo, from Redlamp

# Redlamp's recipe for a film sets its grain and halation as well as its Base Look; the Base Look panel
# sets the look alone.
EFFECTS_OFF = [("effects.grain.amount", 0), ("effects.halation.amount", 0), ("effects.bloom.amount", 0)]


@cache
def real(film):
    """Redlamp's render of the photo as opened, or with `film`'s Base Look alone, 2048 pixels tall."""
    if film is None:
        return results.render(SOURCE, FOLDER, "as-opened")
    slug = film.recipe.rsplit("/", 1)[1]
    with tempfile.TemporaryDirectory() as tmp:
        recipe = Path(tmp) / f"{slug}.redrecipe"
        done = subprocess.run([str(results.CLI), "recipe", "export", film.recipe, "-o", str(recipe)], capture_output=True,
                              text=True)
        if done.returncode != 0:
            raise SystemExit(f"redlamp recipe export failed for {film.recipe}: {done.stderr.strip() or done.stdout.strip()}")
        return results.render(SOURCE, FOLDER, slug, edit=recipe, sets=EFFECTS_OFF)


# The first row of the photo each picture shows: the panel's from just above his cap, the result's a
# little lower, so its taller frame reaches his tongs over the grill.
TOPS = {EDITOR: 290, RESULT: 312}


def crop(size):
    """The part of a render a picture of `size` shows, in its pixels: its whole width, from its top row."""
    width = real(None).width
    return 0, TOPS[size], width, TOPS[size] + round(width * size[1] / size[0])


@cache
def palette(film, colors=32):
    """The look's own colours at each picture's size: the centres of its pixels' clusters in Oklab, so the
    lamps, the sign and the apron keep a colour each, and a black-and-white look keeps only greys."""
    shots = [real(film).crop(crop(size)).resize(size, Image.BOX) for size in (EDITOR, RESULT)]
    rgb = np.concatenate([np.asarray(img).reshape(-1, 3) for img in shots]).astype(np.float64)
    lab = oklab(rgb)

    def nearest(centres):
        return ((lab**2).sum(1)[:, None] - 2 * lab @ centres.T + (centres**2).sum(1)[None]).argmin(1)

    rng = np.random.default_rng(3)
    centres = lab[[rng.integers(len(lab))]]
    far = ((lab - centres[0]) ** 2).sum(1)
    while len(centres) < colors:
        centres = np.vstack([centres, lab[rng.choice(len(lab), p=far / far.sum())]])
        far = np.minimum(far, ((lab - centres[-1]) ** 2).sum(1))
    for _ in range(20):
        near = nearest(centres)
        centres = np.array([lab[near == k].mean(0) if (near == k).any() else centres[k] for k in range(colors)])
    near = nearest(centres)
    return list(dict.fromkeys(tuple(int(v) for v in np.rint(rgb[near == k].mean(0))) for k in range(colors)
                              if (near == k).any()))


@cache
def picture(film, size):
    """The photo at `size` as opened, or in `film`'s look, as pixel art."""
    img = real(film).crop(crop(size)).resize(size, Image.BOX)
    return w.lock(img, palette(film), dither=0.15).convert("RGB")


def developed(old, new, p, r):
    """`new` developed in over `old` to the share p, through the 8 × 8 ordered dither as it lies on the
    canvas at `r`."""
    if p >= 1:
        return new
    order = w.bayer(8)[(r.y + np.arange(r.h))[:, None] % 8, (r.x + np.arange(r.w))[None, :] % 8]
    return Image.fromarray(np.where((order < p)[..., None], np.asarray(new), np.asarray(old)).astype(np.uint8))


def chosen_at(b):
    """The clicks that have landed by beat b."""
    return [click for click in CLICKS if click.press <= b]


def photo_at(b):
    """The photo the panel shows at beat b: as opened until the first click, then each film's look
    developing in over the one before it."""
    done = chosen_at(b)
    if not done:
        return picture(None, EDITOR)
    before = done[-2].film if len(done) > 1 else None
    return developed(picture(before, EDITOR), picture(done[-1].film, EDITOR),
                     w.between(b, done[-1].press, done[-1].press + DEVELOP), VIEW)


# ---------------------------------------------------------------- the film icons

def canister(c, x, y, film):
    """The film's icon as the Base Look menu shows it, small: a canister in its colours with its band and
    the film's leader, or a slide film's mount. 9 × 7."""
    if film.icon is None:
        c.rect(x + 1, y, 7, 7, "#e4e0ec")
        c.rect(x + 3, y + 2, 3, 3, film.accent)
        return
    body, band, _, _ = film.icon
    c.rect(x + 1, y, 3, 1, "dim")
    c.rect(x, y + 1, 6, 6, body)
    c.rect(x, y + 3, 6, 2, band)
    c.hline(x, y + 6, 6, "dim")
    c.rect(x + 6, y + 3, 3, 2, "#8a5a32")


def big_canister(c, x, y, film):
    """The film's icon at the size it labels a look: the canister with the film's label on its band and its
    leader running out to the right, or a slide film's mount with its speed under the window. 22 × 17."""
    if film.icon is None:
        c.rect(x + 2, y, 17, 17, "#e4e0ec")
        c.box(x + 2, y, 17, 17, "#b9b3c6")
        c.rect(x + 5, y + 3, 11, 7, film.accent)
        c.hline(x + 5, y + 3, 11, f"{film.accent}.light")
        c.text(x + 10, y + 11, "50", f"{film.accent}.dark", align="center")
        return
    body, band, ink, label = film.icon
    c.rect(x + 6, y, 5, 2, "muted")
    c.rect(x, y + 2, 17, 2, "dim")
    c.rect(x, y + 4, 17, 11, body)
    c.rect(x + 17, y + 6, 5, 7, "#8a5a32")
    for hole in (y + 7, y + 11):
        c.px(x + 19, hole, "#4a2c14")
    c.rect(x, y + 6, 17, 7, band)
    c.text(x + 9, y + 7, label, ink, align="center")
    c.rect(x, y + 15, 17, 2, "dim")
    c.vline(x, y + 2, 15, "muted")


# ---------------------------------------------------------------- the Base Look panel

def _slots():
    """Where the Base Look panel's films are: two columns of three rows under its title, the last slot
    for the looks it doesn't show."""
    width, step = 82, 10
    return [w.Rect(BASE.x + 4 + (i % 2) * (width + 6), BASE.y + 12 + (i // 2) * step, width, 9) for i in range(6)]


SLOTS = _slots()


def slot(film):
    return SLOTS[FILMS.index(film)]


def chip(c, r, film, state):
    """A film as the panel lists it: its icon and its name in its accent on a dark key, lit in the accent
    with dark ink once it's the look, sunk a row while pressed."""
    if state == "on":
        c.rect(*r, film.accent)
        c.hline(r.x, r.y, r.w, f"{film.accent}.light")
        c.hline(r.x, r.y2 - 1, r.w, f"{film.accent}.dark")
        ink = "shadow"
    elif state == "pressed":
        c.rect(*r, f"{film.accent}.dark")
        ink = f"{film.accent}.light"
    else:
        c.rect(*r, "raised")
        c.hline(r.x, r.y2 - 1, r.w, "shadow")
        ink = film.accent
    sink = state == "pressed"
    canister(c, r.x + 2, r.y + 1 + sink, film)
    c.text(r.x + 13, r.y + 2 + sink, film.name, ink)


def base_look(c, b):
    """The Base Look panel: five of the film looks with their icons, the one picked pressed and then lit,
    and how many more there are."""
    c.panel(*BASE, "BASE LOOK", color="sky", right=f"{LOOKS} LOOKS", right_color="dim")
    done = chosen_at(b)
    for film in FILMS:
        pressed = any(click.film == film and click.press <= b < click.release for click in CLICKS)
        on = bool(done) and done[-1].film == film
        chip(c, slot(film), film, "pressed" if pressed else "on" if on else "off")
    more = SLOTS[len(FILMS)]
    c.text(more.x + 4, more.y + 2, f"+ {LOOKS - len(FILMS)} MORE", "dim")


def target(film):
    """Where the pointer's tip goes to pick a film: low at its key's right, clear of the name."""
    r = slot(film)
    return r.x2 - 6, r.y + 6


def pointer_at(b):
    """Where the pointer's tip is at beat b and whether it's pressed, or None while it's off screen: it
    comes in from the right in the bar before the first film, presses each film on its beat and glides
    to the next over the beat before it."""
    if b < ENTER:
        return None

    def glide(a, z, t):
        return round(a[0] + (z[0] - a[0]) * t), round(a[1] + (z[1] - a[1]) * t)

    first = CLICKS[0]
    if b < first.press:
        return glide((w.W + 6, BASE.y + 20), target(first.film), w.ease(w.between(b, ENTER, first.press))), False
    for click, following in zip(CLICKS, CLICKS[1:] + [None]):
        if following is None or b < following.press - 1:
            return target(click.film), click.press <= b < click.release
        if b < following.press:
            t = w.ease(w.between(b, following.press - 1, following.press))
            return glide(target(click.film), target(following.film), t), False
    return None


# ---------------------------------------------------------------- the card

# Density from 0 to this on every film's chart, so a slide film's deeper blacks show.
DENSITY = 4.0


@cache
def curves(film, width, height):
    """The film's characteristic curves from its datasheet, as the row of each of `width` columns on a
    chart `height` rows tall: the red, green and blue layers' for a colour film, the one curve for black
    and white, each across the exposures its datasheet plots."""
    data = json.loads((w.REPO / "research/film-data" / f"{film.data}.json").read_text())["characteristicCurves"]
    log = np.array(data["logExposure"], dtype=float)
    out = []
    for layer, colour in (("red", "red"), ("green", "green"), ("blue", "sky"), ("neutral", "white")):
        if layer not in data:
            continue
        density = np.array([np.nan if v is None else v for v in data[layer]], dtype=float)
        known = ~np.isnan(density)
        at = np.linspace(log[0], log[-1], width)
        rows = height - 1 - np.interp(at, log[known], density[known]) / DENSITY * (height - 1)
        out.append((colour, np.clip(np.rint(rows), 0, height - 1).astype(int)))
    return out


def drawn_at(b):
    """The film whose datasheet the card shows at beat b, and how much of its curves have drawn: Portra
    400's as the example from the first step, then each film's from its click."""
    done = chosen_at(b)
    if not done:
        return PORTRA, w.between(b, *DRAW)
    return done[-1].film, w.between(b, done[-1].press, done[-1].press + REDRAW)


def datasheet(c, r, b):
    """The film's icon in the title's row, its name, and its characteristic curves drawing themselves from
    left to right over a dotted grid, density up and exposure across, a white pen at their heads as they
    draw."""
    film, share = drawn_at(b)
    canister(c, r.x2 - 9, r.y - 9, film)
    c.text(r.x, r.y, film.name, "white")
    plot = w.Rect(r.x, r.y + 9, r.w, r.h - 9)
    c.grid(*plot, rows=3, cols=4, color="line")
    c.vline(plot.x, plot.y, plot.h, "dim")
    c.hline(plot.x, plot.y2 - 1, plot.w, "dim")
    shown = max(1, round(share * plot.w))
    for colour, rows in curves(film, plot.w, plot.h):
        for i in range(1, shown):
            c.line(plot.x + i - 1, plot.y + rows[i - 1], plot.x + i, plot.y + rows[i], colour)
        if share < 1:
            c.rect(plot.x + shown - 2, plot.y + rows[shown - 1] - 1, 3, 3, "white")


# ---------------------------------------------------------------- the dashboard

def dashboard(c, b):
    """Bars 1 to 5: the photo in the look picked, its histogram and level, the Base Look panel with the
    pointer, and the datasheet card from the first step."""
    w.header(c, FEATURE)
    img = photo_at(b)
    w.photo_panel(c, PHOTO_PANEL, img, b, FILE, horizon=None)
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 2.2), "gold", seg=2, gap=1)
    if b >= s1:
        film, _ = drawn_at(b)
        w.appear(c, w.between(b, s1, s1 + 6 / w.PER_BEAT),
                 lambda c: w.card(c, CARD.x, CARD.y, "DATASHEET", film.accent, lambda c, r: datasheet(c, r, b),
                                  w=CARD.w, h=CARD.h))
        if b < s1 + 0.5:
            c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, [f"{film.accent}.light", "white"],
                       seed=int(b * w.PER_BEAT))
    base_look(c, b)
    at = pointer_at(b)
    if at:
        w.pointer(c, *at[0], pressed=at[1])
    w.caption(c, caption_at(b))
    return []


def band(i):
    """The share of the result's photo the ith look takes, left to right."""
    left, right = round(i * RESULT[0] / len(FILMS)), round((i + 1) * RESULT[0] / len(FILMS))
    return w.Rect(STAGE.x + left, STAGE.y, right - left, STAGE.h)


def result(c, b):
    """Bar 6: the photo fills the stage as opened, then from the flip the five looks develop across it,
    one band each from left to right, a sixteenth apart, each labelled with its film's icon."""
    w.header(c, FEATURE)
    before = picture(None, RESULT)
    if b < CUE["flip"]:
        w.photo_panel(c, RESULT_PANEL, before, b, FILE, right="BEFORE", right_color="text", horizon=None)
    else:
        img = np.asarray(before).copy()
        for i, (film, start) in enumerate(zip(FILMS, BANDS)):
            r = band(i)
            looked = developed(before, picture(film, RESULT), w.between(b, start, start + 4 / w.PER_BEAT), STAGE)
            img[:, r.x - STAGE.x:r.x2 - STAGE.x] = np.asarray(looked)[:, r.x - STAGE.x:r.x2 - STAGE.x]
        r = w.photo_panel(c, RESULT_PANEL, Image.fromarray(img), b, FILE, right=f"{len(FILMS)} LOOKS", right_color="gold",
                          horizon=None)
        for i, (film, start) in enumerate(zip(FILMS, BANDS)):
            area = band(i)
            if i and b >= start:
                c.vline(area.x, area.y, area.h, "shadow")
            w.appear(c, w.between(b, start, start + 4 / w.PER_BEAT),
                     lambda c, film=film, area=area: big_canister(c, area.cx - 11, area.y2 - 21, film))
            if start <= b < start + 0.75:
                c.sparkles(area.x, area.y, area.w, area.h, 7, [f"{film.accent}.light", "white"],
                           seed=int(b * w.PER_BEAT) + i)
    w.caption(c, CAPTION_RESULT)
    return []


def end_card(c, b):
    """Bars 7 and 8: the lamp comes on with the end line, the call to action from its cue, then the fade."""
    light = math.ceil(6 * w.ease(w.between(b, CUE["endLine"], CUE["endLine"] + 1))) / 6
    w.cta_card(c, EPISODE["endLine"], cta=b >= CUE["cta"], light=light)
    w.fade(c, w.between(b, CUE["fade"], CUE["end"]))
    return []


def caption_at(b):
    """The caption at beat b: the title held from the opener, then each step's words."""
    lines = TITLE
    for start, words in CAPTIONS:
        if b >= start:
            lines = words
    return lines


def frame(c, b, hook="a"):
    """The picture at beat b, drawn on c; the hook is the opener's. All pixel art, so no overlays."""
    if b < CUE["result"]:
        return dashboard(c, b)
    if b < CUE["endLine"]:
        return result(c, b)
    return end_card(c, b)


# ---------------------------------------------------------------- its sounds

def pan(x):
    return round((x / w.W - 0.5) * 0.8, 2)


def sounds():
    """Each sound on screen, (beat, kind, pan): a run of blips rising with the datasheet's curve as it
    draws, panned with the card; a press and a release on each film, panned with its key, and a blip in
    the chord as its look applies; and on the flip a run climbing the chord as the five looks develop
    across the photo, from left to right."""
    out = [(DRAW[0], "plot", pan(CARD.cx))]
    for click in CLICKS:
        x = slot(click.film).cx
        out += [(click.press, "press", pan(x)), (click.release, "release", pan(x)), (click.press, "look", 0.0)]
    out.append((BANDS[0], "looks", 0.0))
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(TITLE),
            "A deep hit, then the arpeggio over a kick muffled as if through a wall. The photo as opened and the "
            "Base Look panel's films."),
    w.Panel(2, 2.4, at(s1 + 2.2), " / ".join(CAPTIONS[0][1]),
            "The riff starts over the beat and the galloping bass; a run of soft blips rises with the curves as "
            "they draw; the pointer comes in."),
    w.Panel(3, 4.8, at(s2 + 1.2), PORTRA.name,
            "A click on PORTRA 400 on the bar's first beat and a blip as its look applies."),
    w.Panel(4, 7.2, at(s3 + 2.6), f"{TRI_X.name}, then {CINESTILL.name} two beats later",
            "The riff's answer over A major and the full beat; a click and a blip for each film."),
    w.Panel(5, 9.6, at(s4 + 1.2), f"{VELVIA.name}, then {HP5.name} two beats later",
            "A click and a blip for each film; a snare roll doubles into the stop."),
    w.Panel(6, 12.0, at(BANDS[-1] + 0.6), CAPTION_RESULT + "; as opened, then the five looks from 13.2 s",
            "The drop and the sting; a run of blips climbing the chord as the looks develop across the photo."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
