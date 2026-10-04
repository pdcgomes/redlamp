#!/usr/bin/env python3
"""Keep the README roadmap and the Lightroom comparison in step with the research tracker.

The tracker (docs/research/research-tracker.md) says where each piece of work stands. The README
roadmap names the tracker rows behind each item in a trailing comment (`<!-- tracker: TON-06 -->`,
or `<!-- internal -->` for engineering work), and each row of the Lightroom comparison
(docs/lightroom-comparison.md) lists its rows in the Tracker column. This script carries the
tracker's statuses into both, and stops where a person has to decide:

  - a Planned comparison row becomes In progress once one of its tracker rows starts, and Done
    once they have all finished; In progress becomes Done the same way
  - a Planned or In progress row's Phase follows the README roadmap item naming the same rows
  - a README item is ticked when all its rows have finished, and unticked if one reopens

    scripts/roadmap-sync.py            # dry run: what's out of step, and what --apply would change
    scripts/roadmap-sync.py --apply    # make the changes the tracker decides
    scripts/roadmap-sync.py --check    # quiet unless something is out of step (hooks and CI)

It exits with 1 while anything is out of step, so the pre-commit hook, `mise run lint`, CI and
`tracker-issues.py --apply` stop until it's fixed.
"""

import argparse
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMPARISON = ROOT / "docs/lightroom-comparison.md"

spec = importlib.util.spec_from_file_location("tracker_issues", ROOT / "scripts/tracker-issues.py")
tracker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tracker)

ID = re.compile(r"\b(?:[A-Z]{2,4}|P1)-\d+\b")
LIGHTROOM = re.compile(r"^(Yes|Partly|No)\b")
STATUSES = ("Done", "In progress", "Planned", "Later", "Out of scope")
VERSUS = ("", "Compared", "Behind", "Beyond", "Different")
COLUMNS = ["Feature", "Lightroom", "Redlamp", "vs Lightroom", "Phase", "Tracker", "Notes"]
STARTED = ("done", "in progress")
FINISHED = ("done", "not needed")


def relative(path):
    return path.relative_to(ROOT)


# MARK: - Reading


def comparison_rows(lines):
    """Every row of the comparison's tables, with its group and line number."""
    group, header, out = "", None, []
    for index, line in enumerate(lines):
        if line.startswith("## "):
            group = line[3:].strip()
        if not line.startswith("|"):
            header = None
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells[0] == "Feature":
            header = cells
        elif header and not set(cells[0]) <= set("-: "):
            out.append({"index": index, "group": group, "header": header, "cells": dict(zip(header, cells))})
    return out


def roadmap_items(lines):
    """The README roadmap's items: their phase (a number, or "Later"), box and tags."""
    phase, inside, out = None, False, []
    for index, line in enumerate(lines):
        if line.startswith("## "):
            inside = line.startswith("## Roadmap")
            continue
        if not inside:
            continue
        if line.startswith("### "):
            found = re.match(r"^### Phase (\d+):", line)
            phase = int(found.group(1)) if found else ("Later" if line.startswith("### Later") else None)
            continue
        item = re.match(r"^- (?:\[( |x)\] )?(.*)$", line)
        if phase is None or not item:
            continue
        comment = re.search(r"<!--(.*?)-->", item.group(2))
        tag = comment.group(1) if comment else ""
        out.append({
            "index": index, "phase": phase, "ticked": None if item.group(1) is None else item.group(1) == "x",
            "ids": ID.findall(tag), "internal": "internal" in tag,
            "text": re.sub(r"\s*<!--.*?-->", "", item.group(2)).strip(),
        })
    return out


def phase_headings(lines):
    """Roadmap phases marked done, by number, with the heading's line."""
    out = {}
    for index, line in enumerate(lines):
        if found := re.match(r"^### Phase (\d+): .+?(?: \*\((.+)\)\*)?$", line):
            out[int(found.group(1))] = (index, (found.group(2) or "").strip() == "done")
    return out


# MARK: - Checking


