#!/usr/bin/env python3
"""Capture One's camera list as JSON: which models it tethers, with Live View and wirelessly.

Reads Capture One's help-centre article "Camera Models and RAW Files Supported by Capture One"
through the help centre's public API (the pages themselves refuse scripted requests) and writes
one record per model with the maker, the version that added it, its raw formats, the three
tethering flags and its notes. Prints a summary by maker.

    research/prototypes/tethering/capture_one_cameras.py [--out data/capture-one-cameras.json]
"""

import argparse
import collections
import datetime
import html
import json
import re
import sys
import urllib.request

ARTICLE = 360002718118
API = f"https://support.captureone.com/api/v2/help_center/en-us/articles/{ARTICLE}.json"
PAGE = f"https://support.captureone.com/hc/en-us/articles/{ARTICLE}"
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129 Safari/537.36"


def text(fragment: str) -> str:
    fragment = re.sub(r"<br\s*/?>", "\n", fragment)
    fragment = re.sub(r"<[^>]+>", "", fragment)
    return html.unescape(fragment).replace("\xa0", " ").strip()


def flag(value: str) -> dict:
    """'Yes', 'No', 'Yes*' or a truncated 'N': the answer, and whether a footnote qualifies it."""
    value = value.strip()
    return {"value": value.lower().startswith("y"), "qualified": value.endswith("*")}


def record(maker: str, name: str, fields: dict[str, str]) -> dict:
    if "Tethered/Live View/Wireless" in fields:
        tether, live_view, wireless = (fields["Tethered/Live View/Wireless"] + "//").split("/")[:3]
    else:
        # The iPhones list only "Tethered: Yes (only through Capture One mobile …)".
        tether, live_view, wireless = fields.get("Tethered", "No"), "No", "No"
    return {
        "maker": maker,
        "model": name,
        "versionAdded": fields.get("Version Added", ""),
        "files": fields.get("File Support", ""),
        "tethered": flag(tether),
        "liveView": flag(live_view),
        "wireless": flag(wireless),
        "notes": "; ".join(value for key, value in fields.items() if key == "Notes" and value)
        or (fields.get("Tethered", "") if "Tethered/Live View/Wireless" not in fields else ""),
    }


def parse(body: str) -> tuple[list[dict], dict[str, list[str]]]:
    """Each model is a name line, then "- Key: value" lines with its Version Added; anything else is a note."""
    sections = re.split(r"<h2[^>]*>", body)[1:]
    models, notes = [], {}
    for section in sections:
        heading, _, rest = section.partition("</h2>")
        maker = text(heading)
        rest = re.sub(r"</?p[^>]*>", "\n", rest)
        lines = [line.strip() for line in text(rest).split("\n") if line.strip()]
        if maker.startswith("Frequently Asked"):
            notes["FAQ"] = lines
            continue
        section_notes, name, fields = [], None, {}
        for line in lines + [""]:
            if line.startswith("-") and name is not None:
                key, _, value = line.lstrip("- ").partition(":")
                fields[key.strip()] = value.strip()
                continue
            if name is not None:
                if "Version Added" in fields:
                    models.append(record(maker, name, fields))
                else:
                    section_notes.append(name)
                name, fields = None, {}
            # A name usually ends in a colon, but not always (Canon EOS R50 V).
            if line and len(line) < 80 and "Back to top" not in line:
                name = line.rstrip(":").strip()
            elif line and "Back to top" not in line:
                section_notes.append(line)
        if section_notes:
            notes[maker] = section_notes
    return models, notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", help="write the snapshot here")
    args = parser.parse_args()

    request = urllib.request.Request(API, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        article = json.load(response)["article"]
    models, notes = parse(article["body"])

    snapshot = {
        "source": PAGE,
        "title": article["title"],
        "articleUpdated": article["updated_at"],
        "checked": datetime.date.today().isoformat(),
        "models": models,
        "notes": notes,
    }
    if args.out:
        with open(args.out, "w") as file:
            json.dump(snapshot, file, indent=1, ensure_ascii=False)
            file.write("\n")

    by_maker = collections.OrderedDict()
    for model in models:
        counts = by_maker.setdefault(model["maker"], collections.Counter())
        counts["models"] += 1
        for key in ("tethered", "liveView", "wireless"):
            counts[key] += model[key]["value"]
    print(f"{article['title']} (updated {article['updated_at'][:10]}, checked {snapshot['checked']})")
    print(f"{'Maker':38}{'Models':>8}{'Tethered':>10}{'Live View':>11}{'Wireless':>10}")
    total = collections.Counter()
    for maker, counts in sorted(by_maker.items(), key=lambda item: -item[1]["tethered"]):
        total.update(counts)
        print(f"{maker[:37]:38}{counts['models']:>8}{counts['tethered']:>10}{counts['liveView']:>11}{counts['wireless']:>10}")
    print(f"{'Total':38}{total['models']:>8}{total['tethered']:>10}{total['liveView']:>11}{total['wireless']:>10}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
