#!/usr/bin/env python3
"""Redlamp's performance history (docs/performance/history.jsonl): append a run, and say what changed.

One record per line, oldest first. A record has the date, the commit, the machine, the load average
before and after, whether that load made it noisy, where the numbers came from (`harness`, from
scripts/perf-record.sh; `readme`, from the README's tables through scripts/perf-backfill.py; `e2e`,
from the regression suite; `release`, a release's sizes, which no machine or load changes) and its
metrics by ID (docs/performance/metrics.json), each with a value and, where measured, the slowest
and fastest file and the runs' spread.

    scripts/perf-history.py append --bench b.json --sweep s.json --folders f.json --load-before 3.1 --load-after 3.4
    scripts/perf-history.py report     # what changed in the latest run of each metric
    scripts/perf-history.py import record.json --commit abc1234 [--apply]   # a kit's record (perf-kit.sh)
    scripts/perf-history.py release v0.2.6-prealpha [--zip Redlamp.zip] [--apply]   # a release's sizes

Adding a record redraws the README's performance card (scripts/perf-card.py), so the card changes in
the commit that records it.

A metric got faster or slower when it moved by more than 10%, or by more than its runs' own spread
if that's larger, against the previous record from the same source on the same machine. Noisy
records are kept but never compared. web/lib/performance.ts applies the same rules for the site.
"""

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HISTORY = ROOT / "docs/performance/history.jsonl"
METRICS = ROOT / "docs/performance/metrics.json"
THRESHOLD = 0.10
# Above this one-minute load average (other work running), a run is noisy.
NOISY_LOAD = 8.0


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def sysctl(name):
    return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()


def records():
    if not HISTORY.exists():
        return []
    return [json.loads(line) for line in HISTORY.read_text().splitlines() if line.strip()]


def registry():
    return {metric["id"]: metric for metric in json.loads(METRICS.read_text())["metrics"]}


def change(metric, older, newer):
    """'faster', 'slower' or None for one metric between two records' entries."""
    old, new = older["value"], newer["value"]
    if old <= 0:
        return None
    ratio = (new - old) / old
    threshold = max(THRESHOLD, older.get("spread", 0), newer.get("spread", 0))
    if abs(ratio) <= threshold:
        return None
    worse = ratio > 0 if metric["better"] == "lower" else ratio < 0
    return ("slower" if worse else "faster"), ratio


def word(metric, verdict):
    """'less' and 'more' for memory and sizes, as the page says them."""
    if metric["unit"] in ("MB", "GB"):
        return {"faster": "less", "slower": "more"}.get(verdict, verdict)
    return verdict


def comparable(record, other):
    return (record["source"] == other["source"] and not other.get("noisy")
            and record["machine"].get("chip") == other["machine"].get("chip"))


def report(history, metrics):
    """Each metric's change in the latest record that has it, against the previous comparable one."""
    lines = []
    for metric_id, metric in metrics.items():
        having = [record for record in history if metric_id in record["metrics"]]
        if not having:
            continue
        latest = having[-1]
        if latest.get("noisy"):
            load = max(filter(None, [latest.get("load", {}).get("before"), latest.get("load", {}).get("after")]), default=None)
            lines.append(f"  {metric['label']}: latest record noisy{f' (load {load:.1f})' if load else ''}, not compared")
            continue
        earlier = [record for record in having[:-1] if comparable(latest, record)]
        if not earlier:
            continue
        found = change(metric, earlier[-1]["metrics"][metric_id], latest["metrics"][metric_id])
        if found:
            verdict, ratio = found
            lines.append(f"  {word(metric, verdict).upper():6s} {metric['label']}: {earlier[-1]['metrics'][metric_id]['value']:.4g} → "
                         f"{latest['metrics'][metric_id]['value']:.4g} {metric['unit']} ({ratio:+.0%}, "
                         f"{earlier[-1]['commit']} → {latest['commit']})")
    return lines


