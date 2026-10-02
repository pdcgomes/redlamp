#!/usr/bin/env python3
"""Mirror the research tracker (docs/research/research-tracker.md) to GitHub issues.

The tracker is where the roadmap is planned; each of its work items has an issue, so the roadmap
can be followed, discussed and picked up on GitHub. The sync is one way for the row's fields: the
script owns a marked block in each issue's body, its own labels (tracker, area:, size:, kind:,
decision:, status:) and its milestone, and opens or closes the issue with the row's status.
Anything else on the issue (text outside the block, other labels, comments, assignees) is left
alone.

Each roadmap phase in the README (`### Phase N: Title *(status)*`) is a milestone of that title,
closed once the README marks the phase done; an issue goes in the milestone of its row's earliest
phase ("P2–P3" is Phase 2). Rows with no phase have no milestone.

Issues filed by other people come into the tracker by hand: give the item a tracker ID, then put
the ID at the start of the issue's title ("MSK-18: …") and the next sync adopts it, keeping the
reporter's text above the block. Open issues without an ID are listed as untriaged.

    scripts/tracker-issues.py                 # dry run: what would change
    scripts/tracker-issues.py --apply         # make the changes
    scripts/tracker-issues.py --only MSK-07,MSK-15

Decision rows (DEC-) and recorded skips (SKIP-) stay in the tracker only, unless asked for: the
decisions are questions for counsel and the owner, not work to pick up. Rows already done when
they first sync get no issue, unless --include-done.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
TRACKER = ROOT / "docs/research/research-tracker.md"
README = ROOT / "README.md"
REPO = "pdcgomes/redlamp"
BLOB = f"https://github.com/{REPO}/blob/main/"
BEGIN, END = "<!-- tracker:begin -->", "<!-- tracker:end -->"
ID = re.compile(r"^([A-Z]{2,4}|P1)-\d+$")

AREAS = {
    "P1": "phase-1", "CAM": "cameras", "TON": "color-tone-detail", "MSK": "masks",
    "EDT": "edits-interop-export", "LNS": "lenses-geometry", "ARC": "architecture", "UX": "ux",
    "EXT": "extensibility", "DN": "ai-denoise", "FS": "focus-stacking", "RM": "removal-healing",
    "SR": "super-resolution", "SHP": "sharpening", "AUT": "auto", "OTH": "other-ai",
    "INF": "ai-infrastructure", "DEC": "decisions", "SKIP": "skipped",
}
COLOURS = {"tracker": "5319e7", "area": "0e8a16", "size": "c5def5", "kind": "bfd4f2", "decision": "fbca04",
           "status": "d93f0b"}
# `phase:` labels were how phases were shown before milestones: removed where found.
MANAGED = ("tracker", "area:", "phase:", "size:", "kind:", "decision:", "status:")


# MARK: - The tracker


def rows():
    """Every row of every table, with its section and its cells by column name."""
    header, section, out = None, "", []
    for number, line in enumerate(TRACKER.read_text().splitlines(), 1):
        if line.startswith("## "):
            section = line[3:].strip()
        if not line.startswith("|"):
            header = None if not line.strip() else header
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells[0] == "ID":
            header = cells
        elif header and ID.match(cells[0]):
            out.append({"id": cells[0], "section": section, "line": number, **dict(zip(header, cells))})
    return out


def plain(markdown):
    """Markdown links as their text, bold and italics as plain."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", markdown).replace("**", "")
    return re.sub(r"\*([^*]+)\*", r"\1", text)


def absolute(markdown):
    """Relative links (from docs/research/) as links into the repository on GitHub."""
    def link(match):
        text, target = match.group(1), match.group(2)
        if re.match(r"^[a-z]+:|^#", target):
            return match.group(0)
        path, _, anchor = target.partition("#")
        resolved = (TRACKER.parent / path).resolve().relative_to(ROOT)
        return f"[{text}]({BLOB}{resolved}{'#' + anchor if anchor else ''})"
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, markdown)


