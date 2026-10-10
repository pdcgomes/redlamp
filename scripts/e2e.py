#!/usr/bin/env python3
"""Run Redlamp's end-to-end regression suite (ARC-07, ARC-08).

Builds a test copy of the app (a Release build with the driver compiled in, under the bundle
ID app.redlamp.mac.e2e), runs its scenarios in a home of its own with no network, and writes a
report. The app's own driver (packages/RedlampAutomation) works the app through its keys, menus,
clicks and drags; this script launches it, watches it, and judges the run.

    scripts/e2e.py                       # the smoke tier, on a Debug build
    scripts/e2e.py --tier full           # every feature
    scripts/e2e.py --tier release        # full and soak on the QA build, then performance
    scripts/e2e.py --scenario smoke.export --scenario smoke.panel-sliders
    scripts/e2e.py --app build/release/Redlamp.app --tier release   # a build made elsewhere

It exits 1 if a scenario fails (a pass on retry is flaky, reported, and doesn't fail the run), the
app crashes or hangs, a feature the full tiers must cover isn't covered or exempted, or the
owner's own Redlamp state changed. The report is build/e2e/<commit>-<time>/report.md.

A failed scenario is retried once, in a launch that starts from the photos, home and defaults the
first attempt started from; the run directory's attempt-1 keeps what the first attempt left. The
retry's result stands for the scenario: the stalls of the first attempt are reported with their
attempt but don't count against the run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import http.server
import json
import os
import platform
import plistlib
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "app.redlamp.mac.e2e"
NAME = "Redlamp E2E"
SCENARIO_TIMEOUT = 300
QUIET_LOAD = 8.0
HOME = Path.home()
# Whether another Redlamp (the owner's, or another session's) ran while the suite did.
OTHER_REDLAMP_SEEN = False


def log(message: str) -> None:
    print(f"==> {message}", flush=True)


def screen_locked() -> bool:
    """Whether the console session's screen is locked, as the IORegistry's console users say."""
    try:
        out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, timeout=10).stdout
        users = plistlib.loads(out).get("IOConsoleUsers", [])
    except (subprocess.SubprocessError, plistlib.InvalidFileException, ValueError):
        return False
    return any(user.get("CGSSessionScreenIsLocked") for user in users)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, text=True, **kwargs)


def load() -> float:
    out = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout
    return float(out.strip("{} \n").split()[0])


def commit() -> tuple[str, bool]:
    sha = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short=7", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True)
    return sha.stdout.strip() or "unknown", bool(dirty.stdout.strip())


# ---------------------------------------------------------------- building the test app

def build(configuration: str) -> Path:
    """Builds the app with the driver compiled in: Debug, or Release with REDLAMP_PROFILING."""
    derived = ROOT / "build" / ("DerivedData-e2e" if configuration == "debug" else "DerivedData-e2e-qa")
    command = [
        "xcodebuild", "build", "-workspace", str(ROOT / "Redlamp.xcworkspace"), "-scheme", "Redlamp",
        "-configuration", "Debug" if configuration == "debug" else "Release",
        "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived), "-quiet",
    ]
    if configuration == "qa":
        command.append("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) REDLAMP_PROFILING")
    log(f"Building the {configuration} test app")
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        errors = [line for line in result.stdout.splitlines() + result.stderr.splitlines() if "error:" in line]
        sys.exit("build failed:\n" + "\n".join(errors[:30] or result.stderr.splitlines()[-30:]))
    return derived / "Build/Products" / ("Debug" if configuration == "debug" else "Release") / "Redlamp.app"


def signing_identity(app: Path) -> str:
    """The identity the build was signed with, so the copy's signature matches its frameworks."""
    if os.environ.get("REDLAMP_SIGN_IDENTITY"):
        return os.environ["REDLAMP_SIGN_IDENTITY"]
    info = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True).stderr
    for line in info.splitlines():
        if line.startswith("Authority="):
            return line.split("=", 1)[1]
    return "-"


def make_test_copy(built: Path, destination: Path) -> Path:
    """Copies the build under the test bundle ID and signs it again, so it has its own defaults."""
    app = destination / f"{NAME}.app"
    if app.exists():
        shutil.rmtree(app)
    destination.mkdir(parents=True, exist_ok=True)
    run(["ditto", str(built), str(app)])
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleIdentifier"] = BUNDLE_ID
    info["CFBundleName"] = NAME
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)
    identity = signing_identity(built)
    # Not the build's requirements: they name app.redlamp.mac, so the copy wouldn't meet its own and macOS
    # would ask again on every run for the file access it was given.
    run(["codesign", "--force", "--sign", identity, "--preserve-metadata=entitlements,flags",
         "--timestamp=none", str(app)], capture_output=True)
    run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
    return app


# ---------------------------------------------------------------- the run's home

def prepare_photos(photos: Path) -> list[str]:
    """APFS clones of the sample raws, the process gate's bitmap and other formats made from it."""
    photos.mkdir(parents=True)
    raw = ROOT / "tests/fixtures/raw"
    names = []
    for source in sorted(raw.iterdir()):
        if source.name.startswith(".") or source.suffix == ".redlamp" or source.is_dir():
            continue
        run(["cp", "-c", str(source), str(photos / source.name)])
        names.append(source.name)
    if not names:
        sys.exit("no sample raws in tests/fixtures/raw: run `mise run fixtures`")
    bitmap = ROOT / "tests/golden/process/DSC_0750.png"
    run(["cp", "-c", str(bitmap), str(photos / "Bitmap.png")])
    for extension, kind in [("jpg", "jpeg"), ("tif", "tiff"), ("heic", "heic")]:
        subprocess.run(["sips", "-s", "format", kind, str(bitmap), "--out", str(photos / f"Bitmap.{extension}")],
                       capture_output=True)
    names = sorted(p.name for p in photos.iterdir() if not p.name.startswith(".") and p.is_file())
    # In subfolders, so the folder's own photos all open: a focus bracket and a damaged raw.
    subprocess.run(["swift", str(ROOT / "scripts/make-focus-bracket.swift"), str(photos / "Bitmap.jpg"), str(photos / "Bracket"), "5"],
                   capture_output=True, timeout=300)
    damaged = photos / "Damaged"
    damaged.mkdir()
    nef = next((p for p in sorted(raw.iterdir()) if p.suffix.upper() == ".NEF"), None)
    if nef:
        (damaged / "Damaged.NEF").write_bytes(nef.read_bytes()[:4096])
    return names


