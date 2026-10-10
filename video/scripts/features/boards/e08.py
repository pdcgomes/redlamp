"""
E08, Camera recipes, in the series' look (boards/e01.py): Redlamp's camera-style recipes, built from
Fujifilm-style recipe cards, previewed by hovering, applied with a click, then set with their Amount.
The editor is drawn as E01's dashboard is: a Fujifilm raw in the photo panel as pixel art, its
histogram and level under it, and the Recipes panel below with the Camera Recipes group listed, each
recipe with a swatch of its look on the photo. The pointer comes in over CHROME STREET and the photo
previews it, under the pill the app shows over a preview, then BRIGHT SLIDE and CINEMA TEAL, the photo
following each; back on CHROME STREET it clicks, the recipe is applied and its AMOUNT comes up at 100,
as the app shows it once a recipe is applied, and the pointer drags it to 70, the photo following each
step. What each bar says comes up as a card over the panel's right, clear of the photo: the card the
previewed recipe is built from, the history step the click makes, and the Amount. The result is the
photo before and after Chrome Street at 70, in pixel art.

The photo is AFXT2720.RAF, the README's raw from a Fujifilm X-T3 (tests/fixtures/raw), and every
picture of it is Redlamp's render with the redlamp CLI, kept in public/features/e08/results/: as opened,
and with each camera recipe as the editor applies it (`redlamp recipe render`, which starts from the
photo as opened, its white balance as shot, and works out a recipe's auto white balance as the editor
does), Chrome Street at Amount 100, 90, 80 and 70. Each is reduced to pixel art with a palette of the
photo's own colours, as E02's is. The Camera Recipes group, its order and each recipe's card are the
app's own, read from the CLI too (`redlamp recipe list`, `redlamp recipe show`).
"""

import hashlib
import json
import math
import subprocess
from functools import cache
from pathlib import Path
from typing import NamedTuple

import numpy as np
from PIL import Image

from features import results
from features import world as w
from pixelkit.art import oklab

EPISODE = w.episode("e08")
FEATURE = "CAMERA RECIPES"
FILE = "AFXT2720.RAF"
PHOTO = ("AFXT2720.RAF (FUJIFILM X-T3), THE README'S RAW, EVERY PICTURE OF IT REDLAMP'S OWN RENDER WITH THE CLI: AS "
         "OPENED, WITH EACH CAMERA RECIPE AS THE EDITOR APPLIES IT, AND CHROME STREET AT AMOUNT 100, 90, 80 AND 70; AS "
         "PIXEL ART WITH ITS OWN PALETTE. THE RECIPES, THEIR ORDER AND THEIR CARDS ARE THE APP'S")
CUE = w.CUE
FOLDER = w.VIDEO / "public/features/e08/results"
GROUP = "Camera Recipes"

PHOTO_PANEL = w.Rect(4, 106, 208, 84)
RESULT_PANEL = w.Rect(4, 106, 208, 178)
HIST = w.Rect(4, 192, 208, 12)
RECIPES = w.Rect(4, 206, 178, 81)
LEVEL = w.Rect(190, 210, 18, 73)
EDITOR = (PHOTO_PANEL.w - 8, PHOTO_PANEL.h - 16)
RESULT = (RESULT_PANEL.w - 8, RESULT_PANEL.h - 16)
SWATCH = (9, 6)
# The Recipes panel's rows: the recipe's Amount, the group, and its recipes a row each, their names
# under the group's and their swatches under its folder.
AMOUNT_Y, GROUP_Y, LIST_Y, ROW = RECIPES.y + 12, RECIPES.y + 22, RECIPES.y + 31, 8
LABEL_X, ICON_X, NAME_X = RECIPES.x + 4, RECIPES.x + 10, RECIPES.x + 22
TRACK = (RECIPES.x + 36, RECIPES.x + 136)
# The cards come up over the panel's right, beside the names and under the Amount's value.
CARD = w.Rect(100, 226, 80, 56)
# The Amount's reach (the app's slider runs from 0, the photo as it was, to 200, twice as far).
REACH = 200
TITLE = w.wrapped(EPISODE["title"].upper())
CAPTION_RESULT = "BEFORE AND AFTER"


