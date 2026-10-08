#!/usr/bin/env python3
"""The performance card at the top of the README: Redlamp's key figures from
docs/performance/history.jsonl, drawn as docs/images/performance-card.svg (dark) and
performance-card-light.svg, with the README's <picture> and its alt text between the
`performance-card:begin` and `performance-card:end` markers.

    scripts/perf-card.py            # dry run: is the card current?
    scripts/perf-card.py --apply    # write the card and the README's block
    scripts/perf-card.py --check    # quiet; exit 1 when the card is stale (CI and the push gate)

Four columns: how responsive, how much memory, how much CPU and how big. Each shows the first two of
its metrics that have been measured, from the latest quiet record of each on MACHINE (records from a
release, for sizes, on any). A metric only ever measured under load shows its latest record, marked.
A column with nothing measured is left out. scripts/perf-history.py redraws the card when it adds a
record, so the card changes in the commit that records the figures.
"""

import argparse
import datetime
import difflib
import html
import json
import pathlib
import re
import sys
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[1]
HISTORY = ROOT / "docs/performance/history.jsonl"
METRICS = ROOT / "docs/performance/metrics.json"
README = ROOT / "README.md"
CARDS = {"dark": ROOT / "docs/images/performance-card.svg", "light": ROOT / "docs/images/performance-card-light.svg"}
BEGIN, END = "<!-- performance-card:begin -->", "<!-- performance-card:end -->"
PAGE = "https://redlamp.app/performance"
# The Mac the README quotes. Another Mac's runs are that Mac's own series (ARC-09), never mixed in.
MACHINE = "Apple M1 Ultra"
FRAME_120HZ = 1000 / 120
# The least memory an Apple silicon Mac has, in the MB (2^20 bytes) the footprint is counted in.
SMALLEST_MAC = 8 * 1024


@dataclass
class Column:
    title: str
    metrics: list[str]
    visual: str | None = None


COLUMNS = [
    Column("Responsive", ["render-fit", "open", "drag-p99"], "frame"),
    Column("Memory", ["footprint-photo", "footprint-peak", "folders-peak-memory", "detail-memory-24mp"], "memory"),
    Column("CPU", ["idle-cpu", "idle-wakeups", "drag-cpu"], "cpu"),
    Column("Size", ["download-size", "app-size"], "models"),
]

# What each figure is, in the few words under it on the card.
CAPTIONS = {
    "render-fit": "to render a slider change",
    "open": "to open a 24 MP raw",
    "drag-p99": "main thread p99, dragging",
    "footprint-photo": "with a 24 MP photo open",
    "footprint-peak": "peak, opening and editing",
    "folders-peak-memory": "peak, browsing 50,000 photos",
    "detail-memory-24mp": "GPU, 1:1 with noise reduction",
    "idle-cpu": "of one core when idle",
    "idle-wakeups": "wakeups a second when idle",
    "drag-cpu": "of one core, dragging a slider",
    "download-size": "to download",
    "app-size": "installed",
}

THEMES = {
    "dark": {
        "background": "#0A0707", "border": "rgba(243,238,232,0.10)", "rule": "rgba(243,238,232,0.09)",
        "text": "#F3EEE8", "mute": "#A89D98", "dim": "#857A75",
        "track": "rgba(243,238,232,0.08)", "fill": "#D9D0CB", "fill2": "rgba(217,208,203,0.42)",
        "tick": "rgba(243,238,232,0.40)", "glow": "#E0402E", "glowOpacity": 0.20,
        "ring": "#D9D0CB", "disc": "#E0402E",
    },
    "light": {
        "background": "#F3EEE8", "border": "rgba(26,20,20,0.12)", "rule": "rgba(26,20,20,0.10)",
        "text": "#1A1414", "mute": "#4F4744", "dim": "#6F6561",
        "track": "rgba(26,20,20,0.08)", "fill": "#3A3230", "fill2": "rgba(58,50,48,0.35)",
        "tick": "rgba(26,20,20,0.40)", "glow": "#D8352A", "glowOpacity": 0.06,
        "ring": "#1A1414", "disc": "#D8352A",
    },
}