def append(options, metrics):
    entries = {}
    if options.bench:
        bench = json.loads(pathlib.Path(options.bench).read_text())
        for metric_id, entry in bench["metrics"].items():
            entries[metric_id] = {key: round(entry[key], 4) for key in ("value", "low", "high", "spread")}
    for path in (options.sweep, options.folders, options.e2e):
        if path and pathlib.Path(path).exists():
            for metric_id, value in json.loads(pathlib.Path(path).read_text()).items():
                entries[metric_id] = {"value": round(value, 4)}
    unknown = sorted(set(entries) - set(metrics))
    if unknown:
        sys.exit(f"metrics missing from docs/performance/metrics.json: {', '.join(unknown)}")
    if not entries:
        sys.exit("nothing measured")
    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    record = {
        "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "commit": git("rev-parse", "--short", "HEAD"),
        "subject": git("log", "-1", "--format=%s"),
        "dirty": dirty,
        "source": options.source,
        "machine": {
            "chip": sysctl("machdep.cpu.brand_string"),
            "memoryGB": int(sysctl("hw.memsize") or 0) // 2**30,
            "macOS": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
        },
        "load": {"before": options.load_before, "after": options.load_after},
        "noisy": max(options.load_before, options.load_after) > NOISY_LOAD,
        "runs": json.loads(pathlib.Path(options.bench).read_text())["runs"] if options.bench else None,
        "metrics": dict(sorted(entries.items())),
    }
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    with HISTORY.open("a") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"Recorded {len(entries)} metrics at {record['commit']}{' (uncommitted changes)' if dirty else ''}"
          f"{', noisy: load ' + format(max(options.load_before, options.load_after), '.1f') if record['noisy'] else ''}.")
    redraw_card()


def redraw_card():
    subprocess.run([str(ROOT / "scripts/perf-card.py"), "--apply"], cwd=ROOT, check=False)


def installed_bytes(app):
    """What Finder counts as an app's size: its files' own sizes, symbolic links not followed."""
    total = 0
    for folder, _, files in os.walk(app):
        for name in files:
            path = pathlib.Path(folder) / name
            if not path.is_symlink():
                total += path.stat().st_size
    return total


def release(options, metrics):
    """A release's download and installed size, from its zip on GitHub (or --zip), in date order."""
    tag = options.tag if options.tag.startswith("v") else f"v{options.tag}"
    version = tag[1:]
    if any(record.get("version") == version for record in records()):
        sys.exit(f"{version} is already in the history")
    commit = git("rev-parse", "--short", f"{tag}^{{commit}}")
    if not commit:
        sys.exit(f"no tag {tag} here (git fetch --tags)")
    name = f"Redlamp-{version}.zip"
    found = subprocess.run(["gh", "release", "view", tag, "--json", "publishedAt"], cwd=ROOT, capture_output=True, text=True)
    published = json.loads(found.stdout)["publishedAt"] if found.returncode == 0 else None
    if not published and not options.zip:
        sys.exit(f"{tag} isn't published on GitHub: give its zip with --zip")
    with tempfile.TemporaryDirectory() as work:
        archive = pathlib.Path(options.zip) if options.zip else pathlib.Path(work) / name
        if not options.zip:
            subprocess.run(["gh", "release", "download", tag, "--pattern", name, "--dir", work], cwd=ROOT, check=True)
        subprocess.run(["ditto", "-x", "-k", str(archive), f"{work}/unzipped"], check=True)
        app = pathlib.Path(work, "unzipped", "Redlamp.app")
        if not app.is_dir():
            sys.exit(f"{archive.name} holds no Redlamp.app")
        download, installed = archive.stat().st_size, installed_bytes(app)
    date = (datetime.datetime.fromisoformat(published.replace("Z", "+00:00")) if published
            else datetime.datetime.now(datetime.timezone.utc)).astimezone()
    record = {
        "date": date.isoformat(timespec="seconds"),
        "commit": commit,
        "subject": git("log", "-1", "--format=%s", tag),
        "source": "release",
        "version": version,
        "machine": {},
        "noisy": False,
        "metrics": {"app-size": {"value": round(installed / 1e6, 2)}, "download-size": {"value": round(download / 1e6, 2)}},
    }
    print(f"{version} at {commit}, {record['date']}: {download / 1e6:.1f} MB to download, {installed / 1e6:.1f} MB installed")
    if not options.apply:
        print("Dry run: --apply adds it.")
        return
    lines = [line for line in HISTORY.read_text().splitlines() if line.strip()]
    position = sum(1 for line in lines if datetime.datetime.fromisoformat(json.loads(line)["date"]) <= date)
    lines.insert(position, json.dumps(record, ensure_ascii=False))
    HISTORY.write_text("\n".join(lines) + "\n")
    print(f"Added to {HISTORY.relative_to(ROOT)}.")
    redraw_card()