def labels(row):
    prefix = row["id"].split("-")[0]
    out = {"tracker", f"area:{AREAS.get(prefix, prefix.lower())}"}
    size = row.get("Size", "")
    letters = re.findall(r"\b(XL|S|M|L)\b", size.split("(")[0])
    # Engineer-weeks, the larger of a range: "2–3 ew", "6–8 ew + US$5–20k".
    weeks = [float(n) for n in re.findall(r"\d+(?:\.\d+)?", size.split("ew")[0])] if "ew" in size else []
    if letters:
        out.add(f"size:{max(letters, key=['S', 'M', 'L', 'XL'].index)}")
    elif weeks:
        top = max(weeks)
        out.add("size:" + ("S" if top <= 1 else "M" if top <= 3 else "L" if top <= 6 else "XL"))
    recommended = row.get("Recommended", "").lower()
    for word, kind in (("do better", "do-better"), ("better", "do-better"), ("adopt", "adopt"), ("build", "build")):
        if recommended.startswith(word):
            out.add(f"kind:{kind}")
            break
    if decision := re.match(r"(Proposed|Accepted|Rejected|Deferred)", row.get("Decision", "")):
        out.add(f"decision:{decision.group(1).lower()}")
    status = status_of(row)
    if status in ("in progress", "blocked"):
        out.add(f"status:{status.replace(' ', '-')}")
    return out


def phase_of(row):
    """The row's earliest roadmap phase, or None."""
    if row["id"].startswith("P1-"):
        return 1
    phase = row.get("Phase", "")
    if found := re.search(r"P(\d)", phase):
        return int(found.group(1))
    return 1 if phase.startswith("Now") else None


def phases():
    """The README's roadmap phases: number to (title, done)."""
    out = {}
    for line in README.read_text().splitlines():
        if found := re.match(r"^### (Phase (\d+): .+?)(?: \*\((.+)\)\*)?$", line):
            out[int(found.group(2))] = (found.group(1).strip(), (found.group(3) or "").strip() == "done")
    return out


def milestone_of(row, roadmap):
    phase = phase_of(row)
    return roadmap[phase][0] if phase in roadmap else None


def status_of(row):
    text = row.get("Status", "").lower()
    for status in ("done", "in progress", "blocked", "not needed", "not started"):
        if text.startswith(status):
            return status
    return "not started"


def closed(row):
    return status_of(row) in ("done", "not needed") or row.get("Decision", "").startswith("Rejected")


def title(row):
    item = plain(row.get("Item") or row.get("Question") or row.get("Skip") or "")
    text = f"{row['id']}: {item}"
    return text if len(text) <= 120 else text[:119].rstrip() + "…"


def block(row, numbers):
    """The issue body's mirrored block; dependencies link to their issues."""
    def dependency(match):
        number = numbers.get(match.group(0))
        return f"{match.group(0)} (#{number})" if number else match.group(0)
    depends = re.sub(r"\b(?:[A-Z]{2,4}|P1)-\d+\b", dependency, row.get("Depends on", "—"))
    fields = [(name, row.get(name, "")) for name in ("Recommended", "Phase", "Size") if row.get(name)]
    fields += [("Depends on", depends), ("Decision", row.get("Decision", "")), ("Status", row.get("Status", ""))]
    anchor = re.sub(r"[^a-z0-9 -]", "", row["section"].lower()).replace(" ", "-")
    lines = [
        BEGIN,
        absolute(row.get("Item") or row.get("Question") or row.get("Skip") or ""),
        "",
        "| | |",
        "| --- | --- |",
        *(f"| **{name}** | {absolute(value) or '—'} |" for name, value in fields),
        f"| **Source** | {absolute(row.get('Source', '—'))} |",
        "",
        f"Mirrored from row `{row['id']}` of the [research tracker]({BLOB}docs/research/research-tracker.md#{anchor})"
        " by `scripts/tracker-issues.py`: change the row there, not this block. Discussion here is welcome.",
        f"<!-- tracker-id: {row['id']} -->",
        END,
    ]
    return "\n".join(lines)