WIDTH, HEIGHT, PAD = 880, 320, 32
GUTTER = 28
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"
# Rough advances in ems for the fonts above (the widest of them, Segoe UI), to keep text inside its column.
NARROW, WIDE = set("iljtfr.,:;'’|!() ·"), set("mwMW%")


def estimated_width(content: str, size: float, spacing: float = 0) -> float:
    ems = 0.0
    for char in html.unescape(content):
        if char in NARROW:
            ems += 0.3
        elif char in WIDE:
            ems += 0.85
        elif char.isdigit():
            ems += 0.6
        elif char.isupper():
            ems += 0.68
        else:
            ems += 0.55
    return ems * size * 1.05 + spacing * len(content)


class Overflow(Exception):
    pass


def fits(content: str, size: float, width: float, spacing: float = 0) -> str:
    if estimated_width(content, size, spacing) > width:
        raise Overflow(f"“{html.unescape(content)}” at {size:g} px is wider than its {width:.0f} px")
    return content


@dataclass
class Figure:
    metric: dict
    record: dict

    @property
    def id(self) -> str:
        return self.metric["id"]

    @property
    def value(self) -> float:
        return self.record["metrics"][self.id]["value"]

    @property
    def noisy(self) -> bool:
        return bool(self.record.get("noisy"))


def records() -> list[dict]:
    lines = HISTORY.read_text().splitlines() if HISTORY.exists() else []
    return sorted((json.loads(line) for line in lines if line.strip()), key=lambda r: datetime.datetime.fromisoformat(r["date"]))


def latest(history: list[dict], metric: dict) -> Figure | None:
    """The metric's latest quiet record on MACHINE (or from a release), else its latest under load."""
    having = [record for record in history if metric["id"] in record["metrics"]
              and (record["source"] == "release" or record["machine"].get("chip") == MACHINE)]
    quiet = [record for record in having if not record.get("noisy")]
    chosen = (quiet or having)[-1:] if having else []
    return Figure(metric, chosen[0]) if chosen else None


def number(value: float, unit: str) -> tuple[str, str]:
    """The figure and its unit as the card shows them: 1.8 ms, 160 ms, 317 MB, 1.3 GB, 0.12%."""
    if unit == "MB" and value >= 1000:
        value, unit = value / 1024, "GB"
    if unit == "%":
        digits = 2 if value < 1 else 1 if value < 10 else 0
    elif unit in ("ms", "/s", "MB"):
        digits = 1 if value < (100 if unit == "MB" else 10) else 0
    else:
        digits = 1
    text = f"{value:,.{digits}f}"
    if digits and unit in ("ms", "/s") and text.endswith(".0"):
        text = text[:-2]
    if 0 < value < 10 ** -digits:
        text = f"<{10 ** -digits:g}"
    elif value == 0:
        text = "0"
    return text, {"/s": "", "fps": " fps"}.get(unit, unit)


def esc(text: str) -> str:
    """For text and double-quoted attributes."""
    return html.escape(text, quote=False).replace('"', "&quot;")


def day(record: dict) -> datetime.date:
    return datetime.datetime.fromisoformat(record["date"]).date()


def span(days: list[datetime.date]) -> str:
    first, last = min(days), max(days)
    if first == last:
        return f"{last.day} {last:%b %Y}"
    if first.year == last.year:
        return f"{first.day} {first:%b} – {last.day} {last:%b %Y}"
    return f"{first.day} {first:%b %Y} – {last.day} {last:%b %Y}"


def plan(history: list[dict], metrics: dict[str, dict]) -> list[tuple[Column, list[Figure], dict[str, Figure]]]:
    """Each column with figures, its two shown figures and every figure its visual may draw."""
    out = []
    for column in COLUMNS:
        found = {mid: figure for mid in column.metrics if mid in metrics and (figure := latest(history, metrics[mid]))}
        shown = [found[mid] for mid in column.metrics if mid in found][:2]
        if shown:
            out.append((column, shown, found))
    return out


