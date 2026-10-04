#!/usr/bin/env python3
"""Generate the camera lists in docs/cameras.md (published at redlamp.app/cameras).

Three lists, between the document's `cameras:begin` and `cameras:end` markers:

  - verified: the CC0 raw.pixls.us samples in the decode tests (tests/decode/cameras.json), with
    their decoded size, their download paths from `mise run fixtures` or the camera coverage set
    (tests/decode/samples.json) and whether a colour reference is recorded (tests/golden/cameras)
  - tested with the camera bench: camera modes with evidence in docs/camera-bench.json, which
    scripts/camera-bench.py writes from the bench's reports, by tier (docs/camera-bench.md)
  - in an evaluation set: bodies whose CC0 samples the look-development set
    (research/look-dev/manifest.json) and the dust evaluation (`mise run fixtures-shoots`) develop
  - supported by LibRaw: every camera in the vendored LibRaw's own list (src/tables/cameralist.cpp),
    at the version config/vendored-libs.json pins and with the options scripts/vendor-libraw.sh
    builds it with (without the GoPro SDK or X3F tools, their cameras aren't listed)

    scripts/camera-list.py            # dry run: is the document current?
    scripts/camera-list.py --apply    # rewrite the generated block
    scripts/camera-list.py --check    # quiet; exit 1 when the block is stale (hooks and CI)

LibRaw's source is only in vendor/cache, which isn't committed. Without it the LibRaw list already in
the document is kept, as long as it was generated from the pinned version.
"""

import argparse
import difflib
import json
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCUMENT = ROOT / "docs/cameras.md"
BEGIN, END = "<!-- cameras:begin -->", "<!-- cameras:end -->"
PIXLS = "https://raw.pixls.us/data/"
TWO_WORD_MAKES = ("Digital Bolex", "OM Digital Solutions", "Konica Minolta", "Phase One")
MAKE_NAMES = {"FujiFilm": "Fujifilm", "PhaseOne": "Phase One", "BlackMagic": "Blackmagic", "RaspberryPi": "Raspberry Pi"}
# Names in brackets are usually another name or a note, so they're left out when matching; these
# cameras differ from the LibRaw entry that would match (the Pixel 4a isn't the Pixel 4a (5G)).
NOT_IN_LIBRAW_LIST = {"Google Pixel 4a"}
# The camera bench's tiers (docs/camera-bench.md, DEC-28) and checks, as the cameras page names them.
BENCH_TIERS = {
    "tested": "Tested by photographers",
    "problem": "Problem reported",
    "working": "Reported working",
    "unconfirmed": "Problem found once",
}
CHECK_TITLES = {
    "decode.opens": "Opens", "decode.black": "Black level", "decode.white": "White level",
    "decode.colour": "Colour matrix", "decode.edges": "Edges", "render.default": "Default rendering",
    "preview.orientation": "Orientation", "preview.framing": "Framing", "preview.structure": "Detail",
    "preview.exposure": "Exposure", "preview.cast": "Neutrals", "preview.highlights": "Highlights",
    "preview.colour": "Colours",
}


def key(name):
    """A camera name to compare by: without notes in brackets, case, spaces or punctuation."""
    return re.sub(r"[^a-z0-9]", "", re.sub(r"\(.*?\)", "", name).lower())


def libraw_version():
    return json.loads((ROOT / "config/vendored-libs.json").read_text())["LibRaw"]["version"]


def libraw_defines():
    """The macros Redlamp's LibRaw build defines, which decide which cameras its list includes."""
    return set(re.findall(r"-D(\w+)", (ROOT / "scripts/vendor-libraw.sh").read_text()))


def compiled(source, defined):
    """The lines of a C source that its #ifdef, #ifndef, #else and #endif keep for `defined`."""
    kept, conditions = [], []
    for line in source.splitlines():
        directive = re.match(r"\s*#\s*(ifdef|ifndef|if|else|endif)\b\s*(\w*)", line)
        if not directive:
            if all(conditions):
                kept.append(line)
            continue
        word, name = directive.groups()
        if word == "endif":
            conditions.pop()
        elif word == "else":
            conditions[-1] = not conditions[-1]
        else:
            conditions.append(word == "if" or (name in defined) == (word == "ifdef"))
    return "\n".join(kept)