class Report:
    def __init__(self):
        self.errors, self.warnings, self.changes = [], [], []

    def error(self, path, index, message):
        self.errors.append(f"{relative(path)}:{index + 1}: {message}")

    def warn(self, path, index, message):
        self.warnings.append(f"{relative(path)}:{index + 1}: {message}")

    def change(self, path, index, message):
        self.changes.append(f"{relative(path)}:{index + 1}: {message}")


def statuses(ids, rows):
    return {i: tracker.status_of(rows[i]) for i in ids if i in rows}


def check_comparison(lines, items, rows, phases, report):
    """Validates the comparison and returns its rows with the changes --apply would make."""
    by_id = {}
    for item in items:
        for i in item["ids"]:
            if isinstance(item["phase"], int):
                by_id.setdefault(i, []).append(item["phase"])
    edits = {}
    for row in comparison_rows(lines):
        index, cells = row["index"], row["cells"]
        name = cells.get("Feature", "")
        if row["header"] != COLUMNS:
            report.error(COMPARISON, index, f"the table's columns must be {', '.join(COLUMNS)}")
            continue
        status, versus, phase = cells["Redlamp"], cells["vs Lightroom"], cells["Phase"]
        if not LIGHTROOM.match(cells["Lightroom"]):
            report.error(COMPARISON, index, f"{name}: Lightroom must start with Yes, Partly or No")
        if status not in STATUSES:
            report.error(COMPARISON, index, f"{name}: Redlamp must be one of {', '.join(STATUSES)}")
            continue
        if versus not in VERSUS:
            report.error(COMPARISON, index, f"{name}: vs Lightroom must be blank or one of {', '.join(VERSUS[1:])}")
        elif versus and status != "Done":
            report.error(COMPARISON, index, f"{name}: vs Lightroom is only for Done rows")
        if phase and not (re.fullmatch(r"P(\d)", phase) and int(phase[1]) in phases):
            report.error(COMPARISON, index, f"{name}: Phase must name a README roadmap phase (P0 to P{max(phases)})")
        if status == "Planned" and not phase:
            report.error(COMPARISON, index, f"{name}: a Planned row needs its Phase")
        if phase and status not in ("Planned", "In progress"):
            report.error(COMPARISON, index, f"{name}: only Planned and In progress rows have a Phase")
        ids = [part.strip() for part in cells["Tracker"].split(",") if part.strip()]
        for i in ids:
            if not ID.fullmatch(i) or i not in rows:
                report.error(COMPARISON, index, f"{name}: {i} isn't a row of the tracker")
        known = statuses(ids, rows)
        started = [i for i, s in known.items() if s in STARTED]
        finished = known and all(s in FINISHED for s in known.values()) and "done" in known.values()
        new_status, new_phase = status, phase
        if status == "Planned" and started:
            new_status = "Done" if finished else "In progress"
        elif status == "In progress" and finished:
            new_status = "Done"
        elif status == "In progress" and known and not started:
            report.warn(COMPARISON, index, f"{name}: In progress, but none of {', '.join(ids)} has started")
        elif status == "Done" and known and not started and versus != "Behind":
            report.error(COMPARISON, index,
                         f"{name}: Done, but none of {', '.join(ids)} has started; list the rows it was built "
                         "under, or mark it Behind if they are the work that closes a gap")
        elif status in ("Later", "Out of scope") and started:
            report.error(COMPARISON, index,
                         f"{name}: {status}, but {', '.join(started)} has started; is it Planned, In progress or Done?")
        if status == "Planned" and not ids:
            report.warn(COMPARISON, index, f"{name}: Planned without a tracker row, so there's no issue to follow")
        if new_status in ("Planned", "In progress"):
            followed = sorted({p for i in ids for p in by_id.get(i, [])})
            if followed and new_phase != f"P{followed[0]}":
                new_phase = f"P{followed[0]}"
        else:
            new_phase = ""
        if (new_status, new_phase) != (status, phase):
            why = ", ".join(f"{i} {known[i]}" for i in ids if i in known)
            report.change(COMPARISON, index, f"{name}: {status} {phase or ''}".rstrip()
                          + f" becomes {new_status} {new_phase or ''}".rstrip() + f" ({why})")
            edits[index] = {**cells, "Redlamp": new_status, "Phase": new_phase}
    return edits