def text(x: float, y: float, content: str, *, size: float, color: str, weight: int = 400, anchor: str = "start",
         spacing: float = 0, klass: str = "") -> str:
    attributes = f'x="{x:g}" y="{y:g}" font-size="{size:g}" fill="{color}" font-weight="{weight}"'
    if anchor != "start":
        attributes += f' text-anchor="{anchor}"'
    if spacing:
        attributes += f' letter-spacing="{spacing:g}"'
    if klass:
        attributes += f' class="{klass}"'
    return f"<text {attributes}>{content}</text>"


def value_text(x: float, y: float, figure: Figure, theme: dict, *, size: float, unit_size: float) -> str:
    shown, unit = number(figure.value, figure.metric["unit"])
    gap = "" if unit in ("%", "") else " "
    marker = f'<tspan font-size="{unit_size:g}" fill="{theme["dim"]}" dx="1">*</tspan>' if figure.noisy else ""
    unit_part = f'<tspan font-size="{unit_size:g}" font-weight="500" fill="{theme["mute"]}">{gap}{esc(unit)}</tspan>' if unit else ""
    return text(x, y, f"{esc(shown)}{unit_part}{marker}", size=size, color=theme["text"], weight=600,
                spacing=-0.4 if size > 20 else 0, klass="n")


def bar(x: float, y: float, width: float, theme: dict, fills: list[tuple[float, str]], ticks: list[float]) -> list[str]:
    """A track `width` wide with fills (fractions of it, widest first) and tick lines at fractions."""
    parts = [f'<rect x="{x:g}" y="{y:g}" width="{width:g}" height="6" rx="3" fill="{theme["track"]}"/>']
    for fraction, color in fills:
        filled = max(2.0, min(fraction, 1.0) * width)
        parts.append(f'<rect x="{x:g}" y="{y:g}" width="{filled:.1f}" height="6" rx="3" fill="{color}"/>')
    for fraction in ticks:
        tx = x + min(fraction, 1.0) * width
        parts.append(f'<rect x="{tx - 0.5:.1f}" y="{y - 4:g}" width="1" height="14" fill="{theme["tick"]}"/>')
    return parts


def megabytes(figure: Figure) -> float:
    return figure.value * 1024 if figure.metric["unit"] == "GB" else figure.value


def visual(column: Column, shown: list[Figure], found: dict[str, Figure], x: float, y: float, width: float,
           theme: dict) -> list[str]:
    label = lambda content: text(x, y + 25, fits(esc(content), 11, width), size=11, color=theme["dim"])  # noqa: E731
    if column.visual == "frame" and "render-fit" in found:
        render = found["render-fit"].value
        top = FRAME_120HZ if render <= FRAME_120HZ else 2 * FRAME_120HZ
        ticks = [FRAME_120HZ / top] + ([1.0] if top > FRAME_120HZ else [])
        return [*bar(x, y, width, theme, [(render / top, theme["fill"])], ticks),
                label(f"{render / FRAME_120HZ:.0%} of a 120 Hz frame")]
    if column.visual == "memory":
        fills = [(megabytes(figure) / SMALLEST_MAC, theme["fill2"] if index else theme["fill"])
                 for index, figure in enumerate(shown)]
        return [*bar(x, y, width, theme, sorted(fills, key=lambda f: -f[0]), [1.0]),
                label("of the smallest Mac’s 8 GB")]
    if column.visual == "cpu" and "drag-cpu" in found and "idle-cpu" in found:
        idle, drag = found["idle-cpu"].value, found["drag-cpu"].value
        top = max(100.0, drag)
        return [*bar(x, y, width, theme, [(drag / top, theme["fill2"]), (idle / top, theme["fill"])], [100 / top]),
                label(f"of one core; {number(drag, '%')[0]}% dragging")]
    if column.visual == "models":
        return [label("AI models download on first use")]
    return []