def copy_photos(originals: Path, photos: Path) -> None:
    """The photos folder as an attempt first finds it: APFS clones of the run's originals, their dates kept."""
    run(["cp", "-cR", str(originals), str(photos)])


# Kept between runs on the checkout's volume, so each test home gets clones (no space, no
# copying) of the models and their compiles, rather than a copy of every model compiled anew.
CACHE = ROOT / "build/e2e/cache"
COMPILED = Path("Library/Caches/app.redlamp/CompiledModels")
RUNS_KEPT = 8


def seed_models(home: Path) -> None:
    """The models already downloaded, so no scenario downloads one, and their compiles."""
    owner = HOME / "Library/Application Support/Redlamp/Models"
    if owner.is_dir():
        (CACHE / "Models").mkdir(parents=True, exist_ok=True)
        subprocess.run(["rsync", "-a", "--delete", "--exclude", ".*", f"{owner}/", str(CACHE / "Models")],
                       capture_output=True)
        target = home / "Library/Application Support/Redlamp"
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-cR", str(CACHE / "Models"), str(target)], capture_output=True)
    if (CACHE / "CompiledModels").is_dir():
        (home / COMPILED).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-cR", str(CACHE / "CompiledModels"), str((home / COMPILED).parent)], capture_output=True)


def keep_compiled_models(home: Path) -> None:
    """Keeps the compiles a run made for the next run."""
    compiled = home / COMPILED
    if not compiled.is_dir():
        return
    (CACHE / "CompiledModels").mkdir(parents=True, exist_ok=True)
    for model in compiled.glob("*.mlmodelc"):
        if not (CACHE / "CompiledModels" / model.name).exists():
            subprocess.run(["cp", "-cR", str(model), str(CACHE / "CompiledModels")], capture_output=True)


# ---------------------------------------------------------------- storage

# The app's own limits: ThumbnailPacks, EmbeddingCache and FocusStackCache budgets.
STORAGE_LIMITS = {
    "Library/Caches/app.redlamp/Thumbnails": 1 << 30,
    "Library/Caches/app.redlamp/Embeddings": 1 << 30,
    "Library/Caches/app.redlamp/FocusStacks": 4 << 30,
}
# Hidden staging the app removes when a write finishes; any left after a run is a leak.
STAGING = {
    "Library/Caches/app.redlamp/FocusStacks": ".*",
    "Library/Caches/app.redlamp/Thumbnails": ".*.rltp.*",
    "Library/Application Support/Redlamp/Models": ".*",
}
OUTBOX_LIMIT = 20  # FeedbackHistory.outboxLimit


def tree_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


def temporary_compiles() -> set[str]:
    return {p.name for p in Path(tempfile.gettempdir()).glob("*.mlmodelc")}


def free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def left_behind(home: Path) -> list[str]:
    """What the app left in `home` and in its defaults that it should have removed or kept within its limits."""
    problems: list[str] = []
    for relative, limit in STORAGE_LIMITS.items():
        size = tree_size(home / relative)
        if size > limit * 1.1:
            problems.append(f"{relative} is {size / 2**20:.0f} MB, over its {limit / 2**20:.0f} MB limit")
    for relative, pattern in STAGING.items():
        left = sorted(p.name for p in (home / relative).glob(pattern)) if (home / relative).is_dir() else []
        if left:
            problems.append(f"staging left in {relative}: {', '.join(left[:5])}")
    exports = read_default("export.staging")
    if exports is not None and exports.strip() not in ("", "{\n}", "{}"):
        problems.append("an export's staging is still listed: " + " ".join(exports.split())[:200])
    outbox = home / "Library/Application Support/Redlamp/Feedback/outbox.json"
    if outbox.exists():
        try:
            queued = len(json.loads(outbox.read_text()))
        except ValueError:
            queued = 0
        if queued > OUTBOX_LIMIT:
            problems.append(f"the feedback outbox holds {queued} reports, over its {OUTBOX_LIMIT}")
    return problems


def storage_check(home: Path, compiles_before: set[str], free_before: int, earlier: list[str]) -> dict:
    """What the run left in the test home and the temporary folder, against the app's limits, after what
    `earlier` attempts left in homes of their own."""
    problems = earlier + left_behind(home)
    compiles = sorted(temporary_compiles() - compiles_before)
    if compiles:
        problems.append(f"compiled models left in the temporary folder: {', '.join(compiles[:5])}")
    return {"problems": problems, "sizes": {relative: tree_size(home / relative) for relative in STORAGE_LIMITS},
            "home": tree_size(home), "temporaryFreeChange": free_bytes(Path(tempfile.gettempdir())) - free_before}


def prune_runs(keep: int = RUNS_KEPT) -> None:
    """Removes all but the newest runs' folders."""
    runs = sorted((p for p in (ROOT / "build/e2e").iterdir() if p.is_dir() and p.name != "cache" and not p.name.endswith(".app")),
                  key=lambda p: p.stat().st_mtime, reverse=True)
    for old in runs[keep:]:
        shutil.rmtree(old, ignore_errors=True)


def defaults(*arguments: str) -> None:
    subprocess.run(["defaults", *arguments], capture_output=True)