def libraw_cameras(version):
    """LibRaw's camera list, from its source if it's here, else from the document; None if neither has it."""
    source = ROOT / f"vendor/cache/LibRaw-{version}/src/tables/cameralist.cpp"
    if source.exists():
        return re.findall(r'^\s*"(.*?)",', compiled(source.read_text(), libraw_defines()), re.M)
    current = DOCUMENT.read_text() if DOCUMENT.exists() else ""
    if f"## Supported by LibRaw {version}\n" not in current:
        return None
    listed, make = [], None
    for line in current.split(END)[0].split(f"## Supported by LibRaw {version}\n", 1)[1].splitlines():
        if line.startswith("### "):
            make = line[4:].strip()
        elif line.startswith("- ") and make:
            model = re.sub(r" \*\(.*?\)\*$", "", line[2:]).strip()
            listed.append(make if model == make else f"{make} {model}")
    return listed


def split_make(entry):
    for make in TWO_WORD_MAKES + tuple(MAKE_NAMES.values()):
        if entry.startswith(make + " "):
            return make, entry[len(make) + 1:]
    make, _, model = entry.partition(" ")
    return MAKE_NAMES.get(make, make), model or make


def fixture_paths(task):
    """raw.pixls.us paths a download task spells out, by file name (paths built in a loop are left out)."""
    paths = re.findall(r'"([A-Za-z]+/[^"$]+\.\w+)"', (ROOT / "mise/tasks" / task).read_text())
    return {urllib.parse.unquote(path.rsplit("/", 1)[1]): path for path in paths}


def pixls_camera(path):
    make, model = urllib.parse.unquote(path).split("/")[:2]
    return f"{make} {model}"


def display(entry):
    make, model = split_make(entry)
    return f"{make} {model}" if model != make else make


