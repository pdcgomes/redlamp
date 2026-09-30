"""Builds a second camera-pair set for `redlamp recipe profile` from camera-review sample files.

Photography Blog publishes the original RAF files from its Fujifilm reviews, and each one
carries the camera's own full-size JPEG. The files are copyrighted: they're used as
references only, never shipped or committed (DEC-17 in the research tracker). Everything is
fetched one request at a time, about one a second, resumably, and the fetcher stops at the
first refusal rather than retrying into a block.

    python3 research/profiler/fetch_review_pairs.py survey    # reads each file's first 512 KB
    python3 research/profiler/fetch_review_pairs.py select    # writes review-pairs.json
    python3 research/profiler/fetch_review_pairs.py fetch     # downloads the chosen files
"""

from __future__ import annotations

import collections
import json
import re
import struct
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).resolve().parent / "review-pairs.json"
WORK = ROOT / "build" / "profiler" / "review"
PAGES = WORK / "survey-pages.json"
SURVEY = WORK / "survey.jsonl"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15"
PAUSE = 1.0
PER_CAMERA = 8
# Provia is nearly every file; two per body adds bodies without tens of gigabytes.
PER_CAMERA_SLOT = {"standard": 2}

MODELS = """x_t1 x_t10 x_t2 x_t20 x_t3 x_t30 x_t30_ii x_t30_iii x_t4 x_t5 x_t50 x_pro1 x_pro2 x_pro3 x100t x100f x100v
x100vi x70 x30 x_e1 x_e2 x_e2s x_e3 x_e4 x_e5 x_h1 x_h2 x_h2s x_s10 x_s20 x_m1 x_m5 x_a1 x_a2 x_a3 x_a5 x_a7 x_a10
x_t100 x_t200 gfx_50s gfx_50r gfx_100 gfx_100s gfx_50s_ii gfx_100_ii gfx_100rf""".split()

# Maker-note FilmMode (0x1401), and the monochrome modes carried in Saturation (0x1003).
FILM = {0x000: "Provia", 0x120: "Astia", 0x200: "Velvia", 0x400: "Velvia", 0x500: "Pro Neg Std",
        0x501: "Pro Neg Hi", 0x600: "Classic Chrome", 0x700: "Eterna", 0x800: "Classic Neg",
        0x900: "Eterna Bleach Bypass", 0xA00: "Nostalgic Neg", 0xB00: "Reala Ace"}
MONO = {0x300: "Monochrome", 0x301: "Monochrome+R", 0x302: "Monochrome+Ye", 0x303: "Monochrome+G",
        0x310: "Sepia", 0x500: "Acros", 0x501: "Acros+R", 0x502: "Acros+Ye", 0x503: "Acros+G"}
TAGS = {0x1401: "film", 0x1003: "saturation", 0x1040: "shadow", 0x1041: "highlight", 0x1403: "dr",
        0x1048: "chrome", 0x104E: "chromeBlue", 0x1049: "toneWarmCool", 0x104B: "toneMagentaGreen"}
# Camera look → Redlamp film slot; Acros is preferred over plain Monochrome for the black and white slots.
SLOTS = {"Provia": "standard", "Velvia": "vivid-slide", "Astia": "soft-slide", "Classic Chrome": "chrome",
         "Eterna": "cinema", "Eterna Bleach Bypass": "bleach", "Classic Neg": "negative-classic",
         "Nostalgic Neg": "negative-nostalgic", "Pro Neg Std": "negative-standard", "Pro Neg Hi": "negative-high",
         "Acros": "monochrome", "Acros+Ye": "monochrome-yellow", "Acros+R": "monochrome-red",
         "Acros+G": "monochrome-green", "Sepia": "sepia", "Monochrome": "monochrome",
         "Monochrome+Ye": "monochrome-yellow", "Monochrome+R": "monochrome-red", "Monochrome+G": "monochrome-green"}


class Refused(Exception):
    pass


def get(url: str, referer: str | None = None, head: int | None = None) -> bytes:
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    if head:
        headers["Range"] = f"bytes=0-{head - 1}"
    time.sleep(PAUSE)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
            return response.read(head) if head else response.read()
    except urllib.error.HTTPError as error:
        if error.code in (403, 429):
            raise Refused(f"{error.code} on {url}") from error
        raise