def read_default(key: str) -> str | None:
    """The test app's default `key` as `defaults read` prints it, or None when it isn't set."""
    result = subprocess.run(["defaults", "read", BUNDLE_ID, key], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def seed_defaults(relay: int) -> None:
    defaults("delete", BUNDLE_ID)
    defaults("write", BUNDLE_ID, "welcome.shown", "-int", "99")
    defaults("write", BUNDLE_ID, "FeedbackEndpoint", f"http://127.0.0.1:{relay}/api/feedback")
    defaults("write", BUNDLE_ID, "CameraBenchEndpoint", f"http://127.0.0.1:{relay}/api/bench")
    defaults("write", BUNDLE_ID, "feedback.noteAccepted", "-int", "1")
    # The Export dialog opens on these; Show in Finder after export would bring Finder forward, and Ask
    # would stop an export to a name an earlier scenario's export took. A value the app can't read is Ask.
    previous = json.dumps({"revealInFinder": False, "existingFiles": "addNumber"}).encode().hex()
    defaults("write", BUNDLE_ID, "exportPrevious", "-data", previous)
    # Show Photos in Subfolders, on by default, off: the photos folder keeps a focus bracket and a damaged
    # raw in subfolders, which the scenarios that open every photo of the folder leave out.
    defaults("write", BUNDLE_ID, "folders.includesSubfolders", "-bool", "NO")


def start_afresh(run_dir: Path, relay: int, attempt: int) -> list[str]:
    """Puts back what the first attempt started from, for attempt `attempt`: the photos cloned again from the
    originals, a home holding only the models, the defaults seeded again, and no left.json. The attempt before
    keeps what it left in attempt-<n>; returns what it shouldn't have left there, for the storage check."""
    home = run_dir / "home"
    problems = [f"attempt {attempt - 1}: {problem}" for problem in left_behind(home)]
    keep_compiled_models(home)
    kept = run_dir / f"attempt-{attempt - 1}"
    kept.mkdir()
    for name in ["photos", "home", "left.json"]:
        if (run_dir / name).exists():
            (run_dir / name).rename(kept / name)
    home.mkdir()
    seed_models(home)
    copy_photos(run_dir / "originals", run_dir / "photos")
    seed_defaults(relay)
    return problems


# ---------------------------------------------------------------- the stub relay

class Relay(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, directory: Path):
        self.directory = directory
        self.count = 0
        directory.mkdir(parents=True, exist_ok=True)
        super().__init__(("127.0.0.1", 0), RelayHandler)


class RelayHandler(http.server.BaseHTTPRequestHandler):
    """Answers as redlamp.app's relay does for a dry run, and keeps what it was sent."""

    def log_message(self, *_):
        pass

    def reply(self, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({"reports": []})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        server: Relay = self.server  # type: ignore[assignment]
        server.count += 1
        name = f"{server.count:03d}-{self.path.strip('/').replace('/', '-')}.json"
        try:
            payload = json.loads(body or b"{}")
        except json.JSONDecodeError:
            payload = {"raw": body.decode(errors="replace")}
        (server.directory / name).write_text(json.dumps({"path": self.path, "body": payload}, indent=2))
        if self.path.endswith("/bench"):
            self.reply({"id": f"dry-run-{server.count}", "dryRun": True})
        else:
            title = payload.get("title", "") if isinstance(payload, dict) else ""
            self.reply({"dryRun": True, "title": title, "body": payload.get("body", "") if isinstance(payload, dict) else "",
                        "labels": payload.get("labels", []) if isinstance(payload, dict) else []})


# ---------------------------------------------------------------- the owner's state

def owner_state() -> dict:
    """What a run must not touch: the owner's Redlamp files, caches and preferences."""
    state: dict[str, str] = {}
    for root in [HOME / "Library/Application Support/Redlamp", HOME / "Library/Caches/app.redlamp"]:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            try:
                stat = path.stat()
            except OSError:
                continue
            if path.is_file():
                state[str(path)] = f"{stat.st_size}:{int(stat.st_mtime)}"
    prefs = subprocess.run(["defaults", "export", "app.redlamp.mac", "-"], capture_output=True).stdout
    state["defaults app.redlamp.mac"] = str(hash(prefs))
    return state


def owner_app_running() -> bool:
    """Whether a Redlamp other than the test app runs: the app, or the command-line tool, which
    shares the owner's caches (another session's renders, say)."""
    out = subprocess.run(["pgrep", "-fl", r"Redlamp\.app/Contents/MacOS/Redlamp|/redlamp( |$)"],
                         capture_output=True, text=True).stdout
    return any(NAME not in line for line in out.splitlines() if line.strip())


# ---------------------------------------------------------------- one launch

def crash_reports(since: float) -> list[Path]:
    folder = HOME / "Library/Logs/DiagnosticReports"
    found = []
    try:
        entries = list(folder.iterdir())
    except OSError:
        return found
    for path in entries:
        if not path.name.startswith(("Redlamp", "RedlampDecoder")):
            continue
        try:
            if path.stat().st_mtime >= since and BUNDLE_ID in path.read_text(errors="replace")[:2000]:
                found.append(path)
        except OSError:
            continue
    return found


def known_issues() -> dict[str, str]:
    path = ROOT / "tests/e2e/known-issues.json"
    if not path.exists():
        return {}
    return {item["step"]: item["reason"] for item in json.loads(path.read_text())["knownIssues"]}


def known_stalls() -> dict[str, str]:
    path = ROOT / "tests/e2e/known-issues.json"
    if not path.exists():
        return {}
    return {item["frame"]: item["reason"] for item in json.loads(path.read_text()).get("knownStalls", [])}


def foreign_keys(run_dir: Path) -> dict[str, int]:
    """Keys typed on this Mac that reached the test app, which it kept out of the run, by the scenario running then:
    a menu the app opens takes the keyboard while it tracks, even in the background."""
    counts: dict[str, int] = {}
    for path in sorted(run_dir.glob("events-*.jsonl")):
        for event in read_events(path):
            if event.get("event") == "foreign-input" and event.get("type") == "keyDown":
                scenario = event.get("scenario") or "between scenarios"
                counts[scenario] = counts.get(scenario, 0) + 1
    return counts


def read_events(path: Path, start: int = 0) -> list[dict]:
    """The events in `path` from byte `start`: where a launch began adding its own to its group's."""
    if not path.exists():
        return []
    with path.open("rb") as handle:
        handle.seek(start)
        text = handle.read().decode(errors="replace")
    events = []
    for line in text.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def launch(app: Path, run_dir: Path, group: str, scenarios: list[str], args) -> dict:
    """Runs `scenarios` in one launch of the app and returns what happened."""
    plan = {"scenarios": scenarios, "focus": args.focus, "seed": args.seed, "photos": str(run_dir / "photos"),
            "steps": args.step, "knownIssues": known_issues(), "knownStalls": known_stalls()}
    (run_dir / f"plan-{group}.json").write_text(json.dumps(plan, indent=2))
    events_path = run_dir / f"events-{group}.jsonl"
    # Each launch of a group adds to the group's events; this one's begin here.
    start = events_path.stat().st_size if events_path.exists() else 0
    already = 0
    env = dict(os.environ)
    env["CFFIXED_USER_HOME"] = str(run_dir / "home")
    env["REDLAMP_E2E_SOAK_SECONDS"] = str(args.soak_seconds)
    if args.validation:
        env["MTL_DEBUG_LAYER"] = "1"
    command = [str(app / "Contents/MacOS/Redlamp")]
    if group != "relaunch":
        command.append(str(run_dir / "photos"))
    command += ["--e2e", str(run_dir), "--e2e-launch", group]
    started = time.time()
    with (run_dir / f"app-{group}.log").open("a") as output:
        process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    deadline = started + 120
    current = None
    timed_out = None
    global OTHER_REDLAMP_SEEN
    while process.poll() is None:
        time.sleep(0.5)
        if not OTHER_REDLAMP_SEEN and owner_app_running():
            OTHER_REDLAMP_SEEN = True
        events = read_events(events_path, start)[already:]
        for event in events:
            # Any event is progress; a walk gets its own length on top.
            deadline = max(deadline, time.time() + args.timeout)
            if event.get("event") == "scenario-start":
                current = event.get("scenario")
                deadline = time.time() + args.timeout + (args.soak_seconds if str(current).startswith("soak.") else 0)
            elif event.get("event") == "scenario-end":
                current = None
                deadline = time.time() + 120
            elif event.get("event") == "launch-end":
                deadline = time.time() + 30
        already += len(events)
        if time.time() > deadline:
            timed_out = current or "(between scenarios)"
            log(f"{group}: no progress before the deadline in {timed_out}; stopping the app")
            os.killpg(process.pid, signal.SIGTERM)
            time.sleep(3)
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            break
    process.wait()
    # ReportCrash takes a few seconds to write its report.
    time.sleep(1.5 if process.returncode == 0 else 6)
    return {"returncode": process.returncode, "timedOut": timed_out, "crashes": crash_reports(started),
            "seconds": time.time() - started, "events": start}


def outcomes(run_dir: Path, group: str, start: int = 0) -> tuple[dict[str, dict], list[dict], str | None]:
    """Each scenario's last result in the launch of `group` whose events begin at byte `start`, its hangs, and a
    scenario it left unfinished."""
    results: dict[str, dict] = {}
    hangs = []
    open_scenario = None
    for event in read_events(run_dir / f"events-{group}.jsonl", start):
        kind = event.get("event")
        if kind == "scenario-start":
            open_scenario = event.get("scenario")
        elif kind == "scenario-end":
            results[event["scenario"]] = event
            open_scenario = None
        elif kind == "hang":
            frames = known_stalls()
            if not any(frame in entry for entry in event.get("stack", []) for frame in frames):
                hangs.append(event)
    return results, hangs, open_scenario


class Launches:
    """A run's launches and what they found: each scenario's latest result and its count of attempts, the crash
    reports, and the main-thread stalls, each launch's once, marked with the attempt they belong to. A scenario
    run again is judged on its new attempt, so the stalls of the attempt before move to `retried_hangs`, which
    the report lists and the verdict doesn't count."""

    def __init__(self, run_dir: Path, start: Callable[[str, list[str]], dict], timeout: float):
        self.run_dir = run_dir
        self.start = start
        self.timeout = timeout
        self.results: dict[str, dict] = {}
        self.attempts: dict[str, int] = {}
        self.hangs: list[dict] = []
        self.retried_hangs: list[dict] = []
        self.crashes: list[str] = []

    def run_group(self, group: str, ids: list[str], attempt: int = 1) -> bool:
        """Runs `ids` in launches of `group`, as attempt `attempt` of each; returns whether each got a result."""
        remaining = ids
        tries = 0
        while remaining and tries < 4:
            tries += 1
            log(f"Launch '{group}': {len(remaining)} scenario(s)")
            outcome = self.start(group, remaining)
            group_results, group_hangs, unfinished = outcomes(self.run_dir, group, outcome["events"])
            for path in outcome["crashes"]:
                target = self.run_dir / "crashes" / path.name
                target.parent.mkdir(exist_ok=True)
                shutil.copy(path, target)
                self.crashes.append(str(target))
            stopped = unfinished or outcome["timedOut"]
            if stopped and stopped in ids:
                if outcome["timedOut"]:
                    why = f"made no progress for {self.timeout:.0f} s and was stopped"
                elif outcome["crashes"] or (outcome["returncode"] or 0) not in (0,):
                    why = f"crashed (exit {outcome['returncode']})"
                else:
                    why = "quit"
                group_results[stopped] = {"status": "failed", "message": f"The app {why} during this scenario"}
            judged = {i for i in remaining if i in group_results}
            self.retried_hangs += [h for h in self.hangs if h.get("scenario") in judged]
            self.hangs = [h for h in self.hangs if h.get("scenario") not in judged] + \
                [dict(h, attempt=attempt) for h in group_hangs]
            for scenario_id in remaining:
                if scenario_id in group_results:
                    self.attempts[scenario_id] = self.attempts.get(scenario_id, 0) + 1
                    previous = self.results.get(scenario_id)
                    result = group_results[scenario_id]
                    if previous and previous["status"] == "failed" and result["status"] == "passed":
                        result = dict(result, status="flaky", message=f"passed on retry; first: {previous.get('message', '')}")
                    self.results[scenario_id] = result
            # Scenarios a launch didn't reach (it stopped, or a dialog wouldn't close) run in a fresh one.
            remaining = [i for i in remaining if i not in group_results]
            if outcome["returncode"] not in (0, None) and not stopped and not outcome["timedOut"]:
                log(f"{group}: the app exited with {outcome['returncode']}")
        return not remaining


def later_launches(main: list[str], relaunch: list[str], retry: list[str]) -> list[tuple[str, list[str], bool]]:
    """The launches after the main group's, and whether each starts afresh: the relaunch group, and a fresh one
    retrying the main group's failures. The retry starts from what the first attempt started from
    (`start_afresh`), not from what it left. The relaunch group reopens what the main group's last scenario
    leaves (smoke.leave-an-edit's photo and edit), so it follows the launch that last ran that scenario: the
    retry when that scenario is retried, and otherwise the main group's own, before the retry starts afresh."""
    relaunched = [("relaunch", relaunch, False)] if relaunch else []
    retried = [("main", retry, True)] if retry else []
    if main and main[-1] in retry:
        return retried + relaunched
    return relaunched + retried


# ---------------------------------------------------------------- performance

def wait_for_quiet(limit: float) -> tuple[bool, float]:
    """Waits up to `limit` seconds for the load average to fall to QUIET_LOAD or below."""
    deadline = time.time() + limit
    current = load()
    while current > QUIET_LOAD and time.time() < deadline:
        log(f"The Mac is busy (load average {current:.1f}); waiting for it to be quiet before measuring")
        time.sleep(30)
        current = load()
    return current <= QUIET_LOAD, current


def judge_performance(run_dir: Path, quiet: bool) -> dict:
    """The run's metrics against tests/e2e/budgets.json; a busy run is measured but not judged."""
    metrics_path = run_dir / "metrics.json"
    metrics = json.loads(metrics_path.read_text()) if metrics_path.exists() else {}
    for event in read_events(run_dir / "events-performance.jsonl"):
        if event.get("event") == "ready" and "e2e-launch" not in metrics:
            metrics["e2e-launch"] = event.get("seconds", 0) * 1000
    metrics_path.write_text(json.dumps(metrics, indent=2, sort_keys=True))
    budgets = json.loads((ROOT / "tests/e2e/budgets.json").read_text())["budgets"]
    over = []
    for metric, budget in budgets.items():
        value = metrics.get(metric)
        if value is None:
            over.append(f"{metric} wasn't measured")
        elif "max" in budget and value > budget["max"]:
            over.append(f"{metric} {value:.1f}, over its budget of {budget['max']}")
        elif "min" in budget and value < budget["min"]:
            over.append(f"{metric} {value:.1f}, under its floor of {budget['min']}")
    return {"metrics": metrics, "quiet": quiet, "over": over, "judged": quiet}


# ---------------------------------------------------------------- the report

def coverage(run_dir: Path, catalogue: dict, ran: set[str]) -> dict:
    claims: dict[str, set[str]] = {}
    menu_items: set[str] = set()
    for path in run_dir.glob("coverage-*.json"):
        data = json.loads(path.read_text())
        for claim, paths in data.get("claims", {}).items():
            claims.setdefault(claim, set()).update(paths)
        menu_items.update(data.get("menuItems", []))
    exemptions = json.loads((ROOT / "tests/e2e/exemptions.json").read_text())["exemptions"]
    exempt = {item["claim"]: item["reason"] for item in exemptions}
    # Every required claim has a scenario (the contract tests check that); a run is judged on
    # the claims of the scenarios it ran.
    claimed = {claim for scenario in catalogue["scenarios"] if scenario["id"] in ran for claim in scenario["claims"]}
    required = catalogue["required"]
    missing = [claim for claim in required if claim in claimed and claim not in claims and claim not in exempt]
    return {
        "required": len(required),
        "covered": len([c for c in required if c in claims]),
        "exempt": len([c for c in required if c not in claims and c in exempt]),
        "missing": missing,
        "paths": {claim: sorted(paths) for claim, paths in sorted(claims.items())},
        "menuItems": sorted(menu_items),
    }


def stall_line(hang: dict, attempt: bool = False) -> str:
    """A stall in the report: its scenario, with its attempt when asked or after the first, its length and stack."""
    stack = " ← ".join(hang.get("stack", [])[:8])
    which = f" (attempt {hang.get('attempt', 1)})" if attempt or hang.get("attempt", 1) > 1 else ""
    return f"- {hang.get('scenario', '?')}{which}: {hang.get('seconds', 0):.1f} s at {stack}"


def write_report(run_dir: Path, report: dict) -> None:
    (run_dir / "report.json").write_text(json.dumps(report, indent=2, default=str))
    lines = [
        f"# Regression suite: {report['tier']} at {report['commit']}{' (uncommitted changes)' if report['dirty'] else ''}",
        "",
        f"**{report['verdict']}.** {report['summary']}",
        "",
        f"Started {report['started']}, took {report['seconds'] / 60:.1f} min on {report['machine']}, "
        f"load average {report['load']['before']:.1f} before and {report['load']['after']:.1f} after.",
        "",
        "| Scenario | Result | Time | Main thread p99 | Notes |",
        "| --- | --- | --- | --- | --- |",
    ]
    for item in report["scenarios"]:
        p99 = f"{item['mainP99ms']:.1f} ms" if item.get("mainP99ms") is not None else ""
        note = (item.get("message") or "").replace("|", "/").replace("\n", " ")
        if len(note) > 400:
            note = note[:400] + "…"
        lines.append(f"| `{item['id']}` | {item['status']} | {item.get('seconds', 0):.1f} s | {p99} | {note} |")
    if report["crashes"]:
        lines += ["", "## Crashes", ""] + [f"- `{path}`" for path in report["crashes"]]
    retried = report.get("retriedHangs", [])
    if report["hangs"] or retried:
        lines += ["", "## Main-thread stalls", ""] + [stall_line(hang) for hang in report["hangs"]]
        if retried:
            lines += ["", "In attempts a retry replaced, so they don't count against the run:", ""]
            lines += [stall_line(hang, attempt=True) for hang in retried]
    cover = report.get("coverage")
    if cover:
        lines += ["", "## Coverage", "",
                  f"{cover['covered']} of {cover['required']} claims exercised, {cover['exempt']} exempt with a reason, "
                  f"{len(cover['missing'])} missing."]
        if cover["missing"] and report["coverageRequired"]:
            lines += [""] + [f"- `{claim}`" for claim in cover["missing"]]
    perf = report.get("performance")
    if perf:
        lines += ["", "## Performance", ""]
        if not perf["judged"]:
            lines.append(f"Measured on a busy Mac, so the budgets weren't judged{': accepted by ' + perf['accepted'] if perf.get('accepted') else ''}.")
        elif perf["over"]:
            lines += [f"- {item}" for item in perf["over"]]
        else:
            lines.append("Every metric is within its budget.")
        lines += ["", "| Metric | Value |", "| --- | --- |"] + [f"| `{k}` | {v:.1f} |" for k, v in sorted(perf["metrics"].items())]
    state = report["ownerState"]
    lines += ["", "## Isolation", "", state["summary"]]
    typed = report.get("foreignKeys") or {}
    if typed:
        where = ", ".join(f"{count} in `{scenario}`" for scenario, count in sorted(typed.items()))
        lines += ["", f"Keys typed on this Mac reached the app and were kept out of the run: {where}."]
    storage = report.get("storage")
    if storage:
        change = storage["temporaryFreeChange"] / 2**30
        lines += ["", "## Storage", "",
                  f"The test home holds {storage['home'] / 2**20:.0f} MB. Free space on the temporary folder's disk "
                  f"changed by {change:+.2f} GB over the run (other work on the Mac counts too)."]
        lines += [""] + [f"- `{k}`: {v / 2**20:.0f} MB" for k, v in storage["sizes"].items()]
        if storage["problems"]:
            lines += ["", "Problems:", ""] + [f"- {item}" for item in storage["problems"]]
    if report.get("relay"):
        lines += ["", f"The stub relay received {report['relay']} request(s); see `relay/`."]
    (run_dir / "report.md").write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------- the signed app, as a black box

def blackbox(release: Path, run_dir: Path, update: bool) -> int:
    """Checks the signed app as it ships, with no driver in it: it carries none of the
    driver's code, a copy of it opens photos and quits cleanly, its CLI renders, and Sparkle
    updates an older copy to it."""
    run_dir.mkdir(parents=True, exist_ok=True)
    checks: list[tuple[str, bool, str]] = []

    def check(name: str, passed: bool, detail: str = "") -> None:
        checks.append((name, passed, detail))
        log(f"{'ok  ' if passed else 'FAIL'} {name}{': ' + detail if detail else ''}")

    verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(release)], capture_output=True, text=True)
    check("the signature verifies", verify.returncode == 0, verify.stderr.strip())

    framework = release / "Contents/Frameworks/RedlampAutomation.framework/RedlampAutomation"
    if framework.exists():
        symbols = subprocess.run(["nm", "-U", str(framework)], capture_output=True, text=True).stdout
        leaked = [line for line in symbols.splitlines() if "Scenario" in line or "Catalogue" in line or "RunningApp" in line]
        check("it carries none of the driver's code", not leaked, f"{len(leaked)} driver symbols" if leaked else "")
    else:
        check("it carries none of the driver's code", True, "no RedlampAutomation framework")
    main_binary = release / "Contents/MacOS/Redlamp"
    strings = subprocess.run(["strings", str(main_binary)], capture_output=True, text=True).stdout
    check("the app has no driver entry point", "--e2e-launch" not in strings)

    # A copy under its own bundle ID, so the owner's preferences stay as they are.
    copy_dir = run_dir / "app"
    copy_dir.mkdir(exist_ok=True)
    app = copy_dir / "Redlamp.app"
    run(["ditto", str(release), str(app)])
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    bundle = "app.redlamp.mac.e2e-release"
    info["CFBundleIdentifier"] = bundle
    info["SUFeedURL"] = ""
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)
    identity = signing_identity(release)
    # Its own requirements, as in make_test_copy.
    subprocess.run(["codesign", "--force", "--options", "runtime", "--sign", identity,
                    "--preserve-metadata=entitlements,flags", "--timestamp=none", str(app)],
                   capture_output=True)
    defaults("delete", bundle)
    defaults("write", bundle, "welcome.shown", "-int", "99")
    home = run_dir / "home"
    home.mkdir(exist_ok=True)
    photos = run_dir / "photos"
    if not photos.exists():
        prepare_photos(photos)
    started = time.time()
    with (run_dir / "app.log").open("w") as output:
        process = subprocess.Popen([str(app / "Contents/MacOS/Redlamp"), str(photos)],
                                   env=dict(os.environ, CFFIXED_USER_HOME=str(home)),
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(20)
    alive = process.poll() is None
    check("it opens the photos and stays up for 20 s", alive, "" if alive else f"exited with {process.returncode}")
    windows = subprocess.run(["swift", str(ROOT / "scripts/window-id.swift"), str(process.pid)],
                             capture_output=True, text=True)
    check("it shows its window", windows.returncode == 0 and windows.stdout.strip() != "", windows.stderr.strip()[:200])
    if alive:
        asked = subprocess.run(["osascript", "-l", "JavaScript", "-e",
                                "ObjC.import('AppKit'); "
                                f"$.NSRunningApplication.runningApplicationWithProcessIdentifier({process.pid}).terminate"],
                               capture_output=True, text=True).stdout.strip()
        how = "a quit Apple event"
        if asked != "true":
            # Where Apple events to the app are refused (an agent's sandbox), SIGTERM stands in;
            # the suite's own launches quit through the app's applicationShouldTerminate.
            how = "SIGTERM, since Apple events to the app were refused here"
            os.kill(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        clean = process.returncode == 0 or (asked != "true" and process.returncode == -signal.SIGTERM)
        check("it quits when asked", clean, f"by {how}, exit {process.returncode}")
    time.sleep(6)
    crashes = [p for p in crash_reports_for(started, bundle)]
    check("no crash report", not crashes, ", ".join(p.name for p in crashes))
    defaults("delete", bundle)

    cli = release / "Contents/Helpers/redlamp"
    rendered = run_dir / "cli-render.jpg"
    sample = next(p for p in sorted(photos.iterdir()) if p.suffix.upper() in (".ARW", ".NEF", ".RAF", ".CR3"))
    render = subprocess.run([str(cli), "render", str(sample), "-o", str(rendered), "--size", "512"],
                            capture_output=True, text=True, timeout=300)
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(rendered)], capture_output=True, text=True)
    check("the bundled CLI renders a photo", render.returncode == 0 and "512" in size.stdout,
          (render.stderr or size.stdout).strip()[:200])

    if update:
        result = subprocess.run([str(ROOT / "scripts/test-update.sh"), "--auto"], capture_output=True, text=True,
                                timeout=900)
        (run_dir / "test-update.log").write_text(result.stdout + result.stderr)
        check("Sparkle updates an older copy to it", result.returncode == 0,
              "" if result.returncode == 0 else (result.stdout + result.stderr).strip().splitlines()[-1][:200])

    failed = [name for name, passed, _ in checks if not passed]
    (run_dir / "blackbox.json").write_text(json.dumps(
        {"app": str(release), "checks": [{"name": n, "passed": p, "detail": d} for n, p, d in checks]}, indent=2))
    log(f"Black box: {len(checks) - len(failed)} of {len(checks)} checks passed" + (f"; failed: {', '.join(failed)}" if failed else ""))
    return 1 if failed else 0


