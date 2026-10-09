#!/usr/bin/env python3
"""Where every report stands, for the reports room (.cursor/skills/redlamp-reports/SKILL.md).

    room.py status [--offline] [--json]   a report to read
    room.py sync [--offline] [--force]    writes the room's generated block from GitHub, git and the notes
    room.py watch [--every 300]           sync on a loop, to keep the board live; it only reads
    room.py claim <n> --token <token> [--title <chat title>]
    room.py note <n> [--stage …] [--text …] [--waiting you|reporter|none] [--why …] [--reproduced …]
                     [--branch …] [--worktree …] [--read …] [--proposal <json>] [--triage <decision>]
                     [--reason …] [--applied …] [--reply-url … --release …] [--out-url …] [--tracked <ID>]
    room.py log <text>

Reports are the issues people file on pdcgomes/redlamp: those labelled bug, in-app, enhancement or
question, and open ones with no tracker ID, but never the issues the tracker mirrors (unless the room
already follows them, as it does a suggestion once it's accepted). For each, GitHub gives its state,
labels, the redlamp-feedback line the app writes, the reporter's words and the comments; git gives
the commits naming #n on origin/main and on local branches (copies of commits already on main are
ignored), and the first v* tag that holds them. A commit on main that changes only the tracker and
the roadmap documents, as accepting a suggestion does, isn't its fix. The room's notes, one JSON file per report in
~/.cursor/projects/<workspace>/reports-room/reports/, hold what agents record; the owner's clicks are
read from reports-room.canvas.data.json, which only the canvas writes.

sync writes everything between the room's REPORTS:BEGIN and REPORTS:END lines. It rewrites the file
only when something changed, or when the board's last check is over four minutes old.
"""

import argparse
import base64
import datetime as dt
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[3]
REPO = "pdcgomes/redlamp"
OWNER = "pdcgomes"
REPORT_LABELS = {"bug", "in-app", "enhancement", "question"}
KIND_OF_LABEL = {"bug": "bug", "enhancement": "idea", "question": "question"}
TRACKER_ID = re.compile(r"^(?:[A-Z]{2,4}|P1)-\d{2,3}\b")
ISSUE_IN_SUBJECT = re.compile(r"#(\d+)\b")
MARKER = re.compile(r"<!-- redlamp-feedback v1 (\{.*?\}) -->")
SECTIONS = ("What happened", "What I expected", "Steps to reproduce", "What I'd like to do", "How it could work", "Message")
# A fix touching only these paths ships without a release: the site deploys and the cask updates from main.
OUTSIDE_APP = ("web/", "Casks/", "docs/", "README.md", ".cursor/", ".github/", "research/", "video/", "CONTRIBUTING.md")
# A commit that changes the tracker and nothing past these adds or updates rows, such as an accepted
# suggestion's: it plans the work and never fixes the report it names.
TRACKER_DOC = "docs/research/research-tracker.md"
ROADMAP_DOCS = {TRACKER_DOC, "README.md", "docs/lightroom-comparison.md"}
FIXED_CANDIDATE = ("awaiting approval", "approved", "releasing")
STAGES = ("reading", "reproducing", "fixing", "testing", "pushing", "landed", "replied", "closed")


