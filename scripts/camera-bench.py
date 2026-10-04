#!/usr/bin/env python3
"""Turn camera bench reports into the evidence the cameras page shows (CAM-17).

Reads the submissions the relay keeps in the private repository (pdcgomes/redlamp-bench, through
`gh`) and the raw.pixls.us seed run (research/camera-bench/raw-pixls-seed.json), groups their photos
by camera mode, drops photos sent twice, and decides each mode's tier by DEC-28's thresholds
(proposed). Writes docs/camera-bench.json, with no contributor IDs or file hashes; scripts/camera-list.py
adds the tiers to docs/cameras.md, and redlamp.app/api/bench/summary serves what each mode still needs.

    scripts/camera-bench.py                       # dry run: what would change
    scripts/camera-bench.py --apply               # write docs/camera-bench.json
    scripts/camera-bench.py --no-repo             # without the private repository
    scripts/camera-bench.py --reports a.json --as "Pedro's X-T5"   # add local reports

A check's evidence counts only at the newest version of that check any report has, so a check that
changed isn't judged on older measurements. Where a newer version only changed thresholds, older
results are judged again from the measurements they carry (decode.black 2, as 3).
"""

import argparse
import collections
import datetime
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/camera-bench.json"
SEED = ROOT / "research/camera-bench/raw-pixls-seed.json"
REPOSITORY = "pdcgomes/redlamp-bench"
CONDITIONS = ["baseISO", "highISO", "portrait", "clippedHighlights", "warmLight"]
DIFFERS = {"colours", "brightness", "framing", "artefacts"}

# DEC-28 (proposed): what moves a camera mode between tiers.
TESTED = {"contributors": 3, "photos": 10, "same": 2, "failing_share": 0.10}
PROBLEM_CONTRIBUTORS = 2


def key(name):
    return re.sub(r"[^a-z0-9]", "", re.sub(r"\(.*?\)", "", (name or "").lower()))


def worse(a, b):
    order = ["skipped", "pass", "warn", "fail"]
    return a if order.index(a) >= order.index(b) else b


def black_v3(numbers):
    """decode.black version 3 (CameraBenchChecks.black) from a version 2 or 3 result's measurements."""
    black, white = numbers["black"], numbers["white"]
    span = max(white - black, 1)
    verdict, findings = "pass", []
    optical, noise = numbers.get("opticalBlack"), numbers.get("opticalBlackNoise")
    if optical is not None and noise is not None and optical >= 0.25 * black:
        offset = abs(optical - black)
        if offset > max(4, 5 * noise) and offset > 0.01 * span:
            verdict = "fail"
        elif offset > max(2, 3 * noise):
            verdict = worse(verdict, "warn")
        if offset > max(2, 3 * noise):
            findings.append(f"the masked margins sit at {optical:.1f}, not the stated {black:.1f}")
    dark = numbers.get("darkPercentile")
    if dark is not None:
        below = (black - dark) / span
        if below > 0.02:
            verdict = "fail"
        elif below > 0.01:
            verdict = worse(verdict, "warn")
        if below > 0.01:
            findings.append(f"many photosites sit {below * 100:.1f}% of the range below it")
    summary = (f"The black level ({black:.1f}) agrees with the sensor." if not findings
               else "The black level may be wrong: " + "; ".join(findings) + ".")
    return verdict, summary


# Check → (the oldest version whose measurements the current rule reads, the current version, the rule).
REJUDGED = {"decode.black": (2, 3, black_v3)}


def rejudge(check):
    rule = REJUDGED.get(check["id"])
    if not rule or not rule[0] <= check["version"] < rule[1] or check["verdict"] == "skipped":
        return check
    verdict, summary = rule[2](check["measurements"])
    return {**check, "version": rule[1], "verdict": verdict, "summary": summary}