# MARK: - RAF maker notes


def _ifd(data: bytes, base: int, offset: int, little: bool) -> dict[int, tuple[int, int, int, bytes]]:
    order = "<" if little else ">"
    entries = {}
    for index in range(struct.unpack_from(order + "H", data, base + offset)[0]):
        at = base + offset + 2 + 12 * index
        tag, kind, count, value = struct.unpack_from(order + "HHII", data, at)
        entries[tag] = (kind, count, value, data[at + 8:at + 12])
    return entries


def _number(entry: tuple[int, int, int, bytes]) -> int:
    kind, _, value, raw = entry
    return {3: lambda: struct.unpack_from("<H", raw)[0], 8: lambda: struct.unpack_from("<h", raw)[0],
            9: lambda: struct.unpack_from("<i", raw)[0]}.get(kind, lambda: value)()


def settings(data: bytes) -> dict:
    """The embedded JPEG's model and Fujifilm settings, from the start of a RAF file."""
    jpeg = data[struct.unpack_from(">I", data, 84)[0]:]
    at = 2
    while at < len(jpeg) - 4 and not (jpeg[at + 1] == 0xE1 and jpeg[at + 4:at + 10] == b"Exif\0\0"):
        at += 2 + struct.unpack_from(">H", jpeg, at + 2)[0]
    tiff = at + 10
    little = jpeg[tiff:tiff + 2] == b"II"
    ifd0 = _ifd(jpeg, tiff, struct.unpack_from(("<" if little else ">") + "I", jpeg, tiff + 4)[0], little)
    _, count, offset, _ = ifd0[0x0110]
    model = jpeg[tiff + offset:tiff + offset + count].split(b"\0")[0].decode(errors="ignore")
    note = tiff + _ifd(jpeg, tiff, ifd0[0x8769][2], little)[0x927C][2]
    if jpeg[note:note + 8] != b"FUJIFILM":
        return {"model": model}
    notes = _ifd(jpeg, note, struct.unpack_from("<I", jpeg, note + 8)[0], True)
    result = {"model": model, **{name: _number(notes[tag]) for tag, name in TAGS.items() if tag in notes}}
    saturation = result.get("saturation")
    result["look"] = MONO.get(saturation) or FILM.get(result.get("film", 0), hex(result.get("film", 0)))
    return result


def neutral(record: dict) -> bool:
    """Other JPEG settings at their defaults, so the pair measures the film simulation alone."""
    color = record.get("saturation", 0) if record.get("look") not in MONO.values() else 0
    return (record.get("shadow", 0) == 0 and record.get("highlight", 0) == 0 and record.get("dr", 100) == 100
            and color == 0 and record.get("chrome", 0) == 0 and record.get("chromeBlue", 0) == 0
            and record.get("toneWarmCool", 0) == 0 and record.get("toneMagentaGreen", 0) == 0)


# MARK: - Steps


def survey() -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    pages = json.loads(PAGES.read_text()) if PAGES.exists() else {}
    for model in MODELS:
        if model not in pages:
            url = f"https://www.photographyblog.com/reviews/fujifilm_{model}_review/sample_images"
            try:
                html = get(url).decode("utf8", "ignore")
                files = sorted(set(re.findall(r'href="(https?://[^"]+\.raf)"', html, re.I)))
            except urllib.error.HTTPError:
                files = []
            pages[model] = {"url": url, "rafs": files}
            PAGES.write_text(json.dumps(pages, indent=1))
    done = {json.loads(line)[0] for line in SURVEY.read_text().splitlines()} if SURVEY.exists() else set()
    jobs = [(raf, page["url"]) for page in pages.values() for raf in page["rafs"] if raf not in done]
    print(f"{len(done)} surveyed, {len(jobs)} to go", flush=True)
    with SURVEY.open("a") as log:
        for index, (raf, referer) in enumerate(jobs, 1):
            try:
                record = {**settings(get(raf, referer, 524288)), "page": referer}
            except Refused:
                raise
            except Exception as error:
                record = {"error": str(error), "page": referer}
            log.write(json.dumps([raf, record]) + "\n")
            log.flush()
            if index % 100 == 0:
                print(f"  {index}/{len(jobs)}", flush=True)