def generate(libraw):
    version = libraw_version()
    entries = {key(entry): entry for entry in libraw}

    def named(camera):
        """The camera as LibRaw lists it (with its other name or note), else as given."""
        found = entries.get(key(camera))
        return display(found) if found and camera not in NOT_IN_LIBRAW_LIST else camera

    decoded = json.loads((ROOT / "tests/decode/cameras.json").read_text())
    fixtures = fixture_paths("fixtures")
    coverage = {sample["file"]: sample for sample in json.loads((ROOT / "tests/decode/samples.json").read_text())["samples"]}
    verified, verified_keys = [], set()
    for file, record in decoded.items():
        path, sample = fixtures.get(file), coverage.get(file)
        if path:
            camera, link = pixls_camera(path), f"[{file}]({PIXLS}{path})"
        elif sample:
            camera, link = sample["camera"], f"[{file}]({sample['url']})"
        else:
            camera, link = f"{record['make']} {record['model']}", file
        name = named(camera)
        verified_keys.add(key(name))
        reference = "Yes" if (ROOT / f"tests/golden/cameras/{file}.json").exists() else "No"
        resolution = f"{record['width'] * record['height'] / 1e6:.0f} MP"
        verified.append((name, file.rsplit(".", 1)[1].upper(), record.get("layout", ""), resolution, reference, link))
    verified.sort(key=lambda row: (row[0].lower(), row[1]))

    evaluation, seen = [], set(verified_keys)
    for file, path in fixture_paths("fixtures-shoots").items():
        camera = pixls_camera(path)
        if key(camera) not in seen:
            seen.add(key(camera))
            evaluation.append((named(camera), "Dust evaluation", f"[{file}]({PIXLS}{path})"))
    for image in json.loads((ROOT / "research/look-dev/manifest.json").read_text())["images"]:
        words = image["camera"].split()
        camera = " ".join(words[1:] if len(words) > 2 and words[0] == words[1] else words)
        if key(camera) not in seen:
            seen.add(key(camera))
            evaluation.append((named(camera), "Look development", f"[{image['file']}]({image['url']})"))
    evaluation.sort(key=lambda row: row[0].lower())
    verified_names = {row[0] for row in verified}
    evaluation_names = {row[0] for row in evaluation}

    bench, bench_marks = [], {}
    evidence = ROOT / "docs/camera-bench.json"
    modes = json.loads(evidence.read_text())["modes"] if evidence.exists() else []
    headline = {}
    for mode in modes:
        if mode["tier"] == "verified" or mode["camera"].startswith("Unknown"):
            continue
        name = named(mode["camera"])
        problems = "; ".join(f"{CHECK_TITLES.get(p['check'], p['check'])}: {p['summary'].rstrip('.')}"
                             + (f" ({p['tracker']})" if p["tracker"] else "") for p in mode["problems"])
        bench.append((name, mode["label"], BENCH_TIERS[mode["tier"]], str(mode["photos"]), str(mode["contributors"]),
                      problems.replace("|", "/") or "None"))
        if name not in headline or mode["photos"] > headline[name]["photos"]:
            headline[name] = mode
    bench.sort(key=lambda row: (row[0].lower(), row[1]))
    bench_marks = {name: BENCH_TIERS[mode["tier"]].lower() for name, mode in headline.items()}

    makes = {}
    for entry in libraw:
        make, model = split_make(entry)
        listed = display(entry)
        if listed in verified_names:
            mark = " *(verified)*"
        elif listed in bench_marks:
            mark = f" *({bench_marks[listed]})*"
        elif listed in evaluation_names:
            mark = " *(in an evaluation set)*"
        else:
            mark = ""
        makes.setdefault(make, []).append(f"- {model}{mark}")

    lines = [
        BEGIN,
        "<!-- Generated by scripts/camera-list.py from the decode tests, the sample downloads, the camera bench's evidence and LibRaw's camera list."
        " Change those, then run it with --apply. -->",
        "",
        f"**LibRaw:** {version} · **Verified:** {len(verified_names)} cameras · "
        + (f"**Tested with the camera bench:** {len(bench)} camera modes · " if bench else "")
        + f"**In an evaluation set:** {len(evaluation)} cameras · **Supported by LibRaw:** {len(libraw):,} cameras",
        "",
        "## Verified by the decode tests",
        "",
        "| Camera | Format | Sensor | Resolution | Colour reference | Sample |",
        "| --- | --- | --- | --- | --- | --- |",
        *(f"| {' | '.join(row)} |" for row in verified),
        "",
        *([
            "## Tested with the camera bench",
            "",
            "| Camera | Raw mode | Evidence | Photos | Photographers | Problems |",
            "| --- | --- | --- | --- | --- | --- |",
            *(f"| {' | '.join(row)} |" for row in bench),
            "",
        ] if bench else []),
        "## In an evaluation set",
        "",
        "| Camera | Set | Sample |",
        "| --- | --- | --- |",
        *(f"| {' | '.join(row)} |" for row in evaluation),
        "",
        f"## Supported by LibRaw {version}",
        "",
    ]
    for make in sorted(makes, key=str.lower):
        lines += [f"### {make}", "", *makes[make], ""]
    lines.append(END)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="rewrite the generated block")
    parser.add_argument("--check", action="store_true", help="print only when the block is stale")
    options = parser.parse_args()

    version = libraw_version()
    libraw = libraw_cameras(version)
    if libraw is None:
        sys.exit(f"docs/cameras.md lists another LibRaw version than the pinned {version}, and its source isn't in "
                 f"vendor/cache: run scripts/vendor-libraw.sh, then scripts/camera-list.py --apply.")
    current = DOCUMENT.read_text()
    if BEGIN not in current or END not in current:
        sys.exit(f"docs/cameras.md has no {BEGIN} … {END} block")
    before, rest = current.split(BEGIN, 1)
    after = rest.split(END, 1)[1]
    updated = before + generate(libraw) + after
    if updated == current:
        if not options.check:
            print("docs/cameras.md is current.")
        return
    if options.apply:
        DOCUMENT.write_text(updated)
        print("Rewrote the camera lists in docs/cameras.md.")
        return
    diff = difflib.unified_diff(current.splitlines(), updated.splitlines(), "docs/cameras.md", "generated", lineterm="", n=0)
    print("\n".join(list(diff)[:40]))
    print("\ndocs/cameras.md is out of date: run scripts/camera-list.py --apply.")
    sys.exit(1)


if __name__ == "__main__":
    main()