def check_roadmap(lines, items, compared, rows, report):
    """Validates the README roadmap and returns the boxes --apply would change."""
    edits = {}
    for item in items:
        index, ids, text = item["index"], item["ids"], item["text"][:70]
        for i in ids:
            if i not in rows:
                report.error(tracker.README, index, f"{i} isn't a row of the tracker")
        if item["ticked"] is None:
            continue
        known = statuses(ids, rows)
        finished = known and all(s in FINISHED for s in known.values()) and "done" in known.values()
        if item["ticked"] and known and not all(s in FINISHED for s in known.values()):
            open_rows = ", ".join(i for i, s in known.items() if s not in FINISHED)
            report.change(tracker.README, index, f"untick \"{text}\" ({open_rows} not finished)")
            edits[index] = " "
        elif not item["ticked"] and finished:
            report.change(tracker.README, index, f"tick \"{text}\" ({', '.join(ids)} finished)")
            edits[index] = "x"
        if not item["ticked"] and not item["internal"]:
            if not ids:
                report.warn(tracker.README, index, f"\"{text}\" names no tracker row")
            elif not compared & set(ids):
                report.error(tracker.README, index,
                             f"\"{text}\": no row of the Lightroom comparison lists {', '.join(ids)}; add or extend a "
                             "row, or mark the item <!-- internal -->")
    for number, (index, done) in phase_headings(lines).items():
        open_items = [item for item in items if item["phase"] == number and item["ticked"] is False]
        if done and open_items:
            report.error(tracker.README, index, f"Phase {number} is marked done with {len(open_items)} items open")
    return edits


# MARK: - Writing


def row_line(header, cells):
    return "|" + "|".join(f" {cells[name]} " if cells[name] else " " for name in header) + "|"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="make the changes the tracker decides")
    parser.add_argument("--check", action="store_true", help="print only what's out of step")
    options = parser.parse_args()

    rows = {row["id"]: row for row in tracker.rows()}
    tracker.ROWS.update(rows)
    phases = tracker.phases()
    readme_lines = tracker.README.read_text().split("\n")
    comparison_lines = COMPARISON.read_text().split("\n")
    items = roadmap_items(readme_lines)
    report = Report()
    comparison_edits = check_comparison(comparison_lines, items, rows, phases, report)
    compared = {i.strip() for row in comparison_rows(comparison_lines)
                for i in row["cells"].get("Tracker", "").split(",") if i.strip()}
    roadmap_edits = check_roadmap(readme_lines, items, compared, rows, report)

    for line in report.errors:
        print(f"error   {line}")
    for line in report.changes:
        print(f"{'changed' if options.apply else 'change'} {line}")
    if not options.check:
        for line in report.warnings:
            print(f"warning {line}")

    if options.apply:
        header = {row["index"]: row["header"] for row in comparison_rows(comparison_lines)}
        for index, cells in comparison_edits.items():
            comparison_lines[index] = row_line(header[index], cells)
        for index, box in roadmap_edits.items():
            readme_lines[index] = re.sub(r"^- \[[ x]\] ", f"- [{box}] ", readme_lines[index])
        if comparison_edits:
            COMPARISON.write_text("\n".join(comparison_lines))
        if roadmap_edits:
            tracker.README.write_text("\n".join(readme_lines))
        pending = report.errors
    else:
        pending = report.errors + report.changes

    if not options.check:
        print(f"\n{len(report.errors)} to decide, {len(report.changes)} "
              f"{'changed' if options.apply else 'for --apply'}, {len(report.warnings)} warnings")
    if pending and not options.apply and report.changes and not options.check:
        print("Run with --apply to make the changes the tracker decides.")
    sys.exit(1 if pending else 0)


if __name__ == "__main__":
    main()
