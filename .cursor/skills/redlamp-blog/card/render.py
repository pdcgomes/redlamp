"""Renders a blog post's social card from its kit folder's card.json.

    python3 -m venv /tmp/rl-card && /tmp/rl-card/bin/pip install --quiet playwright pillow
    /tmp/rl-card/bin/python .cursor/skills/redlamp-blog/card/render.py docs/blog/social/<slug> [--still] [--downloads]

Writes into the kit folder, beside card.json (docs/blog/social/.gitignore keeps the renders out of git):
  card.png   3200 × 1800, the still (16:9 at 2x)
  card.gif   1200 × 675, a 6.4 s loop that starts on the finished card, for X
  card.mp4   1920 × 1080, the same loop as H.264, for LinkedIn and anywhere a GIF won't play
  thumb.jpg  560 × 315, the still for the blog room

--still renders only card.png and thumb.jpg, to check the words quickly. --downloads also copies the
still, GIF and MP4 to ~/Downloads/redlamp-<slug>.png, .gif and .mp4, where the owner posts from.

It drives the installed Google Chrome with the flags the agent sandbox needs, and needs ffmpeg. It
stops if Inter didn't load, if a line runs past the card's margins, or if the text comes within
40 px of the lockup, and warns when the GIF is over X's 5 MB limit for GIFs posted from a phone.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

CARD = Path(__file__).resolve().with_name("card.html")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FLAGS = ["--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
         "--allow-file-access-from-files"]
FPS, LOOP, START = 25, 6.4, 4.3
WIDTH, MARGIN, CLEARANCE = 1600, 120, 40
GIF_LIMIT = 5 * 1024 * 1024

MEASURE = """() => {
  const width = (node) => { const r = document.createRange(); r.selectNodeContents(node); return r.getBoundingClientRect().width; };
  const lines = [...document.querySelectorAll('.line')].map((node) => [node.textContent, Math.round(width(node))]);
  const lockup = document.getElementById('lockup').getBoundingClientRect().bottom;
  const body = document.getElementById('eyebrow').getBoundingClientRect().top;
  const fonts = [...document.fonts].map((font) => `${font.family}:${font.status}`);
  return { lines, gap: Math.round(body - lockup), fonts };
}"""


def open_card(browser, card, scale):
    page = browser.new_context(viewport={"width": WIDTH, "height": 900}, device_scale_factor=scale).new_page()
    page.goto(CARD.as_uri())
    page.evaluate("document.fonts.ready")
    page.evaluate("(card) => window.build(card)", card)
    page.evaluate("document.fonts.ready")
    page.wait_for_timeout(300)
    return page


def check(page):
    found = page.evaluate(MEASURE)
    problems = []
    if not any(font.startswith("Inter:loaded") for font in found["fonts"]):
        problems.append(f"Inter didn't load: {found['fonts']}")
    for text, width in found["lines"]:
        if width > WIDTH - 2 * MARGIN:
            problems.append(f"'{text}' is {width} px wide, {width - (WIDTH - 2 * MARGIN)} px past the margin")
    if found["gap"] < CLEARANCE:
        problems.append(f"the text comes within {found['gap']} px of the lockup (needs {CLEARANCE})")
    widest = max(width for _, width in found["lines"])
    print(f"layout: widest line {widest} of {WIDTH - 2 * MARGIN} px, {found['gap']} px below the lockup")
    if problems:
        sys.exit("card.json needs changing: " + "; ".join(problems))


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    kit = Path(args[0]).resolve()
    card = json.loads((kit / "card.json").read_text())
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=CHROME, headless=True, args=FLAGS)
        page = open_card(browser, card, 2)
        check(page)
        page.screenshot(path=str(kit / "card.png"))
        still = Image.open(kit / "card.png").convert("RGB")
        still.resize((560, 315), Image.LANCZOS).save(kit / "thumb.jpg", quality=80, optimize=True)
        print(f"card.png {still.width} × {still.height}")
        if "--still" not in sys.argv:
            frames = Path(tempfile.mkdtemp(prefix="rl-card-"))
            page = open_card(browser, card, 1.2)
            count = round(FPS * LOOP)
            for index in range(count):
                page.evaluate(f"window.frame({(START + index / FPS) % LOOP})")
                page.screenshot(path=str(frames / f"{index:04d}.png"))
            pattern = str(frames / "%04d.png")
            ffmpeg("-framerate", str(FPS), "-i", pattern, "-vf",
                   "scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];"
                   "[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                   "-loop", "0", str(kit / "card.gif"))
            ffmpeg("-framerate", str(FPS), "-i", pattern, "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                   "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(kit / "card.mp4"))
            shutil.rmtree(frames)
            size = (kit / "card.gif").stat().st_size
            print(f"card.gif {size / 1048576:.1f} MB, card.mp4 {(kit / 'card.mp4').stat().st_size / 1048576:.1f} MB, "
                  f"{count} frames")
            if size > GIF_LIMIT:
                print("warning: the GIF is over 5 MB, X's limit for GIFs posted from a phone (15 MB on the web)")
        browser.close()
    if "--downloads" in sys.argv:
        for kind in ["png"] if "--still" in sys.argv else ["png", "gif", "mp4"]:
            target = Path.home() / "Downloads" / f"redlamp-{kit.name}.{kind}"
            shutil.copyfile(kit / f"card.{kind}", target)
            print(f"copied to {target}")


if __name__ == "__main__":
    main()
