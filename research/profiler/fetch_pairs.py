"""Builds the camera-pair set for `redlamp recipe profile` from raw.pixls.us.

Every modern Fujifilm raw file carries the camera's own full-size JPEG, rendered with the
film simulation set at capture. With a neutral Redlamp render of the same raw, that is an
exact before-and-after pair. This keeps CC0 files whose other JPEG settings are neutral
(Color, Highlight and Shadow tone 0, dynamic range 100%), one per camera and film
simulation, writes fujifilm-pairs.json and downloads the files into build/profiler/.

    python3 research/profiler/fetch_pairs.py [--manifest-only]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).resolve().parent / "fujifilm-pairs.json"
FOLDER = ROOT / "build" / "profiler" / "fujifilm"

# EXIF FilmMode values (exiv2 names, or the raw code for newer modes) → Redlamp's slots.
SLOTS = {
    "F0/Standard (Provia)": "standard", "F0/Standard": "standard",
    "F2/Fujichrome (Velvia)": "vivid-slide", "F2/Fujichrome": "vivid-slide",
    "F1b/Studio Portrait Smooth Skin Tone (Astia)": "soft-slide",
    "(1536)": "chrome", "(1792)": "cinema", "(2048)": "negative-classic", "(2560)": "negative-nostalgic",
    "(1280)": "negative-standard", "(1281)": "negative-high", "(2816)": "reala",
}
MODERN = ("X-", "GFX", "X100", "X30", "X70")


def field(text: str, name: str) -> str | None:
    match = re.search(r"Exif\.Fujifilm\." + name + r"\s+(.+)", text)
    return match.group(1).strip() if match else None


def describe(row: list) -> dict | None:
    make, model, mode, _, _, license_html, date, file_html, exif_html = row
    if make != "Fujifilm" or "publicdomain/zero" not in license_html or not model.startswith(MODERN):
        return None
    exif = re.search(r"href='([^']+)'", exif_html)
    file = re.search(r"href='([^']+)'", file_html)
    if not exif or not file:
        return None
    try:
        text = urllib.request.urlopen(urllib.parse.quote(exif.group(1), safe=":/"), timeout=30).read().decode("utf8", "ignore")
    except Exception:
        return None
    slot = SLOTS.get(field(text, "FilmMode") or "")
    clean = (field(text, "Color") in ("Normal", None) and field(text, "HighlightTone") in ("0", None)
             and field(text, "ShadowTone") in ("0", None) and field(text, "DevelopmentDynamicRange") in ("100", None))
    if not slot or not clean:
        return None
    url = urllib.parse.quote(file.group(1), safe=":/")
    return {
        "slot": slot, "camera": f"Fujifilm {model}", "mode": mode, "date": date, "url": url,
        "sha256": re.search(r"Checksum'>([0-9a-f]+)", file_html).group(1),
        "sizeMB": float(re.search(r"\(([\d.]+)MB\)", file_html).group(1)),
        "file": re.sub(r"[^A-Za-z0-9._-]+", "-", f"{model}-{slot}") + "." + url.rsplit(".", 1)[-1],
        "whiteBalance": field(text, "WhiteBalance"), "license": "CC0-1.0", "source": "raw.pixls.us",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-only", action="store_true")
    args = parser.parse_args()
    if args.manifest_only or not MANIFEST.exists():
        rows = json.loads(urllib.request.urlopen("https://raw.pixls.us/json/getrepository.php?set=all", timeout=60).read())["data"]
        with ThreadPoolExecutor(8) as pool:
            pairs = [p for p in pool.map(describe, rows) if p]
        # One file per camera and film simulation (modes of a body usually share a scene).
        best: dict[tuple, dict] = {}
        for pair in pairs:
            key = (pair["slot"], pair["camera"])
            if key not in best or pair["sizeMB"] < best[key]["sizeMB"]:
                best[key] = pair
        chosen = sorted(best.values(), key=lambda p: (p["slot"], p["camera"]))
        MANIFEST.write_text(json.dumps({"version": 1, "description": __doc__.strip().splitlines()[0], "pairs": chosen}, indent=1))
        counts: dict[str, int] = {}
        for pair in chosen:
            counts[pair["slot"]] = counts.get(pair["slot"], 0) + 1
        print(f"{len(chosen)} pairs: {counts}")
    if args.manifest_only:
        return 0
    FOLDER.mkdir(parents=True, exist_ok=True)
    failed = 0
    for pair in json.loads(MANIFEST.read_text())["pairs"]:
        path = FOLDER / pair["file"]
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == pair["sha256"]:
            continue
        print(f"==> {pair['file']} ({pair['sizeMB']:.0f} MB)")
        try:
            path.write_bytes(urllib.request.urlopen(pair["url"], timeout=600).read())
        except Exception as error:
            print(f"    failed: {error}", file=sys.stderr)
            failed += 1
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() != pair["sha256"]:
            print("    checksum mismatch", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
