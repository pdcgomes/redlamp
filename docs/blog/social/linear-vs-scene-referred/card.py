"""Linear vs scene-referred's card, drawn in pixel art with the pixel-graphics skill's kit.

    PYTHONPATH=~/.cursor/skills/pixel-graphics/scripts python3 docs/blog/social/linear-vs-scene-referred/card.py [--downloads]

The kit, pixelkit, needs Python 3.11+, Pillow and numpy, and ffmpeg for the MP4. This writes beside
itself (docs/blog/social/.gitignore keeps the renders out of git):
  card.gif   1200 × 630, for X: a 4.9 s loop that starts on the finished card, then draws both lines
             in again while the grey card's values count up; the finished card is up for 3 s of it
  card.mp4   the same loop as H.264, for LinkedIn
  card.png   the finished card
  thumb.jpg  560 × 315, the finished card on its own background, for the blog room

--downloads also copies the still, GIF and MP4 to ~/Downloads/redlamp-linear-vs-scene-referred.png,
.gif and .mp4, where the owner posts from.
"""
import math
import shutil
import sys
from pathlib import Path

from PIL import Image
from pixelkit import animate, ease_back, ease_out, lerp, load_theme, phase

KIT = Path(__file__).resolve().parent

KICKER = "FROM THE ARTICLES"
TITLE = ["LINEAR VS", "SCENE-REFERRED"]
DECK = [("LINEAR", ": HOW THE NUMBERS ARE WRITTEN"), ("SCENE-REFERRED", ": WHOSE LIGHT THEY DESCRIBE")]
SOURCE = "SOURCE: THE TONE CURVE IN REDLAMP'S DEVELOP.METAL, 9 OCT 2026"
ADDRESS = "REDLAMP.APP/ARTICLES"
GREY_ROW = [20.5, 35.7, 50.9, 66.8, 81.3, 96.5]  # a ColorChecker's grey row, in L*
LAMP = (
    ["..ooooo..", ".orrrrro.", "orrlllrro", "orllwllro", "orlllllro", "orrlllrro", ".orrrrro.", "..ooooo.."],
    {"o": "muted", "r": "red", "l": "red.light", "w": "white"},
)

# The tone curve's constants as Develop.metal had them on 9 October 2026; web/lib/tone.ts has the same.
GREY = 0.18
SHOULDER_START, SHOULDER_START_Y, SHOULDER_WIDTH_EV, SHOULDER_POWER = 0.54358851, 0.8, 2.40548194, 3.25537943
FILMIC_AT_ONE = 0.80379747

LEAD, INTRO, HOLD, FPS = 1.0, 2.4, 1.5, 20
PANEL = (226, 14, 158, 178)

THEME = load_theme()
THEME.brand["name"] = ADDRESS


def tone_curve(scene):
    if scene <= 0:
        return 0.0
    if scene <= SHOULDER_START:
        return scene * (2.51 * scene + 0.03) / (scene * (2.43 * scene + 0.59) + 0.14) / FILMIC_AT_ONE
    u = min(math.log2(scene / SHOULDER_START) / SHOULDER_WIDTH_EV, 1)
    return 1 - (1 - SHOULDER_START_Y) * (1 - u) ** SHOULDER_POWER


def lstar(y):
    return 116 * y ** (1 / 3) - 16 if y > 216 / 24389 else 24389 / 27 * y


def luminance(l):
    f = (l + 16) / 116
    return f**3 if f**3 > 216 / 24389 else 27 * l / 24389


def srgb_grey(l):
    y = luminance(l)
    v = 12.92 * y if y <= 0.0031308 else 1.055 * y ** (1 / 2.4) - 0.055
    level = round(255 * min(max(v, 0.0), 1.0))
    return (level, level, level)


def label(c, x, y, s, color, align="left"):
    w = c.measure(s)
    c.rect((x - w if align == "right" else x) - 1, y - 1, w + 2, 7, "panel")
    c.text(x, y, s, color, align=align)


def copy(c, t):
    x = 16
    mark_w, _ = c.mark(x, 14, LAMP)
    c.text(x + mark_w + 5, 16, KICKER, "dim")
    for i, line in enumerate(TITLE):
        c.text(x, 30 + 18 * i, line, "white", font="large", scale=2, shadow="line")
    c.strip(x, 66, max(c.measure(s, "large", 2) for s in TITLE), 2, [srgb_grey(l) for l in GREY_ROW])
    for i, (term, rest) in enumerate(DECK):
        c.spans(x, 76 + 8 * i, [(term, "white"), (rest, "text")])

    c.text(x, 125, "A GREY CARD AT 0.18 IN SCENE LIGHT", "dim")
    curve, straight = lstar(tone_curve(GREY)), lstar(GREY)
    stats = [(curve, curve * ease_out(phase(t, 0.3, 0.8)), "REDLAMP'S TONE CURVE", "red"),
             (straight, straight * ease_out(phase(t, 0.0, 0.4)), "NO CURVE", "white")]
    for final, value, name, color in stats:
        fw = c.measure(f"{final:.1f}", "large", 2)
        c.text(x + fw, 135, f"{value:.1f}", color, font="large", scale=2, shadow="line", align="right")
        c.text(x + fw + 3, 142, "L*", "dim", font="large")
        nw = c.text(x, 155, name, "text")
        x += max(fw + 3 + c.measure("L*", "large"), nw) + 16