def git(*args, check=False, cwd=ROOT):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def gh_json(*args):
    try:
        result = subprocess.run(["gh", *args], cwd=ROOT, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        return None


def main_checkout():
    common = pathlib.Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent


PROJECT = pathlib.Path.home() / ".cursor/projects" / str(main_checkout()).strip("/").replace("/", "-")
CANVAS = PROJECT / "canvases/reports-room.canvas.tsx"
MARKS = PROJECT / "canvases/reports-room.canvas.data.json"
RELEASE_ROOM = PROJECT / "canvases/release-room.canvas.tsx"
TRANSCRIPTS = PROJECT / "agent-transcripts"
STORE = PROJECT / "reports-room"
NOTES = STORE / "reports"
THUMBS = STORE / "thumbs"
LOG = STORE / "log.jsonl"


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


# ---------------------------------------------------------------- the notes


def note_path(number):
    return NOTES / f"{number}.json"


def read_note(number):
    path = note_path(number)
    return json.loads(path.read_text()) if path.exists() else {"number": number}


def write_note(note):
    NOTES.mkdir(parents=True, exist_ok=True)
    path = note_path(note["number"])
    with tempfile.NamedTemporaryFile("w", dir=NOTES, delete=False, suffix=".tmp") as handle:
        json.dump(note, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(handle.name, path)


# A round is one try at a report: its triage, its agent and what came of it. A reopened report starts another.
ROUND_KEYS = ("triage", "agent", "stage", "waiting", "why", "reproduced", "branch", "worktree", "reply", "out")


def round_of(note):
    return {"triage": note.get("triage"), "agent": note.get("agent"), "stage": note.get("stage"),
            "reproduced": note.get("reproduced"), "reply": note.get("reply"), "out": note.get("out")}


def all_notes():
    if not NOTES.is_dir():
        return {}
    return {int(p.stem): json.loads(p.read_text()) for p in NOTES.glob("*.json") if p.stem.isdigit()}


def room_log():
    if not LOG.exists():
        return []
    return [json.loads(line) for line in LOG.read_text().splitlines() if line.strip()]


def owner_marks():
    """The owner's clicks on the board, by issue number."""
    if not MARKS.exists():
        return {}
    try:
        data = json.loads(MARKS.read_text())
    except json.JSONDecodeError:
        return {}
    return {int(k): v for k, v in (data.get("triage") or {}).items() if str(k).isdigit()}


# ---------------------------------------------------------------- GitHub


def parse_body(body):
    body = body or ""
    meta = {}
    if match := MARKER.search(body):
        try:
            meta = json.loads(match[1])
        except json.JSONDecodeError:
            meta = {}
    area = re.search(r"\*\*Area:\*\* ([^·\n]+)", body)
    often = re.search(r"\*\*How often:\*\* ([^·\n]+)", body)
    origin = re.search(r"^\*\*From:\*\* (.+)$", body, re.M)
    mention = re.search(r"^\*\*Reported by:\*\* (.+)$", body, re.M)
    words = {}
    for title in SECTIONS:
        if found := re.search(rf"^### {re.escape(title)}\n\n(.*?)(?=\n### |\n<details>|\n---\n|\Z)", body, re.M | re.S):
            words[title] = found[1].strip()
    shots = re.findall(r"!\[[^\]]*\]\((https://raw\.githubusercontent\.com/[^)\s]+)\)", body)
    diagnostics = re.search(r"\[diagnostics\.json\]\((https://[^)\s]+)\)", body)
    return {
        "meta": meta,
        "area": area[1].strip() if area else None,
        "often": often[1].strip() if often else None,
        "from": origin[1].strip() if origin else None,
        "mention": mention[1].strip() if mention else None,
        "words": words,
        "screenshots": shots,
        "diagnostics": diagnostics[1] if diagnostics else None,
    }


def excerpt(text, length=240):
    text = re.sub(r"<!--.*?-->", "", text or "", flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "[image]", text)
    text = re.sub(r"https://github\.com/user-attachments/assets/\S+", "[video or image]", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= length else text[: length - 1].rstrip() + "…"


def stamp(iso):
    """Seconds since the epoch, for comparing GitHub's UTC times with the notes' local ones."""
    try:
        return dt.datetime.fromisoformat((iso or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def last_reopened(number):
    """When the issue was last reopened, and by whom, or None."""
    events = gh_json("api", f"repos/{REPO}/issues/{number}/events?per_page=100")
    reopened = [e for e in events or [] if e.get("event") == "reopened"]
    if not reopened:
        return None
    last = reopened[-1]
    return {"at": last["created_at"], "by": (last.get("actor") or {}).get("login")}


def issues(known):
    found = gh_json("issue", "list", "--repo", REPO, "--state", "all", "--limit", "400", "--json",
                    "number,title,state,stateReason,labels,author,createdAt,closedAt,updatedAt,url,body,comments")
    if found is None:
        return None
    out = []
    for issue in found:
        labels = {label["name"] for label in issue["labels"]}
        mirrored = "tracker" in labels or bool(TRACKER_ID.match(issue["title"]))
        if issue["number"] in known:
            pass
        elif mirrored:
            continue
        elif not (labels & REPORT_LABELS) and issue["state"] != "OPEN":
            continue
        out.append(issue)
    return out


# ---------------------------------------------------------------- git


def fetch(offline):
    if not offline:
        git("fetch", "--quiet", "--tags", "origin")


def commits_on_main():
    """{issue number: [commit]} for every commit on origin/main whose subject names an issue."""
    log = git("log", "origin/main", "--no-merges", "-E", "--grep=#[0-9]+", "--format=%H%x09%h%x09%cI%x09%s")
    out = {}
    for line in filter(None, log.splitlines()):
        full, short, when, subject = line.split("\t", 3)
        for number in {int(n) for n in ISSUE_IN_SUBJECT.findall(subject)}:
            out.setdefault(number, []).append({"sha": full, "short": short, "at": when, "subject": subject})
    for commits in out.values():
        commits.sort(key=lambda c: c["at"])
    return out


def worktrees():
    found = {}
    for block in git("worktree", "list", "--porcelain").split("\n\n"):
        path = re.search(r"^worktree (.+)$", block, re.M)
        branch = re.search(r"^branch refs/heads/(.+)$", block, re.M)
        if path and branch:
            found[branch[1]] = path[1]
    return found


def commits_on_branches(on_main):
    """{issue number: {branch: [commit]}} for commits not on origin/main, without copies of main's."""
    log = git("log", "--branches", "--not", "origin/main", "--no-merges", "--source", "-E", "--grep=#[0-9]+",
              "--format=%S%x09%h%x09%cI%x09%s")
    landed = {(n, c["subject"]) for n, commits in on_main.items() for c in commits}
    places = worktrees()
    out = {}
    for line in filter(None, log.splitlines()):
        ref, short, when, subject = line.split("\t", 3)
        branch = ref.removeprefix("refs/heads/")
        for number in {int(n) for n in ISSUE_IN_SUBJECT.findall(subject)}:
            if (number, subject) in landed:
                continue
            entry = out.setdefault(number, {}).setdefault(branch, {"branch": branch, "worktree": places.get(branch), "commits": []})
            entry["commits"].append({"short": short, "at": when, "subject": subject})
    return {n: list(branches.values()) for n, branches in out.items()}


def tags_holding(shas):
    """{sha: the first v* tag holding it, or None}, in one call: name-rev names each commit from its nearest tag."""
    if not shas:
        return {}
    named = git("name-rev", "--name-only", "--refs=refs/tags/v*", *shas)
    out = {}
    for sha, name in zip(shas, named.splitlines()):
        tag = re.match(r"^(?:tags/)?(v[^~^]+)", name)
        out[sha] = tag[1] if tag else None
    return out


def changed_files(shas):
    """{sha: the paths it changes}, for the shas given, in one call."""
    if not shas:
        return {}
    shown = git("show", "--name-only", "--format=@@%H", *shas)
    out, current = {}, None
    for line in shown.splitlines():
        if line.startswith("@@"):
            current = line[2:]
            out[current] = set()
        elif line and current:
            out[current].add(line)
    return out


def app_commits(files):
    """The commits, of those in `changed_files`, that change something in the app."""
    return {sha for sha, paths in files.items() if any(not path.startswith(OUTSIDE_APP) for path in paths)}


def roadmap_commits(files):
    """The commits, of those in `changed_files`, that change the tracker and nothing past the roadmap documents."""
    return {sha for sha, paths in files.items() if TRACKER_DOC in paths and paths <= ROADMAP_DOCS}


# ---------------------------------------------------------------- the release


def release_status_module():
    spec = importlib.util.spec_from_file_location("release_status", ROOT / "scripts/release-status.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def next_patch(version):
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(.*)$", version)
    return f"{match[1]}.{match[2]}.{int(match[3]) + 1}{match[4]}" if match else version


def release(offline):
    out = {"latest": None, "upcoming": None, "stage": None, "candidate": None, "roomVersion": None}
    try:
        status = release_status_module()
        latest = status.latest_release() if not offline else None
        if latest is None:
            # A release made from an earlier commit is tagged off main, so take the newest tag by version.
            newest = [t for t in git("tag", "--list", "v*", "--sort=v:refname").splitlines() if t]
            tag = newest[-1] if newest else None
            latest = {"version": tag.removeprefix("v"), "date": git("log", "-1", "--format=%cs", tag)} if tag else None
        out["latest"] = {"version": latest["version"], "date": latest["date"]} if latest else None
        if latest:
            out["upcoming"] = status.upcoming_release(latest)["version"]
    except (SystemExit, Exception) as error:  # the room still stands without the release's details
        out["error"] = str(error)
    if RELEASE_ROOM.exists():
        text = RELEASE_ROOM.read_text()
        text = text[text.find("const room: Room = {"):]
        block = re.search(r"\n  upcoming: \{(.*?)\n  \},", text, re.S)
        if block:
            version = re.search(r'version: "([^"]+)"', block[1])
            stage = re.search(r'stage: "([^"]+)"', block[1])
            base = re.search(r'base: "([^"]+)"', block[1])
            out["roomVersion"] = version[1] if version else None
            out["stage"] = stage[1] if stage else None
            out["candidate"] = base[1] if base else None
    return out


def expected_release(fix_commits, rel):
    """The release a fix on main, not yet in a tag, is expected in."""
    upcoming = rel.get("upcoming")
    if not upcoming:
        return None
    if rel.get("stage") in FIXED_CANDIDATE and rel.get("candidate") and rel.get("roomVersion") == upcoming:
        held = all(subprocess.run(["git", "merge-base", "--is-ancestor", c["sha"], rel["candidate"]], cwd=ROOT).returncode == 0
                   for c in fix_commits)
        if not held:
            return next_patch(upcoming)
    return upcoming


# ---------------------------------------------------------------- thumbnails


def thumbnail(number, url, offline):
    THUMBS.mkdir(parents=True, exist_ok=True)
    small = THUMBS / f"{number}.jpg"
    if not small.exists():
        if offline:
            return None
        original = THUMBS / f"{number}-original"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "redlamp-reports-room"}), timeout=30) as response:
                original.write_bytes(response.read())
        except OSError:
            return None
        made = subprocess.run(["sips", "-Z", "360", "-s", "format", "jpeg", "-s", "formatOptions", "55",
                               str(original), "--out", str(small)], capture_output=True)
        original.unlink(missing_ok=True)
        if made.returncode != 0 or not small.exists():
            return None
    return "data:image/jpeg;base64," + base64.b64encode(small.read_bytes()).decode()


# ---------------------------------------------------------------- putting it together


def kind_of(issue, parsed):
    kind = parsed["meta"].get("kind")
    if kind in ("bug", "idea", "question"):
        return kind
    for label in issue["labels"]:
        if label["name"] in KIND_OF_LABEL:
            return KIND_OF_LABEL[label["name"]]
    return "unsorted"


def reporter(issue, parsed):
    author = issue["author"]["login"]
    if author.startswith("app/") or issue["author"].get("is_bot"):
        mention = parsed["mention"]
        return {"inApp": True, "login": mention.lstrip("@") if mention else None}
    return {"inApp": False, "login": author}


def build(offline):
    fetch(offline)
    notes = all_notes()
    marks = owner_marks()
    found = issues(set(notes) | set(marks))
    if found is None:
        raise SystemExit("GitHub couldn't be reached through gh; nothing was changed.")
    on_main = commits_on_main()
    on_branches = commits_on_branches(on_main)
    numbers = {issue["number"] for issue in found}
    shas = sorted({c["sha"] for n, commits in on_main.items() if n in numbers for c in commits})
    holding = tags_holding(shas)
    files = changed_files(shas)
    in_app = app_commits(files)
    planning = roadmap_commits(files)
    all_tags = [t for t in git("tag", "--list", "v*", "--sort=v:refname").splitlines() if t]
    rel = release(offline)
    reports = []
    events = []
    for issue in sorted(found, key=lambda i: i["createdAt"], reverse=True):
        number = issue["number"]
        parsed = parse_body(issue["body"])
        note = notes.get(number, {"number": number})
        mark = marks.get(number)
        kind = kind_of(issue, parsed)
        who = reporter(issue, parsed)
        comments = [{"by": c["author"]["login"], "you": c["author"]["login"] == OWNER, "at": c["createdAt"],
                     "text": excerpt(c["body"]), "url": c.get("url")} for c in issue.get("comments", [])]
        fix = [c for c in on_main.get(number, []) if c["sha"] not in planning]
        reopened = None
        if issue["state"] == "OPEN" and (fix or note.get("reply") or note.get("out") or note.get("stage") in ("replied", "closed")):
            reopened = last_reopened(number)
        rounds = list(note.get("rounds", []))
        note_round = note
        if reopened:
            # What was recorded before the reopen is an earlier round; only newer work counts now.
            earlier = [c for c in fix if stamp(c["at"]) < stamp(reopened["at"])]
            fix = [c for c in fix if stamp(c["at"]) >= stamp(reopened["at"])]
            agent = note.get("agent")
            if not agent or stamp(agent.get("started")) < stamp(reopened["at"]):
                if agent or note.get("reply"):
                    rounds.append({**round_of(note), "commits": [c["short"] for c in earlier],
                                   "release": next((holding.get(c["sha"]) for c in earlier if holding.get(c["sha"])), None)})
                note_round = {k: v for k, v in note.items() if k not in ROUND_KEYS}
        fix_info = None
        if fix:
            held = [holding.get(c["sha"]) for c in fix]
            tag = None if None in held or not held else max(held, key=lambda t: all_tags.index(t) if t in all_tags else -1)
            app = any(c["sha"] in in_app for c in fix)
            if not app:
                state, version = "live", None
            elif tag:
                state, version = "released", tag.removeprefix("v")
            else:
                state, version = "expected", expected_release(fix, rel)
            promised = (note_round.get("reply") or {}).get("release")
            missed = bool(promised and state != "released" and f"v{promised}" in all_tags)
            fix_info = {"commits": [{k: c[k] for k in ("short", "at", "subject")} for c in fix], "insideApp": app,
                        "state": "missed" if missed else state, "version": version, "promised": promised}
        triage = note_round.get("triage") or None
        if mark and reopened and stamp(mark.get("at")) < stamp(reopened["at"]):
            mark = None
        if mark and (triage is None or stamp(mark.get("at")) > stamp(triage.get("at"))):
            triage = {"decision": mark.get("decision"), "at": mark.get("at"), "reason": mark.get("reason"), "applied": None}
        replied_after_fix = bool(fix) and any(c["you"] and c["at"] >= fix[0]["at"] for c in comments)
        report = {
            "number": number,
            "title": issue["title"],
            "url": issue["url"],
            "kind": kind,
            "area": parsed["area"] or parsed["meta"].get("area"),
            "often": parsed["often"],
            "from": parsed["from"],
            "version": parsed["meta"].get("version"),
            "reporter": who,
            "labels": sorted(l["name"] for l in issue["labels"]),
            "opened": issue["createdAt"],
            "state": issue["state"].lower(),
            "stateReason": (issue.get("stateReason") or "").lower() or None,
            "closed": issue.get("closedAt"),
            "words": parsed["words"],
            "screenshots": len(parsed["screenshots"]),
            "diagnostics": parsed["diagnostics"],
            "comments": comments,
            "triage": triage,
            "read": None if reopened and stamp((note.get("read") or {}).get("at")) < stamp(reopened["at"]) else note.get("read"),
            "proposal": note.get("proposal"),
            "agent": note_round.get("agent"),
            "stage": note_round.get("stage"),
            "waiting": note_round.get("waiting"),
            "why": note_round.get("why"),
            "reproduced": note_round.get("reproduced"),
            "branches": on_branches.get(number, []),
            "fix": fix_info,
            "reply": note_round.get("reply") or ({"url": None, "at": None, "release": None, "fromComments": True} if replied_after_fix else None),
            "out": note_round.get("out"),
            "reopened": reopened,
            "rounds": rounds,
            "tracked": note.get("tracked") or (TRACKER_ID.match(issue["title"])[0] if TRACKER_ID.match(issue["title"]) else None),
            "notes": note.get("notes", [])[-12:],
            "thumb": None,
        }
        waiting_for_triage = report["state"] == "open" and not triage and not note_round.get("agent")
        if waiting_for_triage and parsed["screenshots"]:
            report["thumb"] = thumbnail(number, parsed["screenshots"][0], offline)
        reports.append(report)
        events.append({"at": issue["createdAt"], "text": f"#{number} filed{' from the app' if who['inApp'] else ''}: {issue['title']}"})
        if issue.get("closedAt") and issue["state"] == "CLOSED":
            reason = (issue.get("stateReason") or "").lower().replace("_", " ") or "closed"
            events.append({"at": issue["closedAt"], "text": f"#{number} closed ({reason})."})
        if reopened:
            events.append({"at": reopened["at"], "text": f"#{number} reopened{' by ' + ('you' if reopened['by'] == OWNER else reopened['by']) if reopened['by'] else ''}."})
        for entry in note.get("notes", []):
            events.append({"at": entry["at"], "text": f"#{number}: {entry['text']}"})
    for entry in room_log():
        events.append(entry)
    events.sort(key=lambda e: e["at"], reverse=True)
    return {"release": rel, "reports": reports, "log": events[:80], "owner": OWNER, "repo": REPO,
            "notesDir": str(NOTES), "script": str(main_checkout() / ".cursor/skills/redlamp-reports/room.py")}


# ---------------------------------------------------------------- the room's block


BEGIN = "// REPORTS:BEGIN"
END = "// REPORTS:END"


def current_block(text):
    match = re.search(rf"^{re.escape(BEGIN)}\b[^\n]*\nconst DATA: Data = (.*?);\n{re.escape(END)}$", text, re.M | re.S)
    if not match:
        return None
    try:
        return json.loads(match[1])
    except json.JSONDecodeError:
        return None


def sync(offline, force=False, canvas=CANVAS):
    data = build(offline)
    text = canvas.read_text()
    begin = re.search(rf"^{re.escape(BEGIN)}\b.*$", text, re.M)
    end = re.search(rf"^{re.escape(END)}$", text, re.M)
    if not begin or not end or end.start() < begin.start():
        raise SystemExit(f"{canvas} has no {BEGIN} … {END} block")
    previous = current_block(text) or {}
    stamp = now()
    same = {k: v for k, v in previous.items() if k not in ("checked", "changed")} == data
    checked_age = time.time() - dt.datetime.fromisoformat(previous["checked"]).timestamp() if previous.get("checked") else 1e9
    if same and checked_age < 240 and not force:
        print(f"Nothing changed since {previous.get('checked')}; the room was left as it is.")
        return data
    data_out = {"checked": stamp, "changed": previous.get("changed") if same and previous.get("changed") else stamp, **data}
    block = f"{BEGIN} (room.py sync writes this block; never edit it by hand)\nconst DATA: Data = {json.dumps(data_out, ensure_ascii=False, indent=1)};\n{END}"
    new = text[: begin.start()] + block + text[end.end() :]
    with tempfile.NamedTemporaryFile("w", dir=canvas.parent, delete=False, suffix=".tmp") as handle:
        handle.write(new)
    os.replace(handle.name, canvas)
    print(f"{len(data['reports'])} reports written into {canvas}{'' if not same else ' (only the check time changed)'}")
    return data


# ---------------------------------------------------------------- reading it


def describe(report):
    bits = [f"#{report['number']:<4} {report['kind']:<8} {report['state']:<6}"]
    if report["state"] == "closed" and report["stateReason"]:
        bits.append(f"({report['stateReason']})")
    bits.append(report["title"][:80])
    lines = [" ".join(bits)]
    detail = []
    if report["reopened"]:
        earlier = report["rounds"][-1] if report["rounds"] else {}
        detail.append(f"reopened {report['reopened']['at'][:16]} by {report['reopened']['by']}"
                      + (f", after {', '.join(earlier.get('commits') or [])} ({earlier.get('release') or '?'})" if earlier else ""))
    if report["triage"]:
        t = report["triage"]
        detail.append(f"triage: {t['decision']}{'' if t.get('applied') else ' (not applied yet)'}")
    elif report["state"] == "open" and not report["agent"]:
        detail.append("waiting for triage")
    if report["agent"]:
        detail.append(f"agent {report['agent'].get('chat') or '(chat not recorded)'}, stage {report['stage'] or '?'}")
    if report["waiting"]:
        detail.append(f"waiting on {report['waiting']}: {report['why'] or ''}".strip())
    for branch in report["branches"]:
        detail.append(f"on {branch['branch']}: {len(branch['commits'])} commits")
    if report["fix"]:
        f = report["fix"]
        detail.append(f"on main: {', '.join(c['short'] for c in f['commits'])}; {f['state']}{' ' + f['version'] if f['version'] else ''}")
    if report["reply"]:
        detail.append("replied" + (f" ({report['reply']['url']})" if report["reply"].get("url") else " (a comment of yours after the fix)"))
    if report["tracked"]:
        detail.append(f"tracked as {report['tracked']}")
    replies = [c for c in report["comments"] if c["you"]]
    others = sorted({c["by"] for c in report["comments"] if not c["you"]})
    detail.append(f"{len(replies)} replies from you" + (f"; comments from {', '.join(others)}" if others else ""))
    lines.append("       " + "; ".join(detail))
    return "\n".join(lines)


def status(offline, as_json):
    data = build(offline)
    if as_json:
        for report in data["reports"]:
            report["thumb"] = bool(report["thumb"])
        json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    rel = data["release"]
    latest = rel.get("latest") or {}
    print(f"Latest release {latest.get('version', '?')} ({latest.get('date', '?')}); upcoming {rel.get('upcoming', '?')}; "
          f"the release room says {rel.get('roomVersion', '?')}, {rel.get('stage', '?')}, candidate {rel.get('candidate', '?')}")
    groups = (
        ("Waiting for your triage", lambda r: r["state"] == "open" and not r["triage"] and not r["agent"]),
        ("Decided, not applied yet", lambda r: r["triage"] and not r["triage"].get("applied") and r["triage"]["decision"] != "fix"),
        ("Agents at work", lambda r: r["state"] == "open" and (r["agent"] or (r["triage"] or {}).get("decision") == "fix")),
        ("Other open reports", lambda r: r["state"] == "open"),
        ("Closed", lambda r: True),
    )
    shown = set()
    for title, test in groups:
        members = [r for r in data["reports"] if r["number"] not in shown and test(r)]
        if not members:
            continue
        print(f"\n{title} ({len(members)}):")
        for report in members:
            shown.add(report["number"])
            print(describe(report))


# ---------------------------------------------------------------- recording


def chat_for(token):
    if not TRANSCRIPTS.is_dir():
        return None
    found = subprocess.run(["grep", "-rl", "--include=*.jsonl", token, str(TRANSCRIPTS)], capture_output=True, text=True).stdout.split()
    for path in found:
        relative = pathlib.Path(path).relative_to(TRANSCRIPTS)
        if "subagents" not in relative.parts:
            return relative.parts[0].removesuffix(".jsonl")
    return None


def claim(args):
    note = read_note(args.number)
    chat = chat_for(args.token) if args.token else None
    if note.get("agent") and (note.get("reply") or note.get("stage") in ("replied", "closed")):
        commits = [c["short"] for c in commits_on_main().get(args.number, [])]
        note.setdefault("rounds", []).append({**round_of(note), "commits": commits, "release": (note.get("reply") or {}).get("release")})
        for key in ROUND_KEYS:
            note.pop(key, None)
        note.setdefault("notes", []).append({"at": now(), "text": "Reopened: the earlier round is kept in the room's history."})
    note["agent"] = {"chat": chat, "title": args.title, "started": now(), "token": args.token}
    note["stage"] = "reading"
    note["waiting"] = None
    marks = owner_marks()
    if not note.get("triage"):
        mark = marks.get(args.number) or {}
        note["triage"] = {"decision": "fix", "at": mark.get("at") or now(), "reason": None, "applied": now()}
    note.setdefault("notes", []).append({"at": now(), "text": f"Its agent started{'' if chat else ' (its chat could not be found from the token)'}."})
    write_note(note)
    print(f"#{args.number} claimed by chat {chat or '(not found)'}")


def note_cmd(args):
    note = read_note(args.number)
    if args.stage:
        note["stage"] = args.stage
    if args.waiting:
        note["waiting"] = None if args.waiting == "none" else args.waiting
        note["why"] = args.why if args.waiting != "none" else None
    if args.reproduced:
        note["reproduced"] = args.reproduced
    if args.branch:
        note["branch"] = args.branch
    if args.worktree:
        note["worktree"] = args.worktree
    if args.read:
        note["read"] = {"at": now(), "text": args.read}
    if args.proposal:
        note["proposal"] = json.loads(args.proposal)
    if args.triage:
        mark = owner_marks().get(args.number) or {}
        note["triage"] = {"decision": args.triage, "at": mark.get("at") or now(), "reason": args.reason or mark.get("reason"),
                          "applied": args.applied or now()}
    if args.reply_url:
        note["reply"] = {"url": args.reply_url, "at": now(), "release": args.release}
    if args.out_url:
        note["out"] = {"url": args.out_url, "at": now()}
    if args.tracked:
        note["tracked"] = args.tracked
    if args.text:
        note.setdefault("notes", []).append({"at": now(), "text": args.text})
    write_note(note)
    print(f"#{args.number} noted")


def log_cmd(args):
    STORE.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as handle:
        handle.write(json.dumps({"at": now(), "text": args.text}, ensure_ascii=False) + "\n")
    print("logged")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("status")
    p.add_argument("--offline", action="store_true", help="don't fetch, and don't ask GitHub for the latest release")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("sync")
    p.add_argument("--offline", action="store_true")
    p.add_argument("--force", action="store_true", help="rewrite the block even when nothing changed")
    p.add_argument("--canvas", type=pathlib.Path, default=CANVAS)
    p = sub.add_parser("watch")
    p.add_argument("--every", type=int, default=300, help="seconds between syncs")
    p = sub.add_parser("claim")
    p.add_argument("number", type=int)
    p.add_argument("--token", help="the token in the agent's prompt, to find its chat")
    p.add_argument("--title")
    p = sub.add_parser("note")
    p.add_argument("number", type=int)
    p.add_argument("--stage", choices=STAGES)
    p.add_argument("--text")
    p.add_argument("--waiting", choices=("you", "reporter", "none"))
    p.add_argument("--why")
    p.add_argument("--reproduced", choices=("yes", "not needed", "couldn't"))
    p.add_argument("--branch")
    p.add_argument("--worktree")
    p.add_argument("--read", help="a short read of the report, for triage")
    p.add_argument("--proposal", help='JSON: {"kind": "new row" | "follows" | "duplicate", "id": …, "text": …, "phase": …, "reply": …}')
    p.add_argument("--triage", choices=("fix", "close", "accept", "reject", "answer"), help="record a decision as applied")
    p.add_argument("--reason")
    p.add_argument("--applied", help="what applying it did")
    p.add_argument("--reply-url")
    p.add_argument("--release", help="the release the reply says the fix is expected in")
    p.add_argument("--out-url", help="the note that the release with the fix is out")
    p.add_argument("--tracked", help="the tracker row the report became or follows")
    p = sub.add_parser("log")
    p.add_argument("text")
    args = parser.parse_args()
    if args.command == "status":
        status(args.offline, args.json)
    elif args.command == "sync":
        sync(args.offline, args.force, args.canvas)
    elif args.command == "watch":
        while True:
            try:
                sync(False)
            except SystemExit as error:
                print(f"{now()}: {error}", file=sys.stderr)
            sys.stdout.flush()
            time.sleep(args.every)
    elif args.command == "claim":
        claim(args)
    elif args.command == "note":
        note_cmd(args)
    elif args.command == "log":
        log_cmd(args)


if __name__ == "__main__":
    main()
