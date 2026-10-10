#!/usr/bin/env python3
"""Where the next release stands, for the release room (.cursor/skills/redlamp-release/SKILL.md).

    scripts/release-status.py           # a report to read
    scripts/release-status.py --json    # the same, for the release room canvas

It reads, without changing anything:

  - the latest release (GitHub's release marked Latest, or the newest v* tag) and the upcoming
    one, by the rule `mise run release` follows: Version.xcconfig's MARKETING_VERSION on
    origin/main, or its next patch if that version has been released
  - the commits on origin/main since the latest release, grouped by the tracker rows they name
  - those rows' statuses: a row still In progress or Blocked ships part of a feature
  - every tracker row In progress or Blocked, and the README's Known limitations
  - the What's New highlights on origin/main for the upcoming version (web/content/whats-new)
  - branches with commits that aren't on origin/main, which this release leaves out
  - open bug reports and in-app reports, and CI's latest run on main
  - how far LibRaw's master has moved past the commit Redlamp pins from its fork (CAM-30), and the
    fork's open upstream-sync pull request, if any

GitHub is asked through `gh`; when it can't be reached, those parts say so and the rest stands.
"""

import argparse
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tracker_issues", ROOT / "scripts/tracker-issues.py")
tracker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tracker)

MAIN = "origin/main"
TRACKER_ID = re.compile(r"\b(?:[A-Z]{2,4}|P1)-\d{2,3}\b")
ISSUE = re.compile(r"#(\d+)\b")
# Commits that aren't changes to the app: the cask, the version bump.
HOUSEKEEPING = re.compile(r"^(Cask: |Version \d)")


