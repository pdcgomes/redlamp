"""The mask evaluation set (MSK-25): CC0 photos from Wikimedia Commons for Sky, Subject, People and
face-part masks, chosen cell by cell (research/mask-eval/cells.json).

    .venv/bin/python photoset.py search [--cells sky-sunset,beard] [--round 2]   candidates, previews, sheets
    .venv/bin/python photoset.py assemble picks.json                 the picks into research/mask-eval/manifest.json
    .venv/bin/python photoset.py fetch [--record]                    the originals into build/mask-eval/
    .venv/bin/python photoset.py sheet                               contact sheets of the set

`search` asks Commons for each cell's queries among files in Category:CC-Zero, keeps photos whose
licence Commons reports as CC0, at least --min-long px on the long side, and leaves out what isn't
a colour photograph of the real thing (paintings, scans, AI-generated images, black and white,
statues). Candidates go to build/mask-eval/candidates/<cell>.json with 320 px previews, and a
numbered contact sheet to build/mask-eval/sheets/<cell>.png. `assemble` takes the numbers picked
per cell ({"cell": [[n, "tag", ...], ...]}) and writes the manifest; `fetch --record` downloads the
originals and records their SHA-256, which `mise run maskeval` then checks.
"""

import argparse
import concurrent.futures
import hashlib
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[3]
CELLS = ROOT / "research/mask-eval/cells.json"
MANIFEST = ROOT / "research/mask-eval/manifest.json"
WORK = ROOT / "build/mask-eval"
API = "https://commons.wikimedia.org/w/api.php"
AGENT = "RedlampMaskEval/1.0 (https://github.com/pdcgomes/redlamp; mask evaluation, MSK-25)"
EXCLUDE = re.compile(
    r"paint|drawing|illustrat|\bscan|engraving|lithograph|poster|collage|montage|composit"
    r"|ai[- ]generated|artificial intelligence|stable diffusion|midjourney|dall-?e|generated with"
    r"|\brender|3d model|screenshot|diagram|\bmaps?\b|logo|clip ?art|cartoon|anime|comic"
    r"|statue|sculpture|mannequin|wax figure|black and white|black-and-white|monochrome|sepia"
    r"|historical photograph|19th.century|vintage photograph|postcard",
    re.IGNORECASE,
)


def get(params):
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json", "formatversion": 2})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=60) as r:
                return json.load(r)
        except Exception:
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Commons didn't answer: {url}")


def text(value):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", value or ""))).strip()


def candidates(query, min_long, limit):
    data = get({
        "action": "query", "generator": "search", "gsrnamespace": 6, "gsrlimit": limit,
        "gsrsearch": f"{query} incategory:CC-Zero filemime:image/jpeg filesize:>700",
        "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata|commonmetadata", "iiurlwidth": 320,
        "iiextmetadatafilter": "LicenseShortName|Artist|Credit|ImageDescription|DateTimeOriginal|Categories|Restrictions",
    })
    for page in sorted(data.get("query", {}).get("pages", []), key=lambda p: p.get("index", 0)):
        info = (page.get("imageinfo") or [{}])[0]
        meta = {k: text(v.get("value")) for k, v in info.get("extmetadata", {}).items()}
        common = {m["name"]: m["value"] for m in info.get("commonmetadata", []) if isinstance(m.get("value"), str)}
        width, height = info.get("width", 0), info.get("height", 0)
        about = " ".join([page["title"], meta.get("Categories", ""), meta.get("ImageDescription", "")])
        if meta.get("LicenseShortName") != "CC0" or max(width, height) < min_long or EXCLUDE.search(about):
            continue
        camera = " ".join(v for v in (common.get("Make", ""), common.get("Model", "")) if v).strip()
        yield {
            "title": page["title"], "page": info.get("descriptionurl"), "url": info.get("url"),
            "thumb": info.get("thumburl"), "width": width, "height": height, "camera": camera,
            "author": meta.get("Artist", "")[:120], "date": meta.get("DateTimeOriginal", "")[:20],
            "restrictions": meta.get("Restrictions", ""), "description": meta.get("ImageDescription", "")[:200],
        }


def download(url, path):
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=120) as r:
                path.write_bytes(r.read())
            return path
        except Exception:
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"couldn't download {url}")