class Hover(NamedTuple):
    """The pointer lands on a recipe on `at`, and the photo previews it."""
    recipe: str
    at: float


class Click(NamedTuple):
    """The pointer presses a recipe on `press` and lets go on `release`."""
    recipe: str
    press: float
    release: float


class Drag(NamedTuple):
    """The pointer presses the Amount's knob on `press`, moves it a step on each of `ticks`, and lets go
    on `release`."""
    press: float
    ticks: tuple
    release: float


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
# The pointer comes in from the right with the first step's words and lands on CHROME STREET two beats
# later; it moves on to BRIGHT SLIDE on the second step's first beat and CINEMA TEAL two beats after,
# and back to CHROME STREET on the third step's first beat, which it clicks on the next. Each move takes
# the three sixteenths before the beat it lands on.
ENTER = s1
HOVERS = [Hover("CHROME STREET", s1 + 2), Hover("BRIGHT SLIDE", s2), Hover("CINEMA TEAL", s2 + 2),
          Hover("CHROME STREET", s3)]
MOVE = 0.75
CLICK = Click("CHROME STREET", s3 + 1, s3 + 1.5)
DRAG = Drag(s4, (s4 + 1, s4 + 2, s4 + 3), s4 + 3.5)
AMOUNTS = (100, 90, 80, 70)
# A knob's step eases in over the frames before its tick and lands on it.
EASE = 3 / w.PER_BEAT
CAPTIONS = [(s1, "HOVER TO PREVIEW"), (s2, ["ONE RECIPE", "AT A TIME"]), (s3, "CLICK TO APPLY"),
            (s4, "SET THE AMOUNT"), (CUE["result"], CAPTION_RESULT)]


# ---------------------------------------------------------------- the recipes and the photo, from Redlamp

def fixture(name):
    """A raw in the repository's fixtures, which a worktree has only in the main checkout."""
    path = w.REPO / "tests/fixtures/raw" / name
    if not path.exists():
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=w.REPO,
                                capture_output=True, text=True, check=True).stdout.strip()
        path = Path(common).parent / "tests/fixtures/raw" / name
    return path


RAW = fixture(FILE)


def kept(name, key, suffix, make):
    """The file FOLDER keeps for `name`, made by `make(path)` when `key` is new; older ones go."""
    path = FOLDER / f"{name}-{hashlib.sha256(json.dumps(key).encode()).hexdigest()[:12]}{suffix}"
    if not path.exists():
        FOLDER.mkdir(parents=True, exist_ok=True)
        make(path)
        for old in FOLDER.glob(f"{name}-*{suffix}"):
            if old != path:
                old.unlink()
    return path