def chart(c, t):
    p = c.panel(*PANEL, "REDLAMP'S TONE CURVE", color="red")
    left, right, top, base = p.x + 14, p.x2 - 2, p.y + 11, p.y2 - 17
    n = right - left

    def x(l):
        return left + round(l * n / 100)

    def y(l):
        return base - round(l * (base - top) / 100)

    for l in (25, 50, 75, 100):
        c.dots(left, y(l), n + 1, "line")
    c.hline(left, base, n + 1, "line")
    for l in (0, 50, 100):
        c.text(left - 3, y(l) - 2, str(l), "dim", align="right")
    c.text(x(lstar(GREY)), base + 4, "0.18", "dim", align="center")
    c.text(right + 1, base + 4, "1.0", "dim", align="right")
    c.text(p.x, p.y, "L*", "dim", font="large")
    c.text(right + 1, base + 12, "SCENE LIGHT", "dim", align="right")

    straight = [(left + i, y(i * 100 / n)) for i in range(n + 1)]
    curve = [(left + i, y(lstar(tone_curve(luminance(i * 100 / n))))) for i in range(n + 1)]
    drawn = round(n * ease_out(phase(t, 0.0, 0.4)))
    for i in range(drawn):
        if i % 6 < 3:
            c.line(*straight[i], *straight[i + 1], "text")
    gx, gy = x(lstar(GREY)), y(lstar(GREY))
    if drawn >= gx - left:
        c.vdots(gx, gy + 4, base - gy - 4, "dim")
    if drawn >= x(62) - left:
        label(c, x(62) + 2, y(62) + 4, "NO CURVE", "text")
    reach = round(n * ease_out(phase(t, 0.3, 0.8)))
    for i in range(reach):
        c.line(curve[i][0], curve[i][1] + 1, curve[i + 1][0], curve[i + 1][1] + 1, "red.dark")
    for i in range(reach):
        c.line(*curve[i], *curve[i + 1], "red")

    if drawn >= gx - left:
        c.circle(gx + 0.5, gy + 0.5, 2.5, "panel", outline="white")
    if phase(t, 0.0, 0.4) >= 1:
        label(c, gx + 5, gy - 2, f"{lstar(GREY):.1f}", "white")
    rising = phase(t, 0.45, 0.8)
    if rising > 0:
        cy = y(lstar(tone_curve(GREY)))
        ry = round(lerp(gy, cy, ease_back(rising)))
        c.vdots(gx, ry + 4, gy - ry - 7, "red.dark")
        c.circle(gx + 0.5, ry + 0.5, 2.5, "red", outline="red.light")
        if rising >= 1:
            label(c, gx - 4, cy - 2, f"{lstar(tone_curve(GREY)):.1f}", "red.light", align="right")


def draw(c, t):
    built = phase(t * (LEAD + INTRO), LEAD, LEAD + INTRO) if t * (LEAD + INTRO) >= LEAD else 1.0
    c.footer(SOURCE)
    copy(c, built)
    chart(c, built)


def main():
    for name in ("card.gif", "card.mp4"):
        animate(draw, KIT / name, preset="og", theme=THEME, seconds=LEAD + INTRO, fps=FPS, hold=HOLD)
    (KIT / "card-poster.png").replace(KIT / "card.png")
    still = Image.open(KIT / "card.png").convert("RGB")
    thumb = Image.new("RGB", (560, 315), THEME.rgb("bg"))
    thumb.paste(still.resize((560, 294), Image.LANCZOS), (0, 10))
    thumb.save(KIT / "thumb.jpg", quality=80, optimize=True)
    sizes = {kind: (KIT / f"card.{kind}").stat().st_size / 1048576 for kind in ("gif", "mp4")}
    print(f"card.png {still.width} × {still.height}; card.gif {sizes['gif']:.2f} MB, card.mp4 {sizes['mp4']:.2f} MB")
    if "--downloads" in sys.argv:
        for kind in ("png", "gif", "mp4"):
            target = Path.home() / "Downloads" / f"redlamp-{KIT.name}.{kind}"
            shutil.copyfile(KIT / f"card.{kind}", target)
            print(f"copied to {target}")


if __name__ == "__main__":
    main()
