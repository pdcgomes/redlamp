"""Main against a candidate on one sample's crop, a row per setting, labelled. Usage:
sidebyside.py <renders dir> <candidate> <crop x0,y0,x1,y1> <out.jpg> [settings…]"""
import sys
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageDraw, ImageFont

folder, candidate, crop, out = Path(sys.argv[1]), sys.argv[2], [float(v) for v in sys.argv[3].split(",")], sys.argv[4]
settings = sys.argv[5:] or ["defaults", "highlights-80", "exposure-1.5", "auto"]
names = {"defaults": "Defaults", "highlights-80": "Highlights -80", "exposure-1.5": "Exposure -1.5",
         "exposure-3": "Exposure -3", "auto": "Auto"}
label = {"ef": "Proposed (E)", "e": "E, first form", "e8": "E8", "a": "A", "b": "B", "d": "D"}.get(candidate, candidate)
font = ImageFont.load_default(size=20)


def tile(name, text):
    image = tifffile.imread(str(folder / f"{name}.tif"))[..., :3]
    h, w = image.shape[:2]
    part = image[int(crop[1] * h): int(crop[3] * h), int(crop[0] * w): int(crop[2] * w)]
    picture = Image.fromarray((part.astype(np.float64) / 257 + 0.5).astype(np.uint8))
    picture = picture.resize((900, int(900 * picture.height / picture.width)), Image.LANCZOS)
    draw = ImageDraw.Draw(picture)
    draw.rectangle([0, 0, 11 * len(text) + 14, 28], fill=(0, 0, 0))
    draw.text((7, 3), text, fill=(255, 255, 255), font=font)
    return picture


rows = [(tile(f"main-{s}", f"main, {names[s]}"), tile(f"{candidate}-{s}", f"{label}, {names[s]}")) for s in settings]
width = rows[0][0].width * 2 + 6
height = sum(r[0].height + 6 for r in rows)
sheet = Image.new("RGB", (width, height), (20, 20, 20))
y = 0
for left, right in rows:
    sheet.paste(left, (0, y))
    sheet.paste(right, (left.width + 6, y))
    y += left.height + 6
sheet.save(out, quality=90)
print(out, sheet.size)
