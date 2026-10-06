#!/usr/bin/env python3
"""Builds the Redlamp user manual (docs/manual) into a PDF with Google Chrome.

The manual is Markdown with a few additions (markup.py), laid out by a print style sheet
(docs/manual/style/manual.css) and typeset by Chrome, the way a web page is printed. Chrome can't put page numbers in the
contents or in cross-references, so the build prints more than once: each print ends with a page
of links to every section, heading and figure, the PDF's link targets say which page each landed
on, and the next print fills those numbers in, until no page moves. The finished PDF is the last
print without that page, with bookmarks for every part, section and heading.

Needs Google Chrome and, in a virtualenv, markdown-it-py, mdit-py-plugins, playwright and pymupdf
(Playwright drives the installed Chrome, so it downloads no browser):

    python3 -m venv build/manual/venv
    build/manual/venv/bin/pip install markdown-it-py mdit-py-plugins playwright pymupdf

    build/manual/venv/bin/python scripts/manual/build.py                # build/manual/redlamp-manual.pdf
    build/manual/venv/bin/python scripts/manual/build.py --pages 1-6,9  # and PNGs of those pages
    build/manual/venv/bin/python scripts/manual/build.py --sheets       # and contact sheets of every page
    build/manual/venv/bin/python scripts/manual/build.py --html         # only the HTML

Previews go to build/manual/pages.

The fonts, Inter 4.1 and JetBrains Mono 2.304, are downloaded into build/manual/fonts on the
first build (fonts.py).
"""

import argparse
import sys
from pathlib import Path

import pymupdf
from playwright.sync_api import sync_playwright

import fonts
from layout import Manual

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "manual"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# The flags Chrome needs to start inside the agent sandbox; harmless outside it.
CHROME_ARGS = ["--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
MAX_PRINTS = 6


def print_pdf(browser, html_path: Path, pdf_path: Path) -> None:
    page = browser.new_page()
    page.goto(html_path.as_uri(), wait_until="load")
    page.evaluate("document.fonts.ready.then(() => true)")
    page.pdf(path=str(pdf_path), prefer_css_page_size=True, print_background=True, tagged=True)
    page.close()


def destinations(pdf_path: Path) -> dict[str, int]:
    """Every link target's page, numbered from 1."""
    with pymupdf.open(pdf_path) as doc:
        return {name: d["page"] + 1 for name, d in doc.resolve_names().items() if d.get("page", -1) >= 0}


def page_list(spec: str, count: int) -> list[int]:
    pages = []
    for part in spec.split(","):
        first, _, last = part.partition("-")
        pages += range(int(first), int(last or first) + 1)
    return [p for p in pages if 1 <= p <= count]


def previews(pdf: Path, pages: list[int], sheets: bool) -> None:
    folder = OUT / "pages"
    folder.mkdir(exist_ok=True)
    with pymupdf.open(pdf) as doc:
        for n in pages:
            doc[n - 1].get_pixmap(dpi=110).save(folder / f"page-{n:03d}.png")
        if not sheets:
            return
        cols, rows, width, pad = 5, 3, 300, 12
        height = width * doc[0].rect.height / doc[0].rect.width
        for first in range(0, doc.page_count, cols * rows):
            sheet = pymupdf.open()
            canvas = sheet.new_page(width=cols * width + (cols + 1) * pad, height=rows * height + (rows + 1) * pad)
            canvas.draw_rect(canvas.rect, color=None, fill=(0.55, 0.53, 0.52))
            for k in range(cols * rows):
                if first + k >= doc.page_count:
                    break
                r, c = divmod(k, cols)
                x, y = pad + c * (width + pad), pad + r * (height + pad)
                canvas.show_pdf_page(pymupdf.Rect(x, y, x + width, y + height), doc, first + k)
                canvas.insert_text((x + 4, y + height - 5), str(first + k + 1), fontsize=13, color=(0.85, 0.1, 0.1))
            canvas.get_pixmap(dpi=72).save(folder / f"sheet-{first // (cols * rows) + 1:02d}.png")


def check_fonts(doc: pymupdf.Document) -> list[str]:
    """Any font in the PDF that isn't one of the manual's own, such as a system font Chrome fell back to."""
    stray = set()
    for page in doc:
        for font in page.get_fonts():
            name = font[3].split("+", 1)[-1]
            if not name.startswith(fonts.EMBEDDED):
                stray.add(f"{name or 'unnamed'} ({font[2]}) on page {page.number + 1}")
    return sorted(stray)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--out", type=Path, default=OUT / "redlamp-manual.pdf")
    parser.add_argument("--html", action="store_true", help="only write the HTML")
    parser.add_argument("--pages", help="also save these pages as PNGs, such as 1-6,9")
    parser.add_argument("--sheets", action="store_true", help="also save contact sheets of every page")
    args = parser.parse_args()

    fonts.ensure(OUT / "fonts", OUT / "cache")
    manual = Manual(ROOT, OUT)
    html_path = OUT / "redlamp-manual.html"
    if args.html:
        html_path.write_text(manual.html({}, measuring=False))
        print(html_path)
        return

    measure = OUT / "measure.pdf"
    pages: dict[str, int] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=CHROME, headless=True, args=CHROME_ARGS)
        for attempt in range(1, MAX_PRINTS + 1):
            html_path.write_text(manual.html(pages, measuring=True))
            print_pdf(browser, html_path, measure)
            found = destinations(measure)
            if found == pages:
                break
            pages = found
        else:
            raise SystemExit(f"error: the page numbers still moved after {MAX_PRINTS} prints")
        browser.close()
    html_path.write_text(manual.html(pages, measuring=False))

    with pymupdf.open(measure) as doc:
        doc.delete_pages(pages["link-index"] - 1, doc.page_count - 1)
        doc.set_toc(manual.outline(pages))
        doc.set_metadata(
            {
                "title": manual.meta["title"],
                "author": "Redlamp",
                "subject": manual.meta["subject"],
                "creator": "scripts/manual/build.py with Google Chrome",
                "producer": f"PyMuPDF {pymupdf.VersionBind}",
            }
        )
        stray = check_fonts(doc)
        count = doc.page_count
        doc.save(args.out, garbage=3, deflate=True)
    measure.unlink()
    print(f"{args.out.relative_to(ROOT)}: {count} pages, page numbers settled after {attempt} prints")
    for font in stray:
        print(f"warning: a font that isn't the manual's own: {font}", file=sys.stderr)
    if args.pages or args.sheets:
        previews(args.out, page_list(args.pages, count) if args.pages else [], args.sheets)


if __name__ == "__main__":
    main()
