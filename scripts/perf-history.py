#!/usr/bin/env python3
"""Redlamp's performance history (docs/performance/history.jsonl): append a run, and say what changed.

One record per line, oldest first. A record has the date, the commit, the machine, the load average
before and after, whether that load made it noisy, where the numbers came from (`harness`, from
scripts/perf-record.sh; `readme`, from the README's tables through scripts/perf-backfill.py) and
its metrics by ID (docs/performance/metrics.json), each with a value and, where measured, the
slowest and fastest file and the runs' spread.

    scripts/perf-history.py append --bench b.json --sweep s.json --folders f.json --load-before 3.1 --load-after 3.4
    scripts/perf-history.py report     # what changed in the latest run of each metric
    scripts/perf-history.py import record.json --commit abc1234 [--apply]   # a kit's record (perf-kit.sh)

A metric got faster or slower when it moved by more than 10%, or by more than its runs' own spread
if that's larger, against the previous record from the same source on the same machine. Noisy
records are kept but never compared. web/lib/performance.ts applies the same rules for the site.
"""

import argparse
import datetime
import json
import pathlib
import subprocess
import sys

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
            lines.append(f"  {verdict.upper():6s} {metric['label']}: {earlier[-1]['metrics'][metric_id]['value']:.4g} → "
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
        print(f"  {verdict:6s} {metric['label']}: {old['value']:.4g} → {entry['value']:.4g} {metric['unit']} ({ratio:+.0%})")
    if options.apply:
        with HISTORY.open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(f"Appended to {HISTORY.relative_to(ROOT)}.")
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
    options = parser.parse_args()

    metrics = registry()
    if options.command == "import":
        return import_record(options, metrics)
    if options.command == "append":
        append(options, metrics)
    lines = report(records(), metrics)
    print("\n".join(["What changed:", *lines]) if lines else "No metric moved beyond its noise.")


if __name__ == "__main__":
    main()