def alt_text(columns: list[tuple[Column, list[Figure], dict[str, Figure]]], days: list[datetime.date]) -> str:
    parts = []
    for _, shown, _ in columns:
        for figure in shown:
            value, unit = number(figure.value, figure.metric["unit"])
            gap = "" if unit in ("%", "") else " "
            parts.append(f"{value}{gap}{unit} {CAPTIONS[figure.id]}{' (measured under load)' if figure.noisy else ''}")
    return (f"Redlamp's measured performance on an {MACHINE} with a Release build, {span(days)}: "
            + "; ".join(parts) + ".")


def card(theme_name: str, history: list[dict], metrics: dict[str, dict]) -> str:
    theme = THEMES[theme_name]
    columns = plan(history, metrics)
    used = [figure for _, _, found in columns for figure in found.values()]
    days = [day(figure.record) for figure in used]
    count = len(columns)
    width = (WIDTH - 2 * PAD - (count - 1) * GUTTER) / count
    body: list[str] = []
    for index, (column, shown, found) in enumerate(columns):
        x = PAD + index * (width + GUTTER)
        if index:
            body.append(f'<rect x="{x - GUTTER / 2 - 0.5:.1f}" y="100" width="1" height="160" fill="{theme["rule"]}"/>')
        body.append(text(x, 112, fits(esc(column.title.upper()), 10.5, width, 1.4), size=10.5, color=theme["mute"],
                         weight=600, spacing=1.4))
        hero = shown[0]
        body.append(value_text(x, 150, hero, theme, size=30, unit_size=15))
        body.append(text(x, 170, fits(esc(CAPTIONS[hero.id]), 12, width), size=12, color=theme["mute"]))
        body += visual(column, shown, found, x, 186, width, theme)
        if len(shown) > 1:
            body.append(value_text(x, 240, shown[1], theme, size=16, unit_size=12))
            body.append(text(x, 258, fits(esc(CAPTIONS[shown[1].id]), 12, width), size=12, color=theme["mute"]))

    noisy = any(figure.noisy for _, shown, _ in columns for figure in shown)
    first = min(day(record) for record in history)
    footer_left = (f"Latest quiet records in docs/performance/history.jsonl, {span(days)}"
                   + (" · * measured under load" if noisy else ""))
    footer_right = f"{len(metrics)} metrics tracked since {first.day} {first:%b %Y}"
    if estimated_width(footer_left, 11) + estimated_width(footer_right, 11) + 24 > WIDTH - 2 * PAD:
        raise Overflow(f"the footer's two halves overlap: “{footer_left}” and “{footer_right}”")
    alt = alt_text(columns, days)
    mark = (f'<g transform="translate({PAD} 24) scale(0.5417)">'
            f'<mask id="rl-holes" maskUnits="userSpaceOnUse" x="0" y="0" width="48" height="48">'
            f'<rect width="48" height="48" fill="#fff"/><circle cx="19" cy="19" r="2.6" fill="#000"/>'
            f'<circle cx="24" cy="4.4" r="1.25" fill="#000"/><circle cx="40.97" cy="33.8" r="1.25" fill="#000"/>'
            f'<circle cx="7.03" cy="33.8" r="1.25" fill="#000"/></mask><g mask="url(#rl-holes)">'
            f'<circle cx="24" cy="24" r="19.6" fill="none" stroke="{theme["ring"]}" stroke-width="4.8"/>'
            f'<circle cx="24" cy="24" r="12.6" fill="{theme["disc"]}"/></g></g>')
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" '
        f'role="img" aria-labelledby="rl-title rl-desc">',
        "<title id=\"rl-title\">Redlamp's measured performance</title>",
        f'<desc id="rl-desc">{esc(alt)}</desc>',
        f'<style>text{{font-family:{FONT}}}.n{{font-variant-numeric:tabular-nums}}</style>',
        '<defs><radialGradient id="rl-glow" cx="45" cy="37" r="420" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{theme["glow"]}" stop-opacity="{theme["glowOpacity"]}"/>'
        f'<stop offset="0.35" stop-color="{theme["glow"]}" stop-opacity="{theme["glowOpacity"] * 0.3:.3f}"/>'
        f'<stop offset="1" stop-color="{theme["glow"]}" stop-opacity="0"/></radialGradient>'
        f'<clipPath id="rl-card"><rect width="{WIDTH}" height="{HEIGHT}" rx="16"/></clipPath></defs>',
        '<g clip-path="url(#rl-card)">',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{theme["background"]}"/>',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="url(#rl-glow)"/>',
        mark,
        text(PAD + 38, 37, "Measured performance", size=16, color=theme["text"], weight=600),
        text(PAD + 38, 55, esc(f"{MACHINE} · Release build · recorded in the repository as the work lands"),
             size=12, color=theme["mute"]),
        text(WIDTH - PAD, 37, "redlamp.app/performance", size=12, color=theme["mute"], anchor="end"),
        f'<rect x="{PAD}" y="76" width="{WIDTH - 2 * PAD}" height="1" fill="{theme["rule"]}"/>',
        *body,
        f'<rect x="{PAD}" y="278" width="{WIDTH - 2 * PAD}" height="1" fill="{theme["rule"]}"/>',
        text(PAD, 301, esc(footer_left), size=11, color=theme["dim"]),
        text(WIDTH - PAD, 301, esc(footer_right), size=11, color=theme["dim"], anchor="end"),
        "</g>",
        f'<rect x="0.5" y="0.5" width="{WIDTH - 1}" height="{HEIGHT - 1}" rx="15.5" fill="none" stroke="{theme["border"]}"/>',
        "</svg>",
        "",
    ])