def sheet(tiles, path, columns=5, size=280):
    """tiles: (label, image path). A numbered contact sheet."""
    rows = (len(tiles) + columns - 1) // columns
    out = Image.new("RGB", (columns * (size + 6), rows * (size + 22)), (22, 22, 22))
    draw = ImageDraw.Draw(out)
    for i, (label, image) in enumerate(tiles):
        x, y = (i % columns) * (size + 6), (i // columns) * (size + 22)
        try:
            tile = ImageOps.exif_transpose(Image.open(image)).convert("RGB")
            tile.thumbnail((size, size))
            out.paste(tile, (x + (size - tile.width) // 2, y + 20 + (size - tile.height) // 2))
        except Exception:
            pass
        draw.text((x + 3, y + 3), label, fill=(235, 235, 235))
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path)


def search(args):
    cells = json.loads(CELLS.read_text())["cells"]
    wanted = set(args.cells.split(",")) if args.cells else None
    suffix = f"~{args.round}" if args.round > 1 else ""
    # A later round leaves out what earlier rounds already offered, under any cell.
    seen = {
        c["title"]
        for path in (WORK / "candidates").glob("*.json")
        if args.round > 1
        for c in json.loads(path.read_text())
    }
    for cell in cells:
        if wanted and cell["id"] not in wanted:
            continue
        queries = cell["queries"] if args.round == 1 else cell.get(f"round{args.round}", [])
        cell = {**cell, "id": cell["id"] + suffix}
        found = []
        for query in queries:
            for c in candidates(query, args.min_long, args.per_query):
                portrait = c["height"] > c["width"]
                if c["title"] in seen or (cell.get("portrait") and not portrait):
                    continue
                seen.add(c["title"])
                found.append(c)
        # Photos with their camera's EXIF first (more likely straight from a camera), then by size.
        found.sort(key=lambda c: (not c["camera"], -c["width"] * c["height"]))
        found = found[: args.keep]
        folder = WORK / "candidates" / cell["id"]
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            list(pool.map(lambda nc: download(nc[1]["thumb"], folder / f"{nc[0]:02d}.jpg"), enumerate(found, 1)))
        for n, c in enumerate(found, 1):
            c["n"] = n
        (WORK / "candidates").mkdir(parents=True, exist_ok=True)
        (WORK / "candidates" / f"{cell['id']}.json").write_text(json.dumps(found, indent=1))
        tiles = [(f"{n}  {c['width']}x{c['height']}{'  exif' if c['camera'] else ''}", folder / f"{n:02d}.jpg") for n, c in enumerate(found, 1)]
        if tiles:
            sheet(tiles, WORK / "sheets" / f"{cell['id']}.png")
        print(f"{cell['id']}: {len(found)} candidates (want {cell['want']})")


def assemble(args):
    """Picks are keyed by cell, by a later round's sheet ("hair-curly~2"), or by a cell and the sheet
    the photo was found on ("beard<hair-busy-background")."""
    cells = {c["id"]: c for c in json.loads(CELLS.read_text())["cells"]}
    picks = json.loads(Path(args.picks).read_text())
    old = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    known = {i["page"]: i for i in old.get("images", [])}
    images = []
    counts = {}
    used = set()
    for key, chosen in picks.items():
        target, _, source = key.partition("<")
        source = source or target
        cell_id = target.split("~")[0]
        found = {c["n"]: c for c in json.loads((WORK / "candidates" / f"{source}.json").read_text())}
        for n, *tags in chosen:
            c = found[n]
            if c["page"] in used:
                continue
            used.add(c["page"])
            counts[cell_id] = counts.get(cell_id, 0) + 1
            k = counts[cell_id]
            entry = known.get(c["page"], {})
            images.append({
                "file": f"{cell_id}-{k:02d}.jpg", "url": c["url"], "page": c["page"], "title": c["title"],
                "sha256": entry.get("sha256", ""), "width": c["width"], "height": c["height"],
                "camera": c["camera"], "masks": cells[cell_id]["masks"], "cell": cell_id,
                "conditions": tags, "license": "CC0-1.0", "author": c["author"], "source": "Wikimedia Commons",
                **({"restrictions": c["restrictions"]} if c["restrictions"] else {}),
            })
    manifest = {
        "version": 1,
        "description": old.get("description", ""),
        "gaps": old.get("gaps", []),
        "lookDev": old.get("lookDev", []),
        "images": images,
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(images)} photos in {MANIFEST.relative_to(ROOT)}")


def fetch(args):
    manifest = json.loads(MANIFEST.read_text())
    failed = 0

    def one(image):
        path = WORK / image["file"]
        if path.exists() and image["sha256"] and hashlib.sha256(path.read_bytes()).hexdigest() == image["sha256"]:
            return image, True
        path.unlink(missing_ok=True)
        download(image["url"], path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if args.record and not image["sha256"]:
            image["sha256"] = digest
        return image, digest == image["sha256"]

    with concurrent.futures.ThreadPoolExecutor(3) as pool:
        for image, ok in pool.map(one, manifest["images"]):
            if not ok:
                failed += 1
                print(f"checksum mismatch: {image['file']}", file=sys.stderr)
    if args.record:
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(manifest['images']) - failed} of {len(manifest['images'])} photos ready in {WORK.relative_to(ROOT)}")
    sys.exit(1 if failed else 0)


def sheets(args):
    manifest = json.loads(MANIFEST.read_text())
    groups = {"sky": [], "people": [], "faces": []}
    for image in manifest["images"]:
        group = "sky" if "sky" in image["masks"] else "faces" if image["cell"].startswith("face-") else "people"
        groups[group].append((image["file"].removesuffix(".jpg"), WORK / image["file"]))
    for group, tiles in groups.items():
        if tiles:
            sheet(tiles, WORK / "sheets" / f"set-{group}.png", columns=6, size=240)
            print(f"{group}: {len(tiles)} photos, build/mask-eval/sheets/set-{group}.png")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("search")
    s.add_argument("--cells")
    s.add_argument("--min-long", type=int, default=2400)
    s.add_argument("--per-query", type=int, default=40)
    s.add_argument("--keep", type=int, default=20)
    s.add_argument("--round", type=int, default=1, help="a later round runs a cell's roundN queries")
    a = sub.add_parser("assemble")
    a.add_argument("picks")
    f = sub.add_parser("fetch")
    f.add_argument("--record", action="store_true")
    sub.add_parser("sheet")
    args = parser.parse_args()
    {"search": search, "assemble": assemble, "fetch": fetch, "sheet": sheets}[args.command](args)


if __name__ == "__main__":
    main()