def verified_cameras():
    """Camera names the decode tests verify, as keys: as decoded, and as the coverage set names them."""
    decoded = json.loads((ROOT / "tests/decode/cameras.json").read_text())
    names = {key(f"{record.get('make', '')} {record.get('model', '')}") for record in decoded.values()}
    samples = json.loads((ROOT / "tests/decode/samples.json").read_text())["samples"]
    return names | {key(sample["camera"]) for sample in samples}


def current_decoder():
    version = json.loads((ROOT / "config/vendored-libs.json").read_text())["LibRaw"]["version"]
    return f"LibRaw {version}"


def repository_reports(repository):
    """(contributor, report, received) for each submission in the private repository, Preview's left out."""
    with tempfile.TemporaryDirectory() as folder:
        clone = subprocess.run(["gh", "repo", "clone", repository, folder, "--", "--depth", "1", "--quiet"],
                               capture_output=True, text=True)
        if clone.returncode != 0:
            print(f"warning: couldn't read {repository} ({clone.stderr.strip()[:200]}); using local reports only",
                  file=sys.stderr)
            return []
        found = []
        for path in sorted(pathlib.Path(folder, "submissions").rglob("*.json")):
            record = json.loads(path.read_text())
            report = record.get("report", {})
            found.append((report.get("contributor") or f"anonymous:{path.stem}", report, record.get("received")))
        return found


def local_reports(paths, label):
    found = []
    for path in paths:
        report = json.loads(pathlib.Path(path).read_text())
        found.append((report.get("contributor") or label or path, report, None))
    return found


