"""Growing the mask bench's pool (MSK-38): more CC0 photos from Wikimedia Commons, in the cells of
research/mask-eval/cells.json marked `added`, aimed at what the bench shows Redlamp gets wrong and
the subjects and skies the evaluation set lacked.

    maskbench pool search [--cells a,b]   candidates for the added cells, and a numbered contact sheet each
    maskbench pool add                    each added cell's first `want` candidates into the manifest, downloaded
    maskbench pool drop <file>…           photos that don't belong, out of the manifest and the quick subset

Candidates are found and filtered as photoset.py finds them (CC0 as Commons reports it, at least
2,400 px on the long side, no paintings, scans, renders or black and white), and ranked the same way:
photos with their camera's EXIF first, then the largest. `add` takes them in that order, so a cell's
picks are automatic: look at its sheet (build/mask-eval/sheets/<cell>.png) and drop any that doesn't
belong. Photos are downloaded into build/mask-eval and never committed; the manifest records each
one's page, author, licence and SHA-256, which `mise run maskeval` checks.
"""

import concurrent.futures
import hashlib
import json
import sys

import common as c

sys.path.insert(0, str(c.ROOT / "research/prototypes/masking"))
import photoset as ps  # noqa: E402

PER_QUERY = 50
KEEP = 30


def added_cells(names=None):
    cells = [cell for cell in json.loads(ps.CELLS.read_text())["cells"] if cell.get("added")]
    return [cell for cell in cells if not names or cell["id"] in names]


def search(args):
    names = set(args.cells.split(",")) if args.cells else None
    seen = {image["page"] for image in json.loads(c.MANIFEST.read_text())["images"]}
    for cell in added_cells(names):
        found = []
        for query in cell["queries"]:
            for candidate in ps.candidates(query, 2400, PER_QUERY):
                if candidate["page"] in seen:
                    continue
                seen.add(candidate["page"])
                found.append(candidate)
        found.sort(key=lambda x: (not x["camera"], -x["width"] * x["height"]))
        found = found[:KEEP]
        folder = ps.WORK / "candidates" / cell["id"]
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            list(pool.map(lambda n_c: ps.download(n_c[1]["thumb"], folder / f"{n_c[0]:02d}.jpg"), enumerate(found, 1)))
        for n, candidate in enumerate(found, 1):
            candidate["n"] = n
        (ps.WORK / "candidates" / f"{cell['id']}.json").write_text(json.dumps(found, indent=1))
        tiles = [(f"{n}  {x['width']}x{x['height']}{'  exif' if x['camera'] else ''}", folder / f"{n:02d}.jpg")
                 for n, x in enumerate(found, 1)]
        if tiles:
            ps.sheet(tiles, ps.WORK / "sheets" / f"{cell['id']}.png")
        print(f"    {cell['id']}: {len(found)} candidates (want {cell['want']})")


def add(_args):
    manifest = json.loads(c.MANIFEST.read_text())
    have = {image["page"] for image in manifest["images"]}
    quick = json.loads(c.QUICK.read_text())
    new = []
    for cell in added_cells():
        path = ps.WORK / "candidates" / f"{cell['id']}.json"
        if not path.exists():
            print(f"    {cell['id']}: no candidates yet (maskbench pool search)", file=sys.stderr)
            continue
        numbers = {int(image["file"][len(cell["id"]) + 1:-4]) for image in manifest["images"] if image["cell"] == cell["id"]}
        taken = len(numbers)
        for candidate in json.loads(path.read_text()):
            if taken >= cell["want"]:
                break
            if candidate["page"] in have:
                continue
            taken += 1
            have.add(candidate["page"])
            number = next(n for n in range(1, 1000) if n not in numbers)
            numbers.add(number)
            new.append({
                "file": f"{cell['id']}-{number:02d}.jpg", "url": candidate["url"], "page": candidate["page"],
                "title": candidate["title"], "sha256": "", "width": candidate["width"], "height": candidate["height"],
                "camera": candidate["camera"], "masks": cell["masks"], "cell": cell["id"], "conditions": [],
                "license": "CC0-1.0", "author": candidate["author"], "source": "Wikimedia Commons",
                **({"restrictions": candidate["restrictions"]} if candidate["restrictions"] else {}),
            })

    def fetch(image):
        path = ps.WORK / image["file"]
        try:
            ps.download(image["url"], path)
        except RuntimeError as error:
            return image, None, str(error)
        return image, hashlib.sha256(path.read_bytes()).hexdigest(), None

    # Commons refuses many downloads at once; two at a time gets through.
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(fetch, new))
    kept = 0
    for image, digest, error in results:
        if error:
            print(f"    {image['file']}: {error}", file=sys.stderr)
            continue
        image["sha256"] = digest
        manifest["images"].append(image)
        kept += 1
        if image["file"].endswith(("-01.jpg", "-02.jpg")) and image["file"][:-4] not in quick["photos"]:
            quick["photos"].append(image["file"][:-4])
    c.MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    c.QUICK.write_text(json.dumps(quick, indent=2) + "\n")
    print(f"==> {kept} photos added: {len(manifest['images'])} in the manifest, "
          f"{len(quick['photos'])} in the quick subset")


def drop(args):
    manifest = json.loads(c.MANIFEST.read_text())
    quick = json.loads(c.QUICK.read_text())
    files = set(args.files)
    manifest["images"] = [image for image in manifest["images"] if image["file"] not in files]
    quick["photos"] = [p for p in quick["photos"] if f"{p}.jpg" not in files]
    for name in files:
        (ps.WORK / name).unlink(missing_ok=True)
    c.MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    c.QUICK.write_text(json.dumps(quick, indent=2) + "\n")
    print(f"==> {len(manifest['images'])} photos in the manifest")


def main(args):
    {"search": search, "add": add, "drop": drop}[args.action](args)
