#!/usr/bin/env python3
"""Seed docs/performance/history.jsonl with the figures past READMEs recorded.

Walks every version of README.md in git history, reads its "Measured performance" section as
docs/performance/metrics.json describes, and writes a `source: "readme"` record wherever a figure
changed, dated by its commit. In a table whose columns are stages (the slider sweep's), the last
column is the figure current at that commit; the earlier columns, and figures a cell quotes from
"before" a change, count once, dated just before the commit that first showed them. A table the
README says was measured under load (a load average above 8) is recorded as noisy.

    scripts/perf-backfill.py            # dry run: the records it would write
    scripts/perf-backfill.py --apply    # replace the README records in the history, keeping the harness's

The README's figures are approximate ("~13 ms") or ranges ("0.6–3 ms", kept as low and high around
their midpoint); the page labels them as recorded in the README.
"""

import argparse
import datetime
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
HISTORY = ROOT / "docs/performance/history.jsonl"
METRICS = ROOT / "docs/performance/metrics.json"
NOISY_LOAD = 8.0
NUMBER = r"~?\s*([\d,]*\.?\d+)"
VALUE = re.compile(NUMBER + r"(?:\s*[–-]\s*([\d,]*\.?\d+))?\s*(ms|s|MB|GB|%|a second)?")
TO_UNIT = {("s", "ms"): 1000, ("ms", "s"): 0.001, ("GB", "MB"): 1024, ("MB", "GB"): 1 / 1024}


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def section(readme):
    match = re.search(r"^##+ Measured performance\n(.*?)(?=^##+ (?!#))", readme, re.S | re.M)
    return match.group(1) if match else ""


def tables(text):
    """Each table under its preceding paragraph: (paragraph, header cells, rows of cells)."""
    out, paragraph, header, rows = [], "", None, []
    for line in text.splitlines() + [""]:
        if line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if header is None:
                header = cells
            elif not set("".join(cells)) <= set("-: "):
                rows.append(cells)
            continue
        if header is not None:
            out.append((paragraph, header, rows))
            header, rows = None, []
        if line.strip():
            paragraph = line
    return out


def parse(cell, unit):
    """(value, low, high) in `unit`, or None for a dash or no number."""
    found = VALUE.search(cell)
    if not found or cell.strip() in ("—", "-"):
        return None
    low = float(found.group(1).replace(",", ""))
    high = float(found.group(2).replace(",", "")) if found.group(2) else low
    factor = TO_UNIT.get((found.group(3), unit), 1)
    low, high = low * factor, high * factor
    return (low + high) / 2, low, high


def entry(parsed):
    value, low, high = parsed
    out = {"value": round(value, 4)}
    if low != high:
        out.update(low=round(low, 4), high=round(high, 4))
    return out


def read(readme, metrics):
    """{table key: (noisy, {metric: entry}), "before": {metric: entry}, "earlier": {metric: entry}}."""
    text = section(readme)
    found = {"before": {}, "earlier": {}}

    def put(key, noisy, metric_id, value):
        found.setdefault(key, (noisy, {}))[1][metric_id] = value

    for paragraph, header, rows in tables(text):
        load = re.search(r"load average about (\d+(?:\.\d+)?)", paragraph)
        noisy = bool(load and float(load.group(1)) > NOISY_LOAD)
        key = f"{header[0]}: {paragraph}"
        for metric in metrics:
            spec = metric.get("readme", {})
            prefix = spec.get("row")
            if not prefix:
                continue
            for cells in rows:
                if not cells[0].startswith(prefix):
                    continue
                if spec.get("columns"):
                    current = parse(cells[-1], metric["unit"])
                    if current:
                        put(key, noisy, metric["id"], entry(current))
                    for cell in cells[1:-1]:
                        earlier = parse(cell, metric["unit"])
                        if earlier:
                            found["earlier"].setdefault(metric["id"], []).append(entry(earlier))
                    break
                cell = cells[1]
                before = re.search(r"\(" + NUMBER + r"\s*(ms|s|MB|GB)? before", cell)
                if before:
                    found["before"][metric["id"]] = entry(parse(before.group(0)[1:], metric["unit"]))
                    cell = cell[:before.start()]
                parts = re.split(r",\s+(?=~|\d)", cell)
                index = 0
                if spec.get("phrase"):
                    # The label lists what each value is ("…, GPU time: a; b; c"), in the cell's order.
                    listed = cells[0].split("GPU time:", 1)[-1]
                    names = [name.strip() for name in re.split(r";" if ";" in listed else r",", listed)]
                    matches = [i for i, name in enumerate(names) if name.startswith(spec["phrase"])]
                    if not matches or len(names) != len(parts):
                        break
                    index = matches[0]
                if index < len(parts) and (current := parse(parts[index], metric["unit"])):
                    put(key, noisy, metric["id"], entry(current))
                break
    for metric in metrics:
        spec = metric.get("readme", {})
        if spec.get("pattern") and (match := re.search(spec["pattern"], text)):
            put("prose", False, metric["id"], entry(parse(match.group(1) + " " + metric["unit"], metric["unit"])))
        if spec.get("before") and (match := re.search(spec["before"], text)):
            found["before"][metric["id"]] = entry(parse(match.group(1) + " " + metric["unit"], metric["unit"]))
    return found