# MARK: - GitHub


def gh(*args, input=None):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, input=input)
    if result.returncode != 0:
        sys.exit(f"gh {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout


def issues():
    found = json.loads(gh("issue", "list", "--state", "all", "--limit", "2000",
                          "--json", "number,title,body,state,labels,milestone"))
    by_id, untriaged = {}, []
    for issue in found:
        marker = re.search(r"<!-- tracker-id: (\S+) -->", issue["body"] or "")
        titled = re.match(r"^\[?((?:[A-Z]{2,4}|P1)-\d+)\]?[:\s]", issue["title"])
        tracker_id = marker.group(1) if marker else titled.group(1) if titled else None
        if tracker_id:
            by_id[tracker_id] = issue
        elif issue["state"] == "OPEN" and not any(label["name"] == "tracker" for label in issue["labels"]):
            untriaged.append(issue)
    return by_id, untriaged


def merged_body(existing, mirrored):
    """The reporter's own text kept, the mirrored block replaced (or added below it)."""
    existing = existing or ""
    if BEGIN in existing and END in existing:
        before, rest = existing.split(BEGIN, 1)
        after = rest.split(END, 1)[1]
        return before + mirrored + after
    return (existing.rstrip() + "\n\n---\n\n" if existing.strip() else "") + mirrored


def milestones():
    """Milestones by phase number (from their "Phase N:" titles)."""
    found = json.loads(gh("api", f"repos/{REPO}/milestones?state=all&per_page=100"))
    return {int(m.group(1)): milestone for milestone in found
            if (m := re.match(r"^Phase (\d+):", milestone["title"]))}


def current_milestone(issue):
    return (issue.get("milestone") or {}).get("title")


def set_milestone(number, milestone, present):
    """By the milestone's number: gh's --milestone finds only open milestones by title, and a done
    phase's milestone is closed."""
    phase = int(re.match(r"^Phase (\d+):", milestone).group(1)) if milestone else None
    value = str(present[phase]["number"]) if phase is not None else "null"
    gh("api", "-X", "PATCH", f"repos/{REPO}/issues/{number}", "-F", f"milestone={value}")


# MARK: - Sync


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="make the changes (default: a dry run)")
    parser.add_argument("--only", help="comma-separated tracker IDs")
    parser.add_argument("--include-done", action="store_true", help="create closed issues for rows already done")
    parser.add_argument("--include-decisions", action="store_true", help="mirror DEC- rows too")
    parser.add_argument("--include-skips", action="store_true", help="mirror SKIP- rows too")
    options = parser.parse_args()

    only = set(options.only.split(",")) if options.only else None
    wanted = [row for row in rows()
              if (only is None or row["id"] in only)
              and (options.include_decisions or not row["id"].startswith("DEC-"))
              and (options.include_skips or not row["id"].startswith("SKIP-"))]
    existing, untriaged = issues()
    roadmap = phases()
    present = milestones()
    milestone_changes = [(number, title_, done) for number, (title_, done) in sorted(roadmap.items())
                         if number not in present or present[number]["title"] != title_
                         or (present[number]["state"] == "closed") != done]

    plan = {"create": [], "update": [], "close": [], "reopen": [], "unchanged": 0, "skipped done": 0}
    for row in wanted:
        issue = existing.get(row["id"])
        if issue is None:
            if closed(row) and not options.include_done:
                plan["skipped done"] += 1
            else:
                plan["create"].append(row)
            continue
        current = {label["name"] for label in issue["labels"]}
        managed = {name for name in current if name.startswith(MANAGED)}
        numbers = {key: value["number"] for key, value in existing.items()}
        if (issue["title"] != title(row) or managed != labels(row)
                or current_milestone(issue) != milestone_of(row, roadmap)
                or merged_body(issue["body"], block(row, numbers)) != issue["body"]):
            plan["update"].append(row)
        else:
            plan["unchanged"] += 1
        if closed(row) and issue["state"] == "OPEN":
            plan["close"].append(row)
        elif not closed(row) and issue["state"] == "CLOSED":
            plan["reopen"].append(row)

    for number, title_, done in milestone_changes:
        verb = "create" if number not in present else "update"
        print(f"{verb:7s} milestone {title_}{' (closed: done)' if done else ''}")
    for action in ("create", "update", "close", "reopen"):
        for row in plan[action]:
            print(f"{action:7s} {title(row)}")
    print(f"\n{len(plan['create'])} to create, {len(plan['update'])} to update, {len(plan['close'])} to close, "
          f"{len(plan['reopen'])} to reopen, {plan['unchanged']} unchanged, "
          f"{plan['skipped done']} done rows without an issue left alone")
    if untriaged:
        print("\nUntriaged open issues (give them a tracker ID, or close them):")
        for issue in untriaged:
            print(f"  #{issue['number']} {issue['title']}")
    if not options.apply:
        print("\nDry run: nothing changed. Run with --apply to sync.")
        return

    for number, title_, done in milestone_changes:
        fields = ["-f", f"title={title_}", "-f", f"state={'closed' if done else 'open'}",
                  "-f", f"description=The README's roadmap: {BLOB}README.md#roadmap"]
        if number in present:
            gh("api", "-X", "PATCH", f"repos/{REPO}/milestones/{present[number]['number']}", *fields)
        else:
            gh("api", "-X", "POST", f"repos/{REPO}/milestones", *fields)
    present = milestones()
    every = set().union(*(labels(row) for row in wanted)) if wanted else set()
    for name in sorted(every):
        colour = COLOURS[name.split(":")[0]] if ":" in name else COLOURS["tracker"]
        gh("label", "create", name, "--color", colour, "--force")
    # Created first, so every dependency can link to its issue.
    for row in plan["create"]:
        milestone = milestone_of(row, roadmap)
        url = gh("issue", "create", "--title", title(row), "--body", block(row, {}),
                 *[arg for name in sorted(labels(row)) for arg in ("--label", name)]).strip()
        if milestone:
            set_milestone(int(url.rsplit("/", 1)[1]), milestone, present)
        existing[row["id"]] = {"number": int(url.rsplit("/", 1)[1]), "title": title(row), "body": block(row, {}),
                               "state": "OPEN", "labels": [{"name": name} for name in labels(row)],
                               "milestone": {"title": milestone} if milestone else None}
        print(f"created {url}")
        time.sleep(1)  # GitHub's secondary rate limit on creating content
    numbers = {key: value["number"] for key, value in existing.items()}
    for row in wanted:
        issue = existing.get(row["id"])
        if issue is None:
            continue
        body = merged_body(issue["body"], block(row, numbers))
        current = {label["name"] for label in issue["labels"]}
        managed = {name for name in current if name.startswith(MANAGED)}
        add, remove = labels(row) - managed, managed - labels(row)
        milestone = milestone_of(row, roadmap)
        moves = current_milestone(issue) != milestone
        if issue["title"] != title(row) or body != issue["body"] or add or remove or moves:
            args = ["issue", "edit", str(issue["number"]), "--title", title(row), "--body-file", "-"]
            args += [arg for name in sorted(add) for arg in ("--add-label", name)]
            args += [arg for name in sorted(remove) for arg in ("--remove-label", name)]
            gh(*args, input=body)
            if moves:
                set_milestone(issue["number"], milestone, present)
        if closed(row) and issue["state"] == "OPEN":
            reason = "not planned" if status_of(row) == "not needed" or row.get("Decision", "").startswith("Rejected") \
                else "completed"
            gh("issue", "close", str(issue["number"]), "--reason", reason)
        elif not closed(row) and issue["state"] == "CLOSED":
            gh("issue", "reopen", str(issue["number"]))
    print("Synced.")


if __name__ == "__main__":
    main()
