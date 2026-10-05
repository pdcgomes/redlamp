#!/usr/bin/env python3
"""Captures the home page's star nudge (docs/brand/star-nudge.md) from a locally served build, and checks it.

usage: capture-nudge.py [url]
       capture-nudge.py http://localhost:3123/

Steps the page with Playwright's fake clock, so every frame lands at an exact time in the sequence, and
writes docs/brand/star-nudge/stages.png (six stills at 1440 px) and tremble.gif (the lamp as it charges).
Then, at a desktop and a phone width, it drags and throws the sign, and reports whether a drag stayed
off its link, a click followed it, scrolling on reeled the sign in, and anything overflowed sideways.
Needs Playwright and Pillow (pip install playwright pillow) and Google Chrome, which it drives with the
flags Chrome needs to start inside the agent sandbox.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ARGS = ["--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
OUT = Path(__file__).resolve().parents[3] / "docs" / "brand" / "star-nudge"
FONT = "/System/Library/Fonts/Helvetica.ttc"
STAGES = [
    (1.4, "Energy gathers behind the lamp"),
    (2.35, "It focuses, and the lamp trembles hardest"),
    (2.62, "The shot leaves from behind the tile"),
    (3.0, "It arcs over the bar into the button"),
    (3.32, "Light runs round the button as it settles"),
    (9.0, "The sign hangs under the star count"),
]
# The button's glow and the star's spin are Web Animations, which run on the browser's own clock:
# each is held at the fake clock's time since it started.
SYNC = """() => {
  const now = performance.now();
  window.__started = window.__started || new Map();
  for (const animation of document.getAnimations()) {
    if (animation.constructor.name === "CSSAnimation") continue;
    if (!window.__started.has(animation)) window.__started.set(animation, now);
    animation.pause();
    animation.currentTime = Math.max(0, now - window.__started.get(animation));
  }
}"""


def begin(page, url):
    """Loads the page with its clock paused, then steps it until the nudge mounts; returns that time."""
    page.clock.install()
    page.goto(url, wait_until="networkidle")
    page.clock.pause_at(page.evaluate("Date.now()") + 20)
    page.wait_for_timeout(1300)  # real time, for the hero's CSS rise
    for _ in range(400):
        if page.evaluate("!!document.querySelector('canvas[aria-hidden]')"):
            page.wait_for_timeout(100)
            return page.evaluate("performance.now()")
        page.clock.run_for(10)
    raise SystemExit("The nudge never started: is the page served, and was it already played in this tab?")


def advance(page, start, seconds):
    behind = start + seconds * 1000 - page.evaluate("performance.now()")
    if behind > 0:
        page.clock.run_for(int(behind))
    page.evaluate(SYNC)


def capture(browser, url):
    page = browser.new_context(viewport={"width": 1440, "height": 900}, device_scale_factor=1).new_page()
    start = begin(page, url)
    box = page.locator('[data-star-nudge="lamp"]').bounding_box()
    lamp = {"x": box["x"] + box["width"] / 2 - 140, "y": box["y"] + box["height"] / 2 - 120, "width": 280, "height": 240}
    stills, frames = {}, []
    times = sorted({round(i / 15, 4) for i in range(41)} | {t for t, _ in STAGES})
    for t in times:
        advance(page, start, t)
        if t <= 2.67:
            frames.append(Image.open(_shot(page, lamp)).convert("RGB"))
        if t in dict(STAGES):
            stills[t] = Image.open(_shot(page, {"x": 560, "y": 0, "width": 880, "height": 320})).convert("RGB")
    page.close()

    OUT.mkdir(parents=True, exist_ok=True)
    font, bold = ImageFont.truetype(FONT, 21), ImageFont.truetype(FONT, 21, index=1)
    w, h, gap, caption = 880, 320, 16, 46
    sheet = Image.new("RGB", (2 * w + 3 * gap, 3 * (h + caption + gap) + gap - gap), (18, 13, 12))
    draw = ImageDraw.Draw(sheet)
    for i, (t, text) in enumerate(STAGES):
        x, y = gap + (i % 2) * (w + gap), gap + (i // 2) * (h + caption + gap)
        sheet.paste(stills[t], (x, y))
        label = f"{t:g} s"
        draw.text((x + 2, y + h + 12), label, font=bold, fill=(243, 238, 232))
        draw.text((x + 2 + draw.textlength(label + "   ", font=bold), y + h + 12), text, font=font, fill=(168, 157, 152))
    sheet.save(OUT / "stages.png", optimize=True)
    gif = [frame.quantize(colors=96, method=Image.Quantize.MEDIANCUT) for frame in frames]
    gif[0].save(OUT / "tremble.gif", save_all=True, append_images=gif[1:], duration=66, loop=0, optimize=True)
    print(f"wrote {OUT / 'stages.png'} and {OUT / 'tremble.gif'} ({len(gif)} frames)")


def _shot(page, clip):
    path = "/tmp/capture-nudge-frame.png"
    page.screenshot(path=path, clip=clip)
    return path


def check(browser, url, name, viewport, scale):
    context = browser.new_context(viewport=viewport, device_scale_factor=scale)
    page = context.new_page()
    requests = []
    page.route("https://github.com/**", lambda route: (requests.append(route.request.url), route.abort()))
    start = begin(page, url)
    overflow = 0
    for t in [1.0, 2.5, 3.3, 4.6, 9.0]:
        advance(page, start, t)
        overflow = max(overflow, page.evaluate("document.documentElement.scrollWidth - window.innerWidth"))
    sign = page.locator("a", has_text="Please star us")
    box = sign.bounding_box()
    x, y = box["x"] + box["width"] * 0.7, box["y"] + box["height"] * 0.6
    page.mouse.move(x, y)
    page.mouse.down()
    for i in range(1, 13):
        page.mouse.move(x - 9 * i, y + 4 * i)
        page.clock.run_for(16)
    page.mouse.up()
    page.clock.run_for(800)
    page.wait_for_timeout(300)
    dragged = list(requests)
    page.clock.run_for(8000)
    box = sign.bounding_box()
    page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
    page.wait_for_timeout(600)
    clicked = requests[len(dragged):]
    page.close()

    page = context.new_page()
    start = begin(page, url)
    advance(page, start, 6.5)
    page.mouse.move(viewport["width"] / 2, viewport["height"] / 2)
    page.mouse.wheel(0, 700)
    page.wait_for_timeout(300)
    page.clock.run_for(600)
    page.wait_for_timeout(300)
    reeled = page.locator("a", has_text="Please star us").count() == 0
    context.close()
    return {
        "overflow px": overflow,
        "a drag stayed off the link": not dragged,
        "a click followed it": any("github.com" in url for url in clicked),
        "scrolling on reeled it in": reeled,
    }


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:3123/"
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=CHROME, headless=True, args=ARGS)
        capture(browser, url)
        report = {
            "desktop": check(browser, url, "desktop", {"width": 1440, "height": 900}, 1),
            "phone": check(browser, url, "phone", {"width": 390, "height": 844}, 2),
        }
        browser.close()
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