def readme_block(history: list[dict], metrics: dict[str, dict]) -> str:
    columns = plan(history, metrics)
    days = [day(figure.record) for _, _, found in columns for figure in found.values()]
    dark, light = (path.relative_to(ROOT).as_posix() for path in (CARDS["dark"], CARDS["light"]))
    return "\n".join([
        BEGIN,
        '<p align="center">',
        f'  <a href="{PAGE}">',
        "    <picture>",
        f'      <source media="(prefers-color-scheme: light)" srcset="{light}">',
        f'      <img src="{dark}" width="{WIDTH}" alt="{esc(alt_text(columns, days))}">',
        "    </picture>",
        "  </a>",
        "</p>",
        END,
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write the card and the README's block")
    mode.add_argument("--check", action="store_true", help="exit 1 when the card or the README's block is stale")
    options = parser.parse_args()

    history = records()
    metrics = {metric["id"]: metric for metric in json.loads(METRICS.read_text())["metrics"]}
    missing = sorted({mid for column in COLUMNS for mid in column.metrics} - set(metrics))
    if missing:
        sys.exit(f"the card names metrics missing from docs/performance/metrics.json: {', '.join(missing)}")
    try:
        wanted = {path: card(name, history, metrics) for name, path in CARDS.items()}
    except Overflow as overflow:
        sys.exit(f"The performance card doesn't fit: {overflow}. Shorten it in scripts/perf-card.py.")

    readme = README.read_text()
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    if not pattern.search(readme):
        sys.exit(f"README.md has no {BEGIN} … {END} block")
    wanted[README] = pattern.sub(lambda _: readme_block(history, metrics), readme, count=1)

    stale = {path: content for path, content in wanted.items()
             if not path.exists() or path.read_text() != content}
    if options.check:
        if stale:
            names = ", ".join(path.relative_to(ROOT).as_posix() for path in stale)
            print(f"The performance card is out of step with the history ({names}): run scripts/perf-card.py --apply",
                  file=sys.stderr)
            return 1
        return 0
    if not stale:
        print("The performance card is current.")
        return 0
    for path, content in stale.items():
        name = path.relative_to(ROOT).as_posix()
        if options.apply:
            path.write_text(content)
            print(f"Wrote {name}.")
        else:
            old = path.read_text().splitlines() if path.exists() else []
            diff = list(difflib.unified_diff(old, content.splitlines(), name, name, lineterm="", n=0))
            print("\n".join(diff[:40]) + ("\n…" if len(diff) > 40 else ""))
    if not options.apply:
        print("Dry run: --apply writes it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