def build(metrics):
    versions = git("log", "--reverse", "--format=%H %aI", "--", "README.md").split("\n")
    latest, seen_before, seen_tables, records = {}, set(), set(), []
    for line in filter(None, versions):
        commit, date = line.split(" ", 1)
        found = read(git("show", f"{commit}:README.md"), metrics)
        short = commit[:7]
        moment = datetime.datetime.fromisoformat(date)
        earlier_moment = (moment - datetime.timedelta(minutes=1)).isoformat()
        parent = git("rev-parse", "--short", f"{commit}^").strip() if found["before"] or found["earlier"] else short
        # Stages and "before" figures first shown here are dated just before this commit.
        before_metrics = {}
        new_tables = {key for key in found if key not in ("before", "earlier") and key not in seen_tables}
        if new_tables:
            # A stage table's earlier columns only where the table first appears.
            for metric_id, values in found["earlier"].items():
                if metric_id not in latest and values and any(metric_id in found[key][1] for key in new_tables):
                    before_metrics[metric_id] = values[0]
        seen_tables.update(new_tables)
        for metric_id, value in found["before"].items():
            if (metric_id, value["value"]) not in seen_before:
                seen_before.add((metric_id, value["value"]))
                if latest.get(metric_id) != value:
                    before_metrics[metric_id] = value
        if before_metrics:
            records.append(record(earlier_moment, parent, False, before_metrics, "Figure the README quotes from before this change"))
            for metric_id, value in before_metrics.items():
                latest.setdefault(metric_id, value)
        for key, value in found.items():
            if key in ("before", "earlier"):
                continue
            noisy, entries = value
            changed = {metric_id: e for metric_id, e in entries.items() if latest.get(metric_id) != e}
            if changed:
                records.append(record(date, short, noisy, changed, None))
                latest.update(changed)
    return records


def record(date, commit, noisy, metrics, note):
    out = {
        "date": date,
        "commit": commit,
        "subject": git("log", "-1", "--format=%s", commit).strip(),
        "source": "readme",
        "machine": {"chip": "Apple M1 Ultra"},
        "noisy": noisy,
        "metrics": dict(sorted(metrics.items())),
    }
    if noisy:
        out["load"] = {"before": None, "after": None, "note": "the README says the Mac was busy (load average above 8)"}
    if note:
        out["note"] = note
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="write the README records into the history")
    options = parser.parse_args()
    metrics = json.loads(METRICS.read_text())["metrics"]
    records = build(metrics)
    if not options.apply:
        for item in records:
            values = ", ".join(f"{key} {value['value']:g}" for key, value in item["metrics"].items())
            print(f"{item['date'][:10]} {item['commit']}{' noisy' if item['noisy'] else ''}: {values}")
        print(f"\n{len(records)} README records. Run with --apply to write them.")
        return
    kept = []
    if HISTORY.exists():
        kept = [json.loads(line) for line in HISTORY.read_text().splitlines() if line.strip()]
        kept = [item for item in kept if item.get("source") != "readme"]
    combined = sorted(records + kept, key=lambda item: datetime.datetime.fromisoformat(item["date"]))
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    HISTORY.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in combined))
    print(f"Wrote {len(records)} README records and kept {len(kept)} harness records in {HISTORY.relative_to(ROOT)}.")


if __name__ == "__main__":
    main()