def redlamp(*args):
    done = subprocess.run([str(results.CLI), *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"redlamp {' '.join(args)} failed: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout


def asked(name, *args):
    """What the CLI prints as JSON for `args`, kept until the CLI changes."""
    path = kept(name, [list(args), results.CLI.stat().st_mtime_ns], ".json",
                lambda path: path.write_text(redlamp(*args)))
    return json.loads(path.read_text())


class Recipe(NamedTuple):
    name: str
    id: str


@cache
def recipes():
    """The Camera Recipes group, in the order the Recipes panel lists it, its names in capitals."""
    listed = asked("list", "recipe", "list", "--json")
    return [Recipe(r["name"].upper(), r["id"]) for r in listed if r["group"] == GROUP]


def recipe(name):
    return next(r for r in recipes() if r.name == name)


@cache
def card(name):
    """The camera card a recipe is built from."""
    return asked(f"card-{recipe(name).id.split('/')[-1]}", "recipe", "show", recipe(name).id)["source"]["card"]


@cache
def render(name=None, amount=100):
    """Redlamp's render of the raw, 2048 pixels on its long edge: as opened, or with the recipe `name` at
    `amount` as the editor applies it, from the photo as opened."""
    if name is None:
        return results.render(RAW, FOLDER, "opened")
    rid, size = recipe(name).id, 2048
    key = [RAW.name, RAW.stat().st_size, RAW.stat().st_mtime_ns, rid, amount, size, results.CLI.stat().st_mtime_ns]
    args = ["recipe", "render", str(RAW), "--recipe", rid, "--size", str(size), "--amount", str(amount)]
    path = kept(f"{rid.split('/')[-1]}-{amount}", key, ".png", lambda path: redlamp(*args, "-o", str(path)))
    return Image.open(path).convert("RGB")


# The photo as opened, and the edit the video makes.
OPENED, EDIT = (None, 100), ("CHROME STREET", AMOUNTS[-1])


def shown(img, size):
    """The part of a render a picture of `size` shows: a band across its whole width through the bag's
    red label for the editor, its whole height about the bag for the result, all of it for a swatch."""
    iw, ih = img.size
    if size[0] * ih > size[1] * iw * 1.01:
        h = round(iw * size[1] / size[0])
        top = round(0.42 * ih - h / 2)
        box = (0, top, iw, top + h)
    elif size[0] * ih < size[1] * iw * 0.99:
        wd = round(ih * size[0] / size[1])
        left = min(iw - wd, round(0.585 * iw - wd / 2))
        box = (left, 0, left + wd, ih)
    else:
        box = (0, 0, iw, ih)
    return img.crop(box).resize(size, Image.BOX)


def looks():
    """Every look the editor shows, as (recipe, amount): as opened, each recipe the pointer previews, and
    Chrome Street at each step of the Amount."""
    hovered = dict.fromkeys(h.recipe for h in HOVERS)
    return [OPENED, *((name, 100) for name in hovered), *((CLICK.recipe, a) for a in AMOUNTS[1:])]


@cache
def palette(colors=40):
    """The photo's own colours, in every look the editor shows and the result's two: the centres of its
    pixels' clusters in Oklab, so the toys' greens and yellows and the bag's blues keep a colour for each
    recipe's take on them."""
    shots = [shown(render(*look), EDITOR) for look in looks()]
    shots += [shown(render(*look), RESULT) for look in (OPENED, EDIT)]
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
def picture(look, size):
    """The photo in `look` at `size`, as pixel art."""
    return w.lock(shown(render(*look), size), palette(), dither=0.15).convert("RGB")


@cache
def keys():
    """Where the photo as opened is the toy's green, the plush's yellow and the bag's blue, at 512 pixels."""
    a = np.asarray(render(*OPENED).resize((512, 342), Image.BOX), dtype=np.float64)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return [(g > r + 25) & (g > b + 60), (r > 170) & (g > 150) & (b < 130) & (r - b > 70), (b > r + 60) & (b > g + 20)]


@cache
def swatch(name):
    """A recipe's look on the photo, as the list's swatch: three stripes, the recipe's take on the toy's
    green, the plush's yellow and the bag's blue."""
    a = np.asarray(render(name, 100).resize((512, 342), Image.BOX), dtype=np.float64)
    out = np.zeros((SWATCH[1], SWATCH[0], 3), np.uint8)
    for i, mask in enumerate(keys()):
        out[:, i * SWATCH[0] // 3:(i + 1) * SWATCH[0] // 3] = np.rint(a[mask].mean(0))
    return Image.fromarray(out)


# ---------------------------------------------------------------- the pointer, the click and the drag

def row_y(name):
    return LIST_Y + [r.name for r in recipes()].index(name) * ROW


def target(name):
    """Where the pointer's tip rests on a recipe: just past its name, so the name stays clear."""
    return NAME_X + w.FONTS["small"].measure(name) + 1, row_y(name) + 2


def knob(v):
    """Where the Amount's knob is at value v."""
    t0, t1 = TRACK
    return round(t0 + v / REACH * (t1 - t0)), AMOUNT_Y + 2


def steps_done(b):
    """How many of the drag's steps have landed by beat b, with the next one's share as it eases in."""
    k = sum(1 for t in DRAG.ticks if t <= b)
    if k < len(DRAG.ticks) and b > DRAG.ticks[k] - EASE:
        return k, w.ease((b - DRAG.ticks[k] + EASE) / EASE)
    return k, 0.0


def amount_at(b):
    """The Amount at beat b, as its knob shows it."""
    k, part = steps_done(b)
    return AMOUNTS[k] + (AMOUNTS[min(k + 1, len(AMOUNTS) - 1)] - AMOUNTS[k]) * part


def previewing(b):
    """The recipe the photo previews at beat b: the last one the pointer landed on, until the click
    applies one."""
    landed = [h.recipe for h in HOVERS if h.at <= b]
    return landed[-1] if landed and b < CLICK.press else None


def applied(b):
    return b >= CLICK.press


def look_at(b):
    """What the photo shows at beat b: the preview, then the applied recipe at the Amount's last step."""
    if applied(b):
        return CLICK.recipe, AMOUNTS[steps_done(b)[0]]
    name = previewing(b)
    return (name, 100) if name else OPENED


def path():
    """The pointer's moves, as (the beat it leaves, the beat it lands, where it lands)."""
    moves = [(ENTER, HOVERS[0].at, target(HOVERS[0].recipe))]
    moves += [(h.at - MOVE, h.at, target(h.recipe)) for h in HOVERS[1:]]
    return moves + [(DRAG.press - 1, DRAG.press, knob(AMOUNTS[0]))]


def pointer_at(b):
    """Where the pointer's tip is at beat b and whether it's pressed, or None while it's off screen: it
    comes in from the right, lands on each recipe it previews, clicks CHROME STREET, then glides to the
    Amount's knob on the beat before the drag, moves with it and lets go."""
    if b < ENTER:
        return None
    if b >= DRAG.press:
        return knob(amount_at(b)), b < DRAG.release

    def glide(a, z, t):
        return round(a[0] + (z[0] - a[0]) * t), round(a[1] + (z[1] - a[1]) * t)

    at = (w.W + 6, target(HOVERS[0].recipe)[1])
    for leave, land, to in path():
        if b < leave:
            break
        at = glide(at, to, w.ease(w.between(b, leave, land))) if b < land else to
    return at, CLICK.press <= b < CLICK.release


# ---------------------------------------------------------------- the cards

def signed(v):
    return "0" if v == 0 else f"{v:+g}"


def recipe_card(c, r, b):
    """The card the previewed recipe is built from, as photographers share them: its highlight, shadow
    and colour as meters either side of zero over their reach, and its grain."""
    k = card(previewing(b))
    t0, t1 = r.x + 38, r.x + 56
    mid = (t0 + t1) // 2
    for i, (label, v, reach) in enumerate((("HIGHLIGHT", k["highlight"], 4), ("SHADOW", k["shadow"], 4),
                                            ("COLOUR", k["color"], 4))):
        y = r.y + 1 + i * 8
        c.text(r.x, y, label, "text")
        c.rect(t0, y + 1, t1 - t0, 3, "shadow")
        kx = round(mid + v / reach * (t1 - t0) / 2)
        lo, hi = sorted((mid, kx))
        c.rect(lo, y + 1, hi - lo + 1, 3, "violet")
        c.vline(mid, y, 5, "dim")
        c.text(r.x2, y, signed(v), "white", align="right")
    grain = k.get("grain", {}).get("strength", "off")
    c.text(r.x, r.y + 25, "GRAIN", "text")
    c.text(r.x2, r.y + 25, grain.upper(), "white" if grain != "off" else "dim", align="right")


def history(c, r, b):
    """The step the click adds to the history, over the photo's import, as the History panel lists them."""
    c.icon(r.x, r.y + 1, "check", "green")
    c.text(r.x + 10, r.y + 1, "RECIPE", "green.light")
    c.text(r.x + 10, r.y + 9, CLICK.recipe, "white")
    c.hline(r.x, r.y + 18, r.w, "line")
    c.text(r.x + 10, r.y + 22, "IMPORT", "dim")


def amount_card(c, r, b):
    """The recipe's strength: its Amount, and a row of LEDs from 0 to 200."""
    v = round(amount_at(b))
    c.text(r.cx, r.y + 1, str(v), "gold.light", font="large", scale=2, align="center")
    n = 20
    x = r.cx - (3 * n - 1) // 2
    for k in range(n):
        c.rect(x + 3 * k, r.y + 21, 2, 4, "gold" if k < round(v / REACH * n) else "raised")
    c.text(x, r.y + 29, "0", "dim")
    c.text(x + 3 * n - 1, r.y + 29, str(REACH), "dim", align="right")


# Each card, from the beat it comes up on to the beat it goes: what the bar's words say, drawn.
CARDS = [(HOVERS[0].at, CLICK.press, "RECIPE CARD", "violet", recipe_card), (CLICK.press, DRAG.press, "HISTORY",
                                                                               "green", history),
         (DRAG.press, CUE["result"], "AMOUNT", "gold", amount_card)]


# ---------------------------------------------------------------- the dashboard

def amount_row(c, b):
    """The recipe's Amount: dim until a recipe is applied, then its knob at 100 and its value, the row lit
    while it's dragged."""
    made, lit = applied(b), DRAG.press <= b < DRAG.release
    y, (t0, t1) = AMOUNT_Y, TRACK
    if lit:
        c.rect(LABEL_X - 2, y - 2, RECIPES.w - 4, 9, "raised")
    c.text(LABEL_X, y, "AMOUNT", "white" if lit else "gold" if made else "dim")
    c.rect(t0, y + 1, t1 - t0, 3, "shadow")
    if made:
        v = amount_at(b)
        kx = knob(v)[0]
        c.rect(t0, y + 1, kx - t0 + 1, 3, "gold.light" if lit else "gold")
    c.vline(knob(100)[0], y, 5, "dim")
    if made:
        c.rect(kx - 1, y - 1, 3, 7, "white")
        c.text(RECIPES.x2 - 4, y, str(round(v)), "white", align="right")


def recipes_panel(c, b):
    """The Recipes panel: the Amount, the Camera Recipes group open, and its recipes, each with its swatch:
    the one previewed raised with the system accent at its edge, the one clicked sunk while pressed, and
    the one applied lit."""
    c.panel(*RECIPES, "RECIPES", color="sky")
    amount_row(c, b)
    c.text(LABEL_X, GROUP_Y, "▼", "dim")
    c.icon(ICON_X, GROUP_Y - 1, "folder", "muted")
    c.text(NAME_X, GROUP_Y, GROUP.upper(), "text")
    shown_ = previewing(b)
    for r in recipes():
        y = row_y(r.name)
        band = w.Rect(RECIPES.x + 2, y - 2, RECIPES.w - 4, ROW)
        ink = "text"
        if r.name == CLICK.recipe and CLICK.press <= b < CLICK.release:
            c.rect(*band, "green.dark")
            ink = "green.light"
        elif r.name == CLICK.recipe and applied(b):
            c.rect(*band, "green")
            c.hline(band.x, band.y, band.w, "green.light")
            ink = "shadow"
        elif r.name == shown_:
            c.rect(*band, "raised")
            c.vline(band.x, band.y, band.h, "sky")
            ink = "white"
        c.rect(ICON_X - 1, y - 2, SWATCH[0] + 2, SWATCH[1] + 2, "shadow")
        c.img.paste(swatch(r.name), (ICON_X, y - 1))
        c.text(NAME_X, y, r.name, ink)


def level(img):
    """How bright the photo is, as the LED level: it sits higher than the dusk's, so it reads at 1.4 times
    its mean where E01's reads at 2.2."""
    return min(1.0, float(np.asarray(img).mean()) / 255 * 1.4)


def dashboard(c, b):
    """Bars 1 to 5: the photo with the preview's pill, its histogram and level, the Recipes panel with the
    pointer, and the bar's card."""
    w.header(c, FEATURE)
    img = picture(look_at(b), EDITOR)
    r = w.photo_panel(c, PHOTO_PANEL, img, b, FILE, horizon=None)
    if previewing(b):
        w.tag(c, r, f"PREVIEW: {previewing(b)}")
    w.histogram(c, img, HIST)
    c.seg_column(*LEVEL, level(img), "gold", seg=2, gap=1)
    recipes_panel(c, b)
    for start, end, title, colour, body in CARDS:
        if start <= b < end:
            w.appear(c, w.between(b, start, start + 6 / w.PER_BEAT),
                     lambda c, t=title, col=colour, bd=body: w.card(c, CARD.x, CARD.y, t, col,
                                                                     lambda c, content: bd(c, content, b),
                                                                     w=CARD.w, h=CARD.h))
            if b < start + 0.5:
                c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, [f"{colour}.light", "white"],
                           seed=int(b * w.PER_BEAT))
    at = pointer_at(b)
    if at:
        w.pointer(c, *at[0], pressed=at[1])
    w.caption(c, caption_at(b))
    return []


def result(c, b):
    """Bar 6: the photo fills the stage, as opened, then developing into the edit on the flip."""
    w.header(c, FEATURE)
    before = picture(OPENED, RESULT)
    if b < CUE["flip"]:
        w.photo_panel(c, RESULT_PANEL, before, b, FILE, right="BEFORE", right_color="text", horizon=None)
    else:
        flat = w.canvas()
        w.header(flat, FEATURE)
        w.photo_panel(flat, RESULT_PANEL, before, b, FILE, right="BEFORE", right_color="text", horizon=None)
        r = w.photo_panel(c, RESULT_PANEL, picture(EDIT, RESULT), b, FILE, right="AFTER", right_color="gold",
                          horizon=None)
        w.develop(c, flat.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
        if b < CUE["flip"] + 1:
            c.sparkles(r.x, r.y, r.w, r.h, 26, ["gold.light", "white", "orange.light"], seed=int(b * w.PER_BEAT))
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
    """Each sound on screen, (beat, kind, pan): a soft tick as each preview changes and a click on CHROME
    STREET, panned with the pointer, a press, a tick a step and a release for the Amount's drag, panned
    with its knob, and a tick on the flip to after."""
    out = [(h.at, "tick", pan(target(h.recipe)[0])) for h in HOVERS]
    x = target(CLICK.recipe)[0]
    out += [(CLICK.press, "press", pan(x)), (CLICK.release, "release", pan(x))]
    out.append((DRAG.press, "press", pan(knob(AMOUNTS[0])[0])))
    for k, t in enumerate(DRAG.ticks, 1):
        out.append((t, "tick", pan(knob(AMOUNTS[k])[0])))
    out += [(DRAG.release, "release", pan(knob(AMOUNTS[-1])[0])), (CUE["flip"], "flip", 0.0)]
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(0), " / ".join(TITLE),
            "A deep hit, then the arpeggio over a kick muffled as if through a wall. The photo as opened and the "
            "Camera Recipes group."),
    w.Panel(2, 2.4, at(HOVERS[0].at + 0.5), CAPTIONS[0][1],
            "The riff starts; the pointer comes in and lands on CHROME STREET two beats later, with a soft tick as "
            "the preview changes; the RECIPE CARD shows its card."),
    w.Panel(3, 4.8, at(HOVERS[2].at + 0.5), " / ".join(CAPTIONS[1][1]),
            "A soft tick for each: BRIGHT SLIDE on the bar's first beat, CINEMA TEAL on its third; the card follows."),
    w.Panel(4, 7.2, at(CLICK.release + 0.5), CAPTIONS[2][1],
            "The full beat comes in; back on CHROME STREET with a tick, then a click a beat later; the Amount "
            "comes up at 100 and the HISTORY card shows the step."),
    w.Panel(5, 9.6, at(s4 + 3.2), CAPTIONS[3][1],
            "A click as the Amount's knob is pressed and a tick a beat as it goes down to 70; a roll into the stop."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), CAPTION_RESULT + "; before, then after at 13.2 s",
            "The drop and the sting; a tick and a burst of sparkles as the photo develops on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over the full beat."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