def git(*args, check=True):
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def gh(*args):
    """`gh`'s JSON, or None when GitHub can't be reached."""
    try:
        result = subprocess.run(["gh", *args], cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        return None


def parse_version(text):
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$", text)
    return (int(match[1]), int(match[2]), int(match[3]), match[4] or "") if match else None


def released(version):
    return bool(git("tag", "--list", f"v{version}")) or bool(
        git("ls-remote", "--tags", "origin", f"refs/tags/v{version}", check=False)
    )


def latest_release():
    release = gh("release", "view", "--json", "tagName,publishedAt,url,name")
    if release:
        return {"tag": release["tagName"], "version": release["tagName"].removeprefix("v"),
                "date": release["publishedAt"][:10], "url": release["url"], "source": "GitHub"}
    tag = git("describe", "--tags", "--abbrev=0", "--match", "v*", MAIN, check=False)
    if not tag:
        return None
    date = git("log", "-1", "--format=%cs", tag)
    return {"tag": tag, "version": tag.removeprefix("v"), "date": date, "url": None, "source": "tags (GitHub not reached)"}


def upcoming_release(latest):
    xcconfig = git("show", f"{MAIN}:Version.xcconfig")
    version = re.search(r"^MARKETING_VERSION *= *(\S+)", xcconfig, re.M)[1]
    bumped = False
    if released(version):
        parts = parse_version(version)
        if parts:
            version = f"{parts[0]}.{parts[1]}.{parts[2] + 1}{parts[3]}"
            bumped = True
    build = int(git("rev-list", "--count", MAIN)) + (1 if bumped else 0)
    return {"version": version, "bumpsPatch": bumped, "build": build,
            "rule": "the next patch, as `mise run release` bumps it" if bumped else "Version.xcconfig as set"}


def changes(latest):
    log = git("log", "--no-merges", "--format=%h%x09%s", f"{latest['tag']}..{MAIN}")
    commits = []
    for line in filter(None, log.splitlines()):
        sha, subject = line.split("\t", 1)
        if HOUSEKEEPING.match(subject):
            continue
        commits.append({"sha": sha, "subject": subject, "rows": sorted(set(TRACKER_ID.findall(subject))),
                        "issues": sorted(set(ISSUE.findall(subject)), key=int)})
    return commits


def tracker_rows():
    return {row["id"]: row for row in tracker.rows()}


def status_word(row):
    status = row.get("Status", "")
    for word in ("Done", "In progress", "Blocked", "Not started", "Not needed", "Rejected"):
        if status.startswith(word):
            return word
    return status.split(":")[0][:30] or "?"


def item_title(row, length=90):
    text = tracker.plain(row.get("Item", ""))
    return text if len(text) <= length else text[: length - 1].rstrip() + "…"


def known_limitations():
    readme = (ROOT / "README.md").read_text()
    section = re.search(r"^### Known limitations\n(.*?)(?=^\*\*|^### |^## )", readme, re.M | re.S)
    if not section:
        return []
    return [tracker.plain(line[2:]).strip() for line in section[1].splitlines() if line.startswith("- ")]


def whats_new(version):
    """The highlights on origin/main, by their front matter, without reading the working tree."""
    listing = git("ls-tree", "-d", "--name-only", f"{MAIN}:web/content/whats-new", check=False)
    items = []
    for folder in filter(None, listing.splitlines()):
        source = git("show", f"{MAIN}:web/content/whats-new/{folder}/index.md", check=False)
        front = dict(re.findall(r"^(\w+):\s*(.*?)\s*$", source.split("\n---", 1)[0], re.M))
        items.append({"id": folder, "version": front.get("version", ""), "title": front.get("title", ""),
                      "draft": front.get("draft") == "true"})
    return {"forUpcoming": [item for item in items if item["version"] == version], "all": len(items)}


def unmerged_branches():
    out = []
    for line in git("for-each-ref", "--format=%(refname:short)", "refs/heads").splitlines():
        ahead = int(git("rev-list", "--count", f"{MAIN}..{line}", check=False) or 0)
        if ahead:
            subject = git("log", "-1", "--format=%s", line)
            out.append({"branch": line, "ahead": ahead, "last": subject})
    worktrees = {}
    for block in git("worktree", "list", "--porcelain").split("\n\n"):
        path = re.search(r"^worktree (.+)$", block, re.M)
        branch = re.search(r"^branch refs/heads/(.+)$", block, re.M)
        if path and branch:
            worktrees[branch[1]] = path[1]
    for branch in out:
        branch["worktree"] = worktrees.get(branch["branch"])
    return sorted(out, key=lambda branch: -branch["ahead"])


def open_reports():
    issues = gh("issue", "list", "--state", "open", "--limit", "300", "--json", "number,title,labels,url,createdAt")
    if issues is None:
        return None
    reports = []
    for issue in issues:
        labels = {label["name"] for label in issue["labels"]}
        if "bug" in labels or "in-app" in labels:
            reports.append({"number": issue["number"], "title": issue["title"], "url": issue["url"],
                            "labels": sorted(labels - {"tracker"}), "opened": issue["createdAt"][:10],
                            "tracked": bool(TRACKER_ID.match(issue["title"]))})
    return reports


def ci_on_main():
    runs = gh("run", "list", "--branch", "main", "--workflow", "ci.yml", "--limit", "1",
              "--json", "status,conclusion,headSha,url,createdAt")
    if not runs:
        return None
    run = runs[0]
    main_sha = git("rev-parse", MAIN)
    return {"status": run["status"], "conclusion": run["conclusion"], "url": run["url"],
            "commit": run["headSha"][:7], "isMainHead": run["headSha"] == main_sha, "date": run["createdAt"][:16]}


def libraw_upstream():
    """LibRaw master's commits that the pinned fork commit lacks, and the fork's sync pull request."""
    pin = json.loads(git("show", f"{MAIN}:config/vendored-libs.json"))["LibRaw"]
    fork = re.match(r"https://github\.com/([^/]+/[^/]+)/", pin["url"])
    if not fork or fork.group(1) == "LibRaw/LibRaw" or not re.fullmatch(r"[0-9a-f]{40}", pin["version"]):
        return None
    compare = gh("api", f"repos/LibRaw/LibRaw/compare/{pin['version']}...master")
    if compare is None:
        return {"pin": pin["version"][:7], "fork": fork.group(1), "behind": None}
    sync = gh("pr", "list", "-R", fork.group(1), "--head", "upstream-sync", "--state", "open",
              "--json", "number,title,url,isDraft") or []
    return {"pin": pin["version"][:7], "fork": fork.group(1), "behind": compare["ahead_by"],
            "base": compare["merge_base_commit"]["sha"][:7], "sync": sync[0] if sync else None}


def status():
    git("fetch", "--quiet", "--tags", "origin", check=False)
    latest = latest_release()
    if not latest:
        raise SystemExit("no release yet: no v* tag on origin/main")
    upcoming = upcoming_release(latest)
    commits = changes(latest)
    rows = tracker_rows()
    named = sorted({row for commit in commits for row in commit["rows"]})
    shipped_rows = [{"id": row, "status": status_word(rows[row]), "title": item_title(rows[row]),
                     "commits": [commit["sha"] for commit in commits if row in commit["rows"]]}
                    for row in named if row in rows]
    unknown = [row for row in named if row not in rows]
    open_rows = [{"id": row["id"], "status": status_word(row), "title": item_title(row), "section": row["section"]}
                 for row in rows.values() if status_word(row) in ("In progress", "Blocked")]
    return {
        "latest": latest,
        "upcoming": upcoming,
        "mainHead": git("log", "-1", "--format=%h %s", MAIN),
        "localMain": {"ahead": int(git("rev-list", "--count", f"{MAIN}..main", check=False) or 0),
                      "behind": int(git("rev-list", "--count", f"main..{MAIN}", check=False) or 0)},
        "commits": commits,
        "untracked": [commit for commit in commits if not commit["rows"]],
        "rows": shipped_rows,
        "partlyShipped": [row for row in shipped_rows if row["status"] in ("In progress", "Blocked", "Not started")],
        "unknownRows": unknown,
        "inProgress": open_rows,
        "whatsNew": whats_new(upcoming["version"]),
        "knownLimitations": known_limitations(),
        "unmergedBranches": unmerged_branches(),
        "reports": open_reports(),
        "ci": ci_on_main(),
        "libraw": libraw_upstream(),
    }


def report(data):
    latest, upcoming = data["latest"], data["upcoming"]
    print(f"Latest release:   {latest['version']} ({latest['date']}, from {latest['source']})")
    print(f"Upcoming release: {upcoming['version']}, build {upcoming['build']} ({upcoming['rule']})")
    print(f"origin/main:      {data['mainHead']}")
    local = data["localMain"]
    if local["ahead"] or local["behind"]:
        print(f"Local main:       {local['ahead']} ahead, {local['behind']} behind origin/main")
    print(f"\nChanges since {latest['version']}: {len(data['commits'])} commits")
    for row in data["rows"]:
        print(f"  {row['id']:<8} {row['status']:<12} {row['title']}  ({len(row['commits'])} commits)")
    if data["untracked"]:
        print(f"  {len(data['untracked'])} commits name no tracker row:")
        for commit in data["untracked"]:
            print(f"    {commit['sha']} {commit['subject'][:100]}")
    if data["partlyShipped"]:
        print("\nPartly shipped (rows with commits in this release that aren't Done):")
        for row in data["partlyShipped"]:
            print(f"  {row['id']:<8} {row['status']:<12} {row['title']}")
    news = data["whatsNew"]["forUpcoming"]
    print(f"\nWhat's New for {upcoming['version']} on origin/main: " + (
        ", ".join(f"{item['title']}{' (draft)' if item['draft'] else ''}" for item in news) or "none yet"))
    print(f"\nUnmerged branches ({len(data['unmergedBranches'])}):")
    for branch in data["unmergedBranches"]:
        print(f"  {branch['branch']:<28} {branch['ahead']:>3} ahead  {branch['last'][:70]}")
    reports = data["reports"]
    if reports is None:
        print("\nOpen bug and in-app reports: GitHub not reached")
    else:
        print(f"\nOpen bug and in-app reports ({len(reports)}):")
        for issue in reports:
            print(f"  #{issue['number']:<5} {issue['title'][:80]}  [{', '.join(issue['labels'])}]")
    ci = data["ci"]
    print("\nCI on main: " + ("GitHub not reached" if ci is None else
          f"{ci['conclusion'] or ci['status']} at {ci['commit']}{'' if ci['isMainHead'] else ' (not main head)'} {ci['url']}"))
    libraw = data["libraw"]
    if libraw:
        line = f"\nLibRaw: {libraw['fork']} at {libraw['pin']}, "
        if libraw["behind"] is None:
            line += "GitHub not reached"
        else:
            line += f"on LibRaw master's {libraw['base']}; master has {libraw['behind']} commits since"
        if libraw.get("sync"):
            sync = libraw["sync"]
            line += f"\n  Upstream sync: {sync['title']}{' (draft: the bench failed)' if sync['isDraft'] else ''} {sync['url']}"
        print(line)
    print(f"\nTracker rows In progress or Blocked: {len(data['inProgress'])}")
    print(f"Known limitations in the README: {len(data['knownLimitations'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--json", action="store_true", help="print JSON for the release room")
    args = parser.parse_args()
    data = status()
    if args.json:
        json.dump(data, sys.stdout, indent=2)
        print()
    else:
        report(data)


if __name__ == "__main__":
    main()
