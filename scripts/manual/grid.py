#!/usr/bin/env python3
"""Draws the image's pixel coordinates over part of a screenshot, to place a figure's marks.

    build/manual/venv/bin/python scripts/manual/grid.py docs/images/hero-masks.png 1920 60 2400 1500

Writes the crop from (x0, y0) to (x1, y1), at one pixel to the point, with a tick and the image's
own coordinate every 50 pixels along its left and top edges, to /tmp/manual-grid.png (or the path
given after the four numbers). A mark's place in a figure is then a percentage of its crop:
(x - x0) / (x1 - x0) across and (y - y0) / (y1 - y0) down.
"""

import sys

import pymupdf


def main() -> None:
    if len(sys.argv) < 6:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    x0, y0, x1, y1 = (int(value) for value in sys.argv[2:6])
    out = sys.argv[6] if len(sys.argv) > 6 else "/tmp/manual-grid.png"
    image = pymupdf.Pixmap(path)
    doc = pymupdf.open()
    page = doc.new_page(width=x1 - x0, height=y1 - y0)
    page.insert_image(pymupdf.Rect(-x0, -y0, image.width - x0, image.height - y0), filename=path)
    for y in range(0, y1 - y0, 50):
        page.draw_line((0, y), (14, y), color=(0, 1, 1), width=1)
        page.insert_text((16, y + 4), str(y + y0), fontsize=9, color=(0, 1, 1))
    for x in range(0, x1 - x0, 50):
        page.draw_line((x, 0), (x, 12), color=(1, 1, 0), width=1)
        page.insert_text((x + 2, 22), str(x + x0), fontsize=8, color=(1, 1, 0))
    page.get_pixmap(dpi=72).save(out)
    print(f"{out}: {x1 - x0} × {y1 - y0} px of the image's {image.width} × {image.height}")


if __name__ == "__main__":
    main()