def aggregate(reports, verified, decoder):
    photos = {}
    answers = collections.defaultdict(list)
    for contributor, report, received in reports:
        environment = report.get("environment", {})
        for photo in report.get("photos", []):
            photo = {**photo, "checks": [rejudge(check) for check in photo["checks"]]}
            identity = photo.get("identity", {})
            entry = {"contributor": contributor, "photo": photo, "received": received or "",
                     "decoder": environment.get("decoder", ""), "redlamp": environment.get("redlamp", ""),
                     "aliases": {key(photo["mode"]["camera"]), key(f"{identity.get('make', '')} {identity.get('model', '')}")}}
            hash_ = photo.get("fileHash") or f"{contributor}:{id(photo)}"
            if hash_ not in photos or entry["received"] >= photos[hash_]["received"]:
                photos[hash_] = entry
        for answer in report.get("answers", []):
            answers[answer["mode"]].append((contributor, answer["choice"]))

    newest = collections.defaultdict(int)
    for entry in photos.values():
        for check in entry["photo"]["checks"]:
            newest[check["id"]] = max(newest[check["id"]], check["version"])

    by_mode = collections.defaultdict(list)
    for entry in photos.values():
        by_mode[entry["photo"]["mode"]["key"]].append(entry)

    modes = []
    for mode_key, entries in by_mode.items():
        mode = entries[0]["photo"]["mode"]
        current = [e for e in entries if e["decoder"].startswith(decoder)]
        contributors = {e["contributor"] for e in entries}
        conditions = {c for e in entries for c in e["photo"]["conditions"]}
        checks = collections.defaultdict(lambda: {"pass": 0, "warn": 0, "fail": 0})
        failing = collections.defaultdict(lambda: {"contributors": set(), "photos": 0, "summaries": collections.Counter(), "tracker": None})
        failed_photos = 0
        for entry in entries:
            failed = False
            for check in entry["photo"]["checks"]:
                if check["version"] != newest[check["id"]] or check["verdict"] == "skipped":
                    continue
                checks[check["id"]][check["verdict"]] += 1
                if check["verdict"] == "fail":
                    failed = True
                    problem = failing[check["id"]]
                    problem["contributors"].add(entry["contributor"])
                    problem["photos"] += 1
                    problem["summaries"][check["summary"]] += 1
                    problem["tracker"] = problem["tracker"] or check.get("tracker")
            failed_photos += failed
        choices = collections.Counter(choice for _, choice in answers.get(mode_key, []))
        same = choices.get("same", 0)
        differs = sum(choices.get(choice, 0) for choice in DIFFERS)
        is_verified = any(entry["aliases"] & verified for entry in entries)
        current_contributors = {e["contributor"] for e in current}
        current_conditions = {c for e in current for c in e["photo"]["conditions"]}
        confirmed = any(len(p["contributors"]) >= PROBLEM_CONTRIBUTORS for p in failing.values())
        if is_verified:
            tier = "verified"
        elif confirmed or differs > 0:
            tier = "problem"
        elif (len(current_contributors) >= TESTED["contributors"] and len(current) >= TESTED["photos"]
              and current_conditions >= set(CONDITIONS) and failed_photos <= TESTED["failing_share"] * len(entries)
              and same >= TESTED["same"]):
            tier = "tested"
        elif any(not any(c["verdict"] == "fail" and c["version"] == newest[c["id"]] for c in e["photo"]["checks"])
                 for e in entries):
            tier = "working"
        else:
            tier = "unconfirmed"
        modes.append({
            "key": mode_key,
            "camera": mode["camera"],
            "label": mode["label"],
            "tier": tier,
            "verified": is_verified,
            "contributors": len(contributors),
            "photos": len(entries),
            "conditions": [c for c in CONDITIONS if c in conditions],
            "needs": [c for c in CONDITIONS if c not in conditions],
            "answers": dict(sorted(choices.items())),
            "checks": {check_id: counts for check_id, counts in sorted(checks.items())},
            "problems": [
                {"check": check_id, "summary": p["summaries"].most_common(1)[0][0], "tracker": p["tracker"],
                 "contributors": len(p["contributors"]), "photos": p["photos"]}
                for check_id, p in sorted(failing.items())
            ],
            "decoders": sorted({e["decoder"] for e in entries}),
            "redlamp": sorted({e["redlamp"] for e in entries}),
        })
    return sorted(modes, key=lambda mode: (mode["camera"].lower(), mode["label"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="write docs/camera-bench.json")
    parser.add_argument("--no-repo", action="store_true", help="leave out the private repository")
    parser.add_argument("--repo", default=REPOSITORY)
    parser.add_argument("--reports", nargs="*", default=[], help="more report files")
    parser.add_argument("--as", dest="label", help="the contributor to count local reports as")
    options = parser.parse_args()

    reports = [] if options.no_repo else repository_reports(options.repo)
    if SEED.exists():
        reports += local_reports([SEED], "raw.pixls.us")
    reports += local_reports(options.reports, options.label)
    modes = aggregate(reports, verified_cameras(), current_decoder())
    evidence = {
        "format": 1,
        "description": "The camera bench's evidence per camera mode (docs/camera-bench.md), written by scripts/camera-bench.py.",
        "thresholds": "DEC-28 (proposed)",
        "decoder": current_decoder(),
        "generated": datetime.date.today().isoformat(),
        "modes": modes,
    }
    tiers = collections.Counter(mode["tier"] for mode in modes)
    print(f"{len(modes)} camera modes from {len(reports)} reports: "
          + ", ".join(f"{count} {tier}" for tier, count in tiers.most_common()))
    for mode in modes:
        for problem in mode["problems"]:
            tracker = f" ({problem['tracker']})" if problem["tracker"] else ""
            print(f"  {mode['camera']}, {mode['label']}: {problem['check']}: {problem['summary']}{tracker}"
                  f" [{problem['contributors']} contributor(s), {problem['photos']} photo(s)]")

    current = json.loads(OUTPUT.read_text()) if OUTPUT.exists() else None
    unchanged = current is not None and {**current, "generated": ""} == {**evidence, "generated": ""}
    if unchanged:
        print("docs/camera-bench.json is current.")
    elif options.apply:
        OUTPUT.write_text(json.dumps(evidence, indent=1, ensure_ascii=False) + "\n")
        print(f"wrote {OUTPUT.relative_to(ROOT)}; run scripts/camera-list.py --apply next")
    else:
        print("Dry run: run with --apply to write docs/camera-bench.json.")


if __name__ == "__main__":
    main()
