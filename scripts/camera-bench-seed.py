#!/usr/bin/env python3
"""Runs the camera bench over raw.pixls.us: one CC0 file per camera without a verified sample.

The camera bench's first evidence, before anyone contributes (CAM-14): for each camera in
raw.pixls.us's repository that the decode tests don't verify, the smallest full-resolution CC0
file is downloaded, checked against its SHA-256, run through `redlamp camera-bench`, and deleted.
One download at a time with a pause between, as raw.pixls.us is run by volunteers. The reports
are merged into one, in the format the app sends (docs/camera-bench.schema.json).

    scripts/camera-bench-seed.py --redlamp <path to redlamp> [-o build/camera-bench/seed.json]
        [--max-mb 60] [--pause 2] [--limit N] [--pairs <dir>] [--recheck decode.black,decode.edges]

Build the CLI in Release first (`xcodebuild ... -scheme redlamp -configuration Release`). A run
that stops part way resumes: photos already in the output report are skipped. `--recheck` runs again
the cameras whose photos failed the named checks, after a check changes, replacing their results.
"""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPOSITORY = "https://raw.pixls.us/json/getrepository.php?set=all"
# Reduced-resolution modes; the bench wants each camera's full-resolution raw.
REDUCED = re.compile(r"sraw|mraw|small|medium|half|\b[sm]\b", re.I)


def key(name):
    return re.sub(r"[^a-z0-9]", "", re.sub(r"\(.*?\)", "", name.lower()))


def verified_cameras():
    decoded = json.loads((ROOT / "tests/decode/cameras.json").read_text())
    names = {key(f"{record.get('make', '')} {record.get('model', '')}") for record in decoded.values()}
    samples = json.loads((ROOT / "tests/decode/samples.json").read_text())["samples"]
    return names | {key(sample["camera"]) for sample in samples}


def candidates(max_mb):
    rows = json.loads(urllib.request.urlopen(REPOSITORY, timeout=60).read())["data"]
    verified = verified_cameras()
    cameras = {}
    for make, model, mode, _mp, _x, licence, _date, file_html, *_ in rows:
        link = re.search(r"href='([^']+)'", file_html)
        size = re.search(r"\(([\d.]+)MB\)", file_html)
        checksum = re.search(r"Checksum'>([0-9a-f]+)", file_html)
        if "zero" not in licence or not (link and size and checksum) or key(f"{make} {model}") in verified:
            continue
        entry = {"camera": f"{make} {model}", "mode": mode, "url": urllib.parse.quote(link.group(1), safe=":/"),
                 "megabytes": float(size.group(1)), "sha256": checksum.group(1)}
        cameras.setdefault(entry["camera"], []).append(entry)
    chosen = []
    for files in cameras.values():
        full = [entry for entry in files if not REDUCED.search(entry["mode"])] or files
        smallest = min(full, key=lambda entry: entry["megabytes"])
        if smallest["megabytes"] <= max_mb:
            chosen.append(smallest)
    return sorted(chosen, key=lambda entry: entry["camera"].lower())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--redlamp", required=True, help="the redlamp command-line tool, built in Release")
    parser.add_argument("-o", "--output", default=str(ROOT / "build/camera-bench/seed.json"))
    parser.add_argument("--max-mb", type=float, default=60)
    parser.add_argument("--pause", type=float, default=2)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--pairs", help="keep side-by-side pairs here")
    parser.add_argument("--recheck", help="comma-separated check IDs: run again the cameras that failed them")
    options = parser.parse_args()

    output = pathlib.Path(options.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    merged = json.loads(output.read_text()) if output.exists() else None
    done = {photo["fileHash"] for photo in merged["photos"]} if merged else set()
    recheck = None
    if options.recheck and merged:
        ids = set(options.recheck.split(","))
        recheck = {photo["fileHash"] for photo in merged["photos"]
                   if any(c["id"] in ids and c["verdict"] == "fail" for c in photo["checks"])}
        done -= recheck
    chosen = candidates(options.max_mb)[: options.limit]
    print(f"{len(chosen)} cameras without a verified sample, {sum(c['megabytes'] for c in chosen):,.0f} MB")

    failures = []
    with tempfile.TemporaryDirectory() as folder:
        for number, entry in enumerate(chosen, 1):
            if entry["sha256"] in done or (recheck is not None and entry["sha256"] not in recheck):
                continue
            name = re.sub(r"[^A-Za-z0-9._-]+", "-", entry["camera"]) + "." + entry["url"].rsplit(".", 1)[-1]
            path = pathlib.Path(folder) / name
            try:
                data = urllib.request.urlopen(entry["url"], timeout=600).read()
            except Exception as error:
                failures.append((entry["camera"], f"download: {error}"))
                continue
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                failures.append((entry["camera"], "checksum mismatch"))
                continue
            path.write_bytes(data)
            report = pathlib.Path(folder) / "report.json"
            command = [options.redlamp, "camera-bench", str(path), "--all", "-o", str(report)]
            if options.pairs:
                command += ["--pairs", options.pairs]
            run = subprocess.run(command, capture_output=True, text=True, timeout=900)
            path.unlink()
            if not report.exists():
                failures.append((entry["camera"], f"no report (status {run.returncode}): {run.stderr.strip()[-200:]}"))
                continue
            result = json.loads(report.read_text())
            report.unlink()
            for photo in result["photos"]:
                photo["fileHash"] = entry["sha256"]
            if merged is None:
                merged = result
            else:
                merged["photos"] = [p for p in merged["photos"] if p["fileHash"] != entry["sha256"]] + result["photos"]
                merged["environment"] = result["environment"]
            output.write_text(json.dumps(merged, indent=1, sort_keys=True))
            verdicts = ", ".join(f"{c['id']} {c['verdict']}" for p in result["photos"] for c in p["checks"]
                                 if c["verdict"] in ("warn", "fail"))
            print(f"[{number}/{len(chosen)}] {entry['camera']}: {verdicts or 'pass'}", flush=True)
            time.sleep(options.pause)
    for camera, reason in failures:
        print(f"not benched: {camera}: {reason}", file=sys.stderr)
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