def crash_reports_for(since: float, bundle: str) -> list[Path]:
    folder = HOME / "Library/Logs/DiagnosticReports"
    found = []
    try:
        entries = list(folder.iterdir())
    except OSError:
        return found
    for path in entries:
        try:
            if path.name.startswith("Redlamp") and path.stat().st_mtime >= since \
                    and f'"bundleID":"{bundle}"' in path.read_text(errors="replace")[:2000]:
                found.append(path)
        except OSError:
            continue
    return found


def passing_report(commits: list[str], tier: str) -> Path | None:
    """A passing report for one of `commits` at `tier` or a tier that includes it."""
    includes = {"smoke": {"smoke", "full", "release"}, "full": {"full", "release"}, "release": {"release"}}
    for report in sorted((ROOT / "build/e2e").glob("*/report.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            data = json.loads(report.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("verdict") == "Passed" and not data.get("dirty") and data.get("tier") in includes.get(tier, {tier}) \
                and any(c.startswith(data.get("commit", "-")) or data.get("commit", "-").startswith(c[:7]) for c in commits):
            return report
    return None


# ---------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tier", default="smoke", choices=["smoke", "full", "soak", "performance", "release"])
    parser.add_argument("--scenario", action="append", default=[], help="run only these scenarios")
    parser.add_argument("--step", action="append", default=[], help="within them, only steps whose names contain this")
    parser.add_argument("--app", type=Path, help="a test app already built (with the driver compiled in)")
    parser.add_argument("--build", choices=["debug", "qa"], help="what to build (default: qa for release, else debug)")
    parser.add_argument("--focus", action="store_true", help="let scenarios that need a key window take focus")
    parser.add_argument("--seed", type=int, default=int(time.time()) % 100000)
    parser.add_argument("--timeout", type=float, default=SCENARIO_TIMEOUT, help="seconds a scenario may take")
    parser.add_argument("--no-validation", dest="validation", action="store_false", help="Metal's validation layer off")
    parser.add_argument("--out", type=Path, help="the run directory (default build/e2e/<commit>-<time>)")
    parser.add_argument("--blackbox", type=Path, metavar="APP", help="check a signed release app as a black box instead")
    parser.add_argument("--quiet-wait", type=float, default=900, help="seconds to wait for a quiet Mac before measuring")
    parser.add_argument("--accept-busy", action="store_true", help="accept performance measured on a busy Mac, unjudged")
    parser.add_argument("--record", action="store_true", help="append the performance run to docs/performance/history.jsonl")
    parser.add_argument("--soak-seconds", type=float, default=300, help="how long the soak tier walks")
    parser.add_argument("--replay", type=Path, help="a soak run's soak-steps.jsonl to walk again, step for step")
    parser.add_argument("--no-update", dest="update", action="store_false", help="with --blackbox: skip the Sparkle update")
    parser.add_argument("--passing-report", nargs="+", metavar="COMMIT",
                        help="print a passing report for one of these commits at --tier, if there is one, and exit 0")
    args = parser.parse_args()
    # The app and its driver are handed paths in the run directory: a relative one becomes a URL relative to the
    # working directory, which isn't equal to the absolute URL the app has elsewhere for the same folder or photo.
    if args.out:
        args.out = args.out.resolve()

    if args.passing_report:
        report = passing_report(args.passing_report, args.tier)
        if report:
            print(report)
            return 0
        return 1
    if args.blackbox:
        sha, _ = commit()
        out = args.out or ROOT / "build/e2e" / f"{sha}-blackbox-{dt.datetime.now():%Y%m%d-%H%M%S}"
        return blackbox(args.blackbox.resolve(), out, args.update)

    sha, dirty = commit()
    started = dt.datetime.now().astimezone()
    run_dir = args.out or ROOT / "build/e2e" / f"{sha}-{started:%Y%m%d-%H%M%S}"
    run_dir.mkdir(parents=True, exist_ok=False)
    # A click on a SwiftUI button doesn't arrive while every display is asleep or the screen is locked:
    # keep the displays awake for the whole run, as the capture scripts do.
    subprocess.Popen(["caffeinate", "-u", "-d", "-w", str(os.getpid())])
    if screen_locked():
        log("The screen is locked: clicks on SwiftUI's buttons won't arrive until it's unlocked, "
            "so the scenarios that make them will fail")
    tier = args.tier
    if tier == "performance":
        args.validation = False

    built = args.app or build(args.build or ("qa" if tier in ("release", "performance") else "debug"))
    app = make_test_copy(built, ROOT / "build/e2e")

    home = run_dir / "home"
    home.mkdir()
    if args.replay:
        shutil.copy(args.replay, run_dir / "soak-replay.jsonl")
    seed_models(home)
    photos = prepare_photos(run_dir / "originals")
    copy_photos(run_dir / "originals", run_dir / "photos")
    relay = Relay(run_dir / "relay")
    threading.Thread(target=relay.serve_forever, daemon=True).start()
    seed_defaults(relay.server_address[1])
    compiles_before = temporary_compiles()
    free_before = free_bytes(Path(tempfile.gettempdir()))
    owner_before = owner_state()
    owner_running = owner_app_running()
    load_before = load()

    catalogue_path = run_dir / "catalogue.json"
    subprocess.run([str(app / "Contents/MacOS/Redlamp"), "--e2e-list", str(catalogue_path)],
                   env=dict(os.environ, CFFIXED_USER_HOME=str(home)), capture_output=True, timeout=60)
    if not catalogue_path.exists():
        sys.exit("the test app didn't write its catalogue (is the driver compiled in?)")
    catalogue = json.loads(catalogue_path.read_text())
    tiers = {"release": {"full", "soak"}}.get(tier, {tier})
    performance_ids = [s["id"] for s in catalogue["scenarios"] if "performance" in s["tiers"]] \
        if tier in ("performance", "release") and not args.scenario else []
    if tier == "performance":
        tiers = set()
    chosen = [s for s in catalogue["scenarios"]
              if (s["id"] in args.scenario if args.scenario else tiers & set(s["tiers"]))]
    if not chosen and not performance_ids:
        sys.exit("no scenarios chosen")
    log(f"{len(chosen)} scenarios, {len(photos)} photos, seed {args.seed}, run directory {run_dir}")

    launches = Launches(run_dir, lambda group, ids: launch(app, run_dir, group, ids, args), args.timeout)
    main_ids = [s["id"] for s in chosen if s["group"] == "main"]
    relaunch_ids = [s["id"] for s in chosen if s["group"] == "relaunch"]
    retry = []
    if launches.run_group("main", main_ids):
        # One retry, in a fresh app, for what failed (not the relaunch group, whose state is spent).
        retry = [i for i in main_ids
                 if launches.results.get(i, {}).get("status") == "failed" and launches.attempts.get(i, 0) < 2]
    earlier: list[str] = []
    for group, ids, afresh in later_launches(main_ids, relaunch_ids, retry):
        if afresh:
            log("Starting the retry as the first attempt started: the photos, the home and the defaults afresh")
            earlier += start_afresh(run_dir, relay.server_address[1], attempt=2)
        launches.run_group(group, ids, attempt=2 if afresh else 1)
    results, attempts, hangs, crashes = launches.results, launches.attempts, launches.hangs, launches.crashes

    performance = None
    if performance_ids:
        quiet, current = wait_for_quiet(args.quiet_wait)
        validation, args.validation = args.validation, False
        log(f"Performance: {len(performance_ids)} scenario(s), load average {current:.1f}")
        launch(app, run_dir, "performance", performance_ids, args)
        args.validation = validation
        perf_results, perf_hangs, _ = outcomes(run_dir, "performance")
        hangs += perf_hangs
        for scenario_id in performance_ids:
            results[scenario_id] = perf_results.get(scenario_id, {"status": "failed", "message": "never ran"})
        quiet = quiet and load() <= QUIET_LOAD
        performance = judge_performance(run_dir, quiet)
        if not quiet:
            if args.accept_busy:
                performance["accepted"] = "--accept-busy"
            elif sys.stdin.isatty():
                answer = input(f"The Mac was busy while measuring, so the budgets can't be judged. Accept? [y/N] ")
                if answer.strip().lower().startswith("y"):
                    performance["accepted"] = "the owner, at the prompt"
        if args.record:
            subprocess.run([str(ROOT / "scripts/perf-history.py"), "append", "--e2e", str(run_dir / "metrics.json"),
                            "--source", "e2e", "--load-before", f"{load_before:.2f}", "--load-after", f"{load():.2f}"])
        chosen += [s for s in catalogue["scenarios"] if s["id"] in performance_ids]

    relay.shutdown()
    load_after = load()
    owner_after = owner_state()
    changed = sorted(k for k in set(owner_before) | set(owner_after) if owner_before.get(k) != owner_after.get(k))
    if not changed:
        state_summary = "The owner's Redlamp files, caches and preferences are as they were before the run."
    elif owner_running or OTHER_REDLAMP_SEEN or owner_app_running():
        state_summary = (f"{len(changed)} of the owner's Redlamp files or preferences changed, but another Redlamp "
                         "ran during the run, so the change may be its own: " + ", ".join(changed[:5]))
    else:
        state_summary = f"The run changed {len(changed)} of the owner's Redlamp files or preferences: " + ", ".join(changed[:10])
    isolation_failed = bool(changed) and not (owner_running or OTHER_REDLAMP_SEEN or owner_app_running())

    cover = coverage(run_dir, catalogue, {s["id"] for s in chosen})
    coverage_required = tier in ("full", "release") and not args.scenario
    scenarios = []
    by_id = {s["id"]: s for s in chosen}
    for scenario_id, info in by_id.items():
        result = results.get(scenario_id, {"status": "failed", "message": "never ran"})
        scenarios.append({"id": scenario_id, "title": info["title"], "status": result["status"],
                          "seconds": result.get("seconds", 0), "message": result.get("message"),
                          "snapshot": result.get("snapshot"), "mainP99ms": result.get("mainP99ms"),
                          "footprintMB": result.get("footprintMB"), "attempts": attempts.get(scenario_id, 0)})
    for item in scenarios:
        if item["id"].startswith("soak.") and item["status"] == "failed":
            item["message"] = (f"{item.get('message') or ''} (seed {args.seed}; replay with "
                               f"--replay {run_dir / 'soak-steps.jsonl'})")
    failed = [s for s in scenarios if s["status"] == "failed"]
    flaky = [s for s in scenarios if s["status"] == "flaky"]
    skipped = [s for s in scenarios if s["status"] == "skipped"]
    problems = []
    if failed:
        problems.append(f"{len(failed)} failed")
    if crashes:
        problems.append(f"{len(crashes)} crash report(s)")
    if hangs:
        problems.append(f"{len(hangs)} main-thread stall(s)")
    if coverage_required and cover["missing"]:
        problems.append(f"{len(cover['missing'])} claim(s) not covered")
    if isolation_failed:
        problems.append("the run changed the owner's state")
    storage = storage_check(home, compiles_before, free_before, earlier)
    if storage["problems"]:
        problems.append(f"{len(storage['problems'])} storage problem(s)")
    if performance and performance["judged"] and performance["over"]:
        problems.append(f"{len(performance['over'])} performance budget(s) missed")
    if performance and not performance["judged"] and not performance.get("accepted"):
        problems.append("performance was measured on a busy Mac and not accepted")
    passed = len([s for s in scenarios if s["status"] == "passed"])
    summary = f"{passed} passed, {len(flaky)} flaky, {len(skipped)} skipped, {len(failed)} failed of {len(scenarios)}."
    report = {
        "format": "app.redlamp.e2e-report", "tier": tier, "commit": sha, "dirty": dirty,
        "started": started.isoformat(timespec="seconds"), "seconds": (dt.datetime.now().astimezone() - started).total_seconds(),
        "machine": f"{platform.machine()} macOS {platform.mac_ver()[0]}", "load": {"before": load_before, "after": load_after},
        "noisy": max(load_before, load_after) > QUIET_LOAD, "app": str(built), "seed": args.seed,
        "verdict": "Failed: " + ", ".join(problems) if problems else "Passed",
        "summary": summary, "scenarios": scenarios, "crashes": crashes, "hangs": hangs,
        "retriedHangs": launches.retried_hangs, "coverage": cover, "coverageRequired": coverage_required,
        "ownerState": {"changed": changed, "ownerAppRunning": owner_running, "summary": state_summary},
        "relay": relay.count, "performance": performance, "storage": storage, "foreignKeys": foreign_keys(run_dir),
    }
    write_report(run_dir, report)
    defaults("delete", BUNDLE_ID)
    keep_compiled_models(home)
    prune_runs()
    log(f"{report['verdict']}. {summary}")
    log(f"Report: {run_dir / 'report.md'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