def import_record(options, metrics):
    """A record made elsewhere (scripts/perf-kit.sh's run.sh): checked, compared, appended with --apply."""
    record = json.loads(pathlib.Path(options.record).read_text())
    if options.commit and record.get("commit") != options.commit:
        sys.exit(f"the record names commit {record.get('commit')}, not the kit's {options.commit}")
    if subprocess.run(["git", "cat-file", "-e", f"{record.get('commit')}^{{commit}}"], cwd=ROOT,
                      capture_output=True).returncode != 0:
        sys.exit(f"commit {record.get('commit')} isn't in this repository")
    unknown = sorted(set(record["metrics"]) - set(metrics))
    if unknown:
        sys.exit(f"metrics missing from docs/performance/metrics.json: {', '.join(unknown)}")
    machine = record["machine"]
    load = record["load"]
    print(f"{record['date']} at {record['commit']}: {machine['chip']}, {machine['memoryGB']} GB, macOS {machine['macOS']}; "
          f"load {load['before']} before, {load['after']} after{' (noisy)' if record.get('noisy') else ''}")
    history = records()
    earlier = [other for other in history
               if other["source"] == record["source"] and other["machine"].get("chip") == machine["chip"]]
    if not earlier:
        print(f"The first record from {machine['chip']}:")
    else:
        print(f"Against {earlier[-1]['date']} at {earlier[-1]['commit']}{' (noisy)' if earlier[-1].get('noisy') else ''}:")
    for metric_id, entry in record["metrics"].items():
        metric = metrics[metric_id]
        old = earlier[-1]["metrics"].get(metric_id) if earlier else None
        if not old:
            print(f"  {metric['label']}: {entry['value']:.4g} {metric['unit']}")
            continue
        found = change(metric, old, entry)
        noisy = record.get("noisy") or earlier[-1].get("noisy")
        verdict = "noisy" if noisy and found else (found[0] if found else "same")
        ratio = (entry["value"] - old["value"]) / old["value"] if old["value"] else 0
        print(f"  {word(metric, verdict):6s} {metric['label']}: {old['value']:.4g} → {entry['value']:.4g} {metric['unit']} ({ratio:+.0%})")
    if options.apply:
        with HISTORY.open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(f"Appended to {HISTORY.relative_to(ROOT)}.")
        redraw_card()
    else:
        print("Dry run: --apply appends it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    imported = commands.add_parser("import", help="check and compare a record made elsewhere; --apply appends it")
    imported.add_argument("record")
    imported.add_argument("--commit", help="the commit the record must name")
    imported.add_argument("--apply", action="store_true")
    add = commands.add_parser("append", help="append one run")
    add.add_argument("--bench")
    add.add_argument("--sweep")
    add.add_argument("--folders")
    add.add_argument("--e2e", help="the regression suite's metrics.json")
    add.add_argument("--source", default="harness", help="what measured the run: harness, or e2e for the suite")
    add.add_argument("--load-before", type=float, required=True)
    add.add_argument("--load-after", type=float, required=True)
    commands.add_parser("report", help="what changed in each metric's latest run")
    sizes = commands.add_parser("release", help="a release's download and installed size; --apply adds them")
    sizes.add_argument("tag", help="the release's tag, such as v0.2.6-prealpha")
    sizes.add_argument("--zip", help="the release's zip, when it isn't on GitHub yet")
    sizes.add_argument("--apply", action="store_true")
    options = parser.parse_args()

    metrics = registry()
    if options.command == "import":
        return import_record(options, metrics)
    if options.command == "release":
        return release(options, metrics)
    if options.command == "append":
        append(options, metrics)
    lines = report(records(), metrics)
    print("\n".join(["What changed:", *lines]) if lines else "No metric moved beyond its noise.")


if __name__ == "__main__":
    main()
