#!/usr/bin/env python3
"""Builds the Redlamp logo SVGs in docs/brand/logo: the Fixed lens mark and the lockups.

The wordmark is "Redlamp" in Inter Display SemiBold, outlined so the files don't depend on
an installed font. Needs fontTools (`pip install fonttools`) and InterDisplay-SemiBold.ttf
from the Inter 4.1 release (https://github.com/rsms/inter/releases, extras/ttf/).

    scripts/build-logo.py path/to/InterDisplay-SemiBold.ttf [output-dir]
"""

import math
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

RUBY = "#E0402E"
RUBY_ON_LIGHT = "#D8352A"
RING_ON_DARK = "#D9D0CB"
PAPER = "#F3EEE8"
INK = "#1A1414"

TONES = {
    "dark": {"ring": RING_ON_DARK, "disc": RUBY, "word": PAPER},
    "light": {"ring": INK, "disc": RUBY_ON_LIGHT, "word": INK},
    "white": {"ring": PAPER, "disc": PAPER, "word": PAPER},
    "black": {"ring": INK, "disc": INK, "word": INK},
}
SUFFIXES = {"dark": "", "light": "-light", "white": "-white", "black": "-black"}


def num(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def mark(tone, ox, oy, scale, uid):
    """The Fixed lens mark in a 48 x 48 box at (ox, oy). The highlight and screws are holes."""
    t = TONES[tone]
    cuts = [(19, 19, 2.6)]
    for deg in (-90, 30, 150):
        a = math.radians(deg)
        cuts.append((24 + 19.6 * math.cos(a), 24 + 19.6 * math.sin(a), 1.25))
    holes = "".join(f'<circle cx="{num(x)}" cy="{num(y)}" r="{num(r)}" fill="#000"/>' for x, y, r in cuts)
    return (
        f'<g transform="translate({num(ox)} {num(oy)}) scale({num(scale)})">'
        f'<mask id="{uid}" maskUnits="userSpaceOnUse" x="0" y="0" width="48" height="48">'
        f'<rect width="48" height="48" fill="#fff"/>{holes}</mask>'
        f'<g mask="url(#{uid})">'
        f'<circle cx="24" cy="24" r="19.6" fill="none" stroke="{t["ring"]}" stroke-width="4.8"/>'
        f'<circle cx="24" cy="24" r="12.6" fill="{t["disc"]}"/>'
        "</g></g>"
    )


class Wordmark:
    def __init__(self, font_path, text="Redlamp", tracking_em=-0.02):
        font = TTFont(font_path)
        self.upem = font["head"].unitsPerEm
        self.cap = font["OS/2"].sCapHeight
        self.glyphs = font.getGlyphSet()
        self.cmap = font.getBestCmap()
        self.hmtx = font["hmtx"]
        self.text = text
        self.tracking = tracking_em * self.upem

    def width(self, size):
        units = sum(self.hmtx[self.cmap[ord(ch)]][0] for ch in self.text) + self.tracking * (len(self.text) - 1)
        return units * size / self.upem

    def cap_height(self, size):
        return self.cap * size / self.upem

    def path(self, x, baseline, size):
        s = size / self.upem
        pen = SVGPathPen(self.glyphs)
        cursor = 0.0
        for ch in self.text:
            name = self.cmap[ord(ch)]
            self.glyphs[name].draw(TransformPen(pen, (s, 0, 0, -s, x + cursor * s, baseline)))
            cursor += self.hmtx[name][0] + self.tracking
        return pen.getCommands()


def svg(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{num(width)}" height="{num(height)}" '
        f'viewBox="0 0 {num(width)} {num(height)}" role="img" aria-label="Redlamp">'
        f"<title>Redlamp</title>{body}</svg>\n"
    )


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "docs", "brand", "logo")
    os.makedirs(out, exist_ok=True)
    word = Wordmark(sys.argv[1])

    def write(name, content):
        with open(os.path.join(out, name), "w") as fh:
            fh.write(content)

    for tone, suffix in SUFFIXES.items():
        write(f"redlamp-mark{suffix}.svg", svg(48, 48, mark(tone, 0, 0, 1, "m")))

    # Horizontal: the wordmark's cap height is about half the mark's, centred on it.
    size, gap = 34, 12
    wx = 48 + gap
    baseline = 24 + word.cap_height(size) / 2
    for tone, suffix in SUFFIXES.items():
        body = mark(tone, 0, 0, 1, "m") + f'<path d="{word.path(wx, baseline, size)}" fill="{TONES[tone]["word"]}"/>'
        write(f"redlamp-lockup{suffix}.svg", svg(wx + word.width(size), 48, body))

    # Stacked: a 64-unit mark above the wordmark, both centred.
    ssize = 30
    sw = word.width(ssize)
    swidth = max(sw, 64)
    sbaseline = 64 + 16 + word.cap_height(ssize)
    for tone in ("dark", "light"):
        body = mark(tone, (swidth - 64) / 2, 0, 64 / 48, "m") + (
            f'<path d="{word.path((swidth - sw) / 2, sbaseline, ssize)}" fill="{TONES[tone]["word"]}"/>'
        )
        write(f"redlamp-lockup-stacked{SUFFIXES[tone]}.svg", svg(swidth, sbaseline + 2, body))


main()