def surveyed() -> list[tuple[str, dict]]:
    return [tuple(json.loads(line)) for line in SURVEY.read_text().splitlines()] if SURVEY.exists() else []


def select() -> None:
    """Up to PER_CAMERA neutral files per camera and slot (fewer for Provia), spread across each review."""
    groups: dict[tuple[str, str], list[tuple[str, dict]]] = collections.defaultdict(list)
    seen: set[tuple[str, ...]] = set()
    for url, record in surveyed():
        # Reviews often publish a file in two folders (photos/, sample_images/), but the same
        # name can also be a different photo, so a copy must match on settings too.
        review, name = url.split("/reviews/", 1)[-1].split("/")[0], url.rsplit("/", 1)[-1].lower()
        identity = (review, name, *(str(record.get(key)) for key in ("look", "shadow", "highlight", "dr", "chrome")))
        if identity in seen:
            continue
        # A rejected copy rules out its twin too.
        seen.add(identity)
        slot = SLOTS.get(record.get("look", ""))
        if not slot or not neutral(record):
            continue
        model = record.get("model") or review.removeprefix("fujifilm_").replace("_", "-").upper()
        groups[(slot, model)].append((url, record))
    pairs = []
    for (slot, model), files in sorted(groups.items()):
        # Acros beats plain Monochrome on the same body; keep one kind per camera and slot.
        if any(record["look"].startswith("Acros") for _, record in files):
            files = [(url, record) for url, record in files if record["look"].startswith("Acros")]
        limit = PER_CAMERA_SLOT.get(slot, PER_CAMERA)
        step = max(1, len(files) / limit)
        for index in range(min(limit, len(files))):
            url, record = files[int(index * step)]
            folder, file = url.rsplit("/", 2)[-2:]
            stem = file if folder == "sample_images" else f"{folder}-{file}"
            name = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{model}-{slot}-{stem}")
            pairs.append({
                "slot": slot, "camera": f"Fujifilm {model}", "look": record["look"], "url": url,
                "page": record["page"], "file": name, "source": "photographyblog.com",
                "license": "Copyright; reference only, never shipped or committed (DEC-17)",
            })
    MANIFEST.write_text(json.dumps({
        "version": 1, "description": __doc__.strip().splitlines()[0],
        "folder": str(WORK.relative_to(ROOT) / "files"), "pairs": pairs,
    }, indent=1))
    counts = collections.Counter(p["slot"] for p in pairs)
    cameras = {slot: len({p["camera"] for p in pairs if p["slot"] == slot}) for slot in counts}
    print(f"{len(pairs)} pairs")
    for slot, count in counts.most_common():
        print(f"  {slot}: {count} files from {cameras[slot]} cameras")


def fetch() -> None:
    folder = WORK / "files"
    folder.mkdir(parents=True, exist_ok=True)
    pairs = json.loads(MANIFEST.read_text())["pairs"]
    # The rarer simulations first: Provia is the one we already have most of.
    todo = sorted((p for p in pairs if not (folder / p["file"]).exists()), key=lambda p: p["slot"] == "standard")
    print(f"{len(pairs) - len(todo)} present, {len(todo)} to download", flush=True)
    for index, pair in enumerate(todo, 1):
        data = get(pair["url"], pair["page"])
        if data[:15] != b"FUJIFILMCCD-RAW":
            print(f"  not a RAF: {pair['url']}", file=sys.stderr)
            continue
        partial = folder / (pair["file"] + ".part")
        partial.write_bytes(data)
        partial.rename(folder / pair["file"])
        print(f"  {index}/{len(todo)} {pair['file']} ({len(data) / 1e6:.0f} MB)", flush=True)


def main() -> int:
    step = sys.argv[1] if len(sys.argv) > 1 else "survey"
    try:
        {"survey": survey, "select": select, "fetch": fetch}[step]()
    except Refused as refused:
        print(f"Stopped: the site refused a request ({refused}). Rerun later to resume.", file=sys.stderr)
        return 1
    if step == "survey":
        records = [record for _, record in surveyed()]
        print("looks:", dict(collections.Counter(r.get("look", "error") for r in records).most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
