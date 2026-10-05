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
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "app.redlamp.mac.e2e"
NAME = "Redlamp E2E"
GROUPS = ["main", "relaunch"]
SCENARIO_TIMEOUT = 300
QUIET_LOAD = 8.0
HOME = Path.home()


def log(message: str) -> None:
    print(f"==> {message}", flush=True)


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
    run(["codesign", "--force", "--sign", identity, "--preserve-metadata=entitlements,requirements,flags",
         "--timestamp=none", str(app)], capture_output=True)
    run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
    return app


# ---------------------------------------------------------------- the run's home

def prepare_photos(photos: Path) -> list[str]:
    """APFS clones of the sample raws, a JPEG and the bitmaps made from it."""
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
    jpeg = ROOT / "tests/golden/process/DSC_0750.jpg"
    run(["cp", "-c", str(jpeg), str(photos / "Bitmap.jpg")])
    for extension, kind in [("png", "png"), ("tif", "tiff"), ("heic", "heic")]:
        subprocess.run(["sips", "-s", "format", kind, str(jpeg), "--out", str(photos / f"Bitmap.{extension}")],
                       capture_output=True)
    return sorted(p.name for p in photos.iterdir() if not p.name.startswith("."))


def seed_models(home: Path) -> None:
    """Clones of the models already downloaded, so no scenario downloads one."""
    owner = HOME / "Library/Application Support/Redlamp/Models"
    if owner.is_dir():
        target = home / "Library/Application Support/Redlamp"
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-cR", str(owner), str(target)], capture_output=True)


def defaults(*arguments: str) -> None:
    subprocess.run(["defaults", *arguments], capture_output=True)


def seed_defaults(relay: int) -> None:
    defaults("delete", BUNDLE_ID)
    defaults("write", BUNDLE_ID, "welcome.shown", "-int", "99")
    defaults("write", BUNDLE_ID, "FeedbackEndpoint", f"http://127.0.0.1:{relay}/api/feedback")
    defaults("write", BUNDLE_ID, "CameraBenchEndpoint", f"http://127.0.0.1:{relay}/api/bench")
    defaults("write", BUNDLE_ID, "feedback.noteAccepted", "-int", "1")
    # The Export dialog opens on these; Show in Finder after export would bring Finder forward.
    previous = json.dumps({"revealInFinder": False, "existingFiles": "keepBoth"}).encode().hex()
    defaults("write", BUNDLE_ID, "exportPrevious", "-data", previous)


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
    out = subprocess.run(["pgrep", "-fl", "Redlamp.app/Contents/MacOS/Redlamp"], capture_output=True, text=True).stdout
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


def read_events(path: Path) -> list[dict]:
    if not path.exists():
        return []
    events = []
    for line in path.read_text().splitlines():
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
    already = len(read_events(events_path))
    env = dict(os.environ)
    env["CFFIXED_USER_HOME"] = str(run_dir / "home")
    if args.validation:
        env["MTL_DEBUG_LAYER"] = "1"
    command = [str(app / "Contents/MacOS/Redlamp")]
    if group == "main":
        command.append(str(run_dir / "photos"))
    command += ["--e2e", str(run_dir), "--e2e-launch", group]
    started = time.time()
    with (run_dir / f"app-{group}.log").open("a") as output:
        process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    deadline = started + 120
    current = None
    timed_out = None
    while process.poll() is None:
        time.sleep(0.5)
        events = read_events(events_path)[already:]
        for event in events:
            if event.get("event") == "scenario-start":
                current = event.get("scenario")
                deadline = time.time() + args.timeout
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
            "seconds": time.time() - started}


def outcomes(run_dir: Path, group: str) -> tuple[dict[str, dict], list[dict], str | None]:
    """Each scenario's last result in this group, the hangs, and a scenario left unfinished."""
    results: dict[str, dict] = {}
    hangs = []
    open_scenario = None
    for event in read_events(run_dir / f"events-{group}.jsonl"):
        kind = event.get("event")
        if kind == "scenario-start":
            open_scenario = event.get("scenario")
        elif kind == "scenario-end":
            results[event["scenario"]] = event
            open_scenario = None
        elif kind == "hang":
            hangs.append(event)
    return results, hangs, open_scenario


# ---------------------------------------------------------------- the report

def coverage(run_dir: Path, catalogue: dict) -> dict:
    claims: dict[str, set[str]] = {}
    menu_items: set[str] = set()
    for path in run_dir.glob("coverage-*.json"):
        data = json.loads(path.read_text())
        for claim, paths in data.get("claims", {}).items():
            claims.setdefault(claim, set()).update(paths)
        menu_items.update(data.get("menuItems", []))
    exemptions = json.loads((ROOT / "tests/e2e/exemptions.json").read_text())["exemptions"]
    exempt = {item["claim"]: item["reason"] for item in exemptions}
    required = catalogue["required"]
    missing = [claim for claim in required if claim not in claims and claim not in exempt]
    return {
        "required": len(required),
        "covered": len([c for c in required if c in claims]),
        "exempt": len([c for c in required if c not in claims and c in exempt]),
        "missing": missing,
        "paths": {claim: sorted(paths) for claim, paths in sorted(claims.items())},
        "menuItems": sorted(menu_items),
    }


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
    if report["hangs"]:
        lines += ["", "## Main-thread stalls", ""]
        for hang in report["hangs"]:
            stack = " ← ".join(hang.get("stack", [])[:8])
            lines.append(f"- {hang.get('scenario', '?')}: {hang.get('seconds', 0):.1f} s at {stack}")
    cover = report.get("coverage")
    if cover:
        lines += ["", "## Coverage", "",
                  f"{cover['covered']} of {cover['required']} claims exercised, {cover['exempt']} exempt with a reason, "
                  f"{len(cover['missing'])} missing."]
        if cover["missing"] and report["coverageRequired"]:
            lines += [""] + [f"- `{claim}`" for claim in cover["missing"]]
    state = report["ownerState"]
    lines += ["", "## Isolation", "", state["summary"]]
    if report.get("relay"):
        lines += ["", f"The stub relay received {report['relay']} request(s); see `relay/`."]
    (run_dir / "report.md").write_text("\n".join(lines) + "\n")


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
    args = parser.parse_args()

    sha, dirty = commit()
    started = dt.datetime.now().astimezone()
    run_dir = args.out or ROOT / "build/e2e" / f"{sha}-{started:%Y%m%d-%H%M%S}"
    run_dir.mkdir(parents=True, exist_ok=False)
    tier = args.tier
    if tier == "performance":
        args.validation = False

    built = args.app or build(args.build or ("qa" if tier in ("release", "performance") else "debug"))
    app = make_test_copy(built, ROOT / "build/e2e")

    home = run_dir / "home"
    home.mkdir()
    seed_models(home)
    photos = prepare_photos(run_dir / "photos")
    relay = Relay(run_dir / "relay")
    threading.Thread(target=relay.serve_forever, daemon=True).start()
    seed_defaults(relay.server_address[1])
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
    chosen = [s for s in catalogue["scenarios"]
              if (s["id"] in args.scenario if args.scenario else tiers & set(s["tiers"]))]
    if not chosen:
        sys.exit("no scenarios chosen")
    log(f"{len(chosen)} scenarios, {len(photos)} photos, seed {args.seed}, run directory {run_dir}")

    results: dict[str, dict] = {}
    attempts: dict[str, int] = {}
    hangs: list[dict] = []
    crashes: list[str] = []
    retry_main: list[str] = []
    for group in GROUPS + ["retry"]:
        if group == "retry":
            # Retried last, so a retry never changes what the relaunch group expects to find.
            group, ids = "main", retry_main
        else:
            ids = [s["id"] for s in chosen if s["group"] == group]
        if not ids:
            continue
        remaining = ids
        tries = 0
        retrying = ids is retry_main
        while remaining and tries < 4:
            tries += 1
            log(f"Launch '{group}': {len(remaining)} scenario(s)")
            outcome = launch(app, run_dir, group, remaining, args)
            group_results, group_hangs, unfinished = outcomes(run_dir, group)
            hangs = [h for h in hangs if h.get("scenario") not in remaining] + group_hangs
            for path in outcome["crashes"]:
                target = run_dir / "crashes" / path.name
                target.parent.mkdir(exist_ok=True)
                shutil.copy(path, target)
                crashes.append(str(target))
            stopped = unfinished or outcome["timedOut"]
            if stopped and stopped in ids:
                if outcome["timedOut"]:
                    why = f"made no progress for {args.timeout:.0f} s and was stopped"
                elif outcome["crashes"] or (outcome["returncode"] or 0) not in (0,):
                    why = f"crashed (exit {outcome['returncode']})"
                else:
                    why = "quit"
                group_results[stopped] = {"status": "failed", "message": f"The app {why} during this scenario"}
            for scenario_id in remaining:
                if scenario_id in group_results:
                    attempts[scenario_id] = attempts.get(scenario_id, 0) + 1
                    previous = results.get(scenario_id)
                    result = group_results[scenario_id]
                    if previous and previous["status"] == "failed" and result["status"] == "passed":
                        result = dict(result, status="flaky", message=f"passed on retry; first: {previous.get('message', '')}")
                    results[scenario_id] = result
            done = [i for i in remaining if i in group_results]
            if stopped:
                # Scenarios after the one that stopped the app run in a fresh launch.
                remaining = [i for i in remaining if i not in group_results]
            else:
                remaining = []
            # One retry, in a fresh app, for what failed (not the relaunch group, whose state is spent).
            if not remaining and group == "main" and not retrying:
                retry_main = [i for i in ids if results.get(i, {}).get("status") == "failed" and attempts.get(i, 0) < 2]
            if outcome["returncode"] not in (0, None) and not stopped and not outcome["timedOut"]:
                log(f"{group}: the app exited with {outcome['returncode']}")

    relay.shutdown()
    load_after = load()
    owner_after = owner_state()
    changed = sorted(k for k in set(owner_before) | set(owner_after) if owner_before.get(k) != owner_after.get(k))
    if not changed:
        state_summary = "The owner's Redlamp files, caches and preferences are as they were before the run."
    elif owner_running or owner_app_running():
        state_summary = (f"{len(changed)} of the owner's Redlamp files or preferences changed, but the owner's own Redlamp "
                         "was running, so the change may be its own: " + ", ".join(changed[:5]))
    else:
        state_summary = f"The run changed {len(changed)} of the owner's Redlamp files or preferences: " + ", ".join(changed[:10])
    isolation_failed = bool(changed) and not (owner_running or owner_app_running())

    cover = coverage(run_dir, catalogue)
    coverage_required = tier in ("full", "release") and not args.scenario
    scenarios = []
    by_id = {s["id"]: s for s in chosen}
    for scenario_id, info in by_id.items():
        result = results.get(scenario_id, {"status": "failed", "message": "never ran"})
        scenarios.append({"id": scenario_id, "title": info["title"], "status": result["status"],
                          "seconds": result.get("seconds", 0), "message": result.get("message"),
                          "snapshot": result.get("snapshot"), "mainP99ms": result.get("mainP99ms"),
                          "footprintMB": result.get("footprintMB"), "attempts": attempts.get(scenario_id, 0)})
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
    passed = len([s for s in scenarios if s["status"] == "passed"])
    summary = f"{passed} passed, {len(flaky)} flaky, {len(skipped)} skipped, {len(failed)} failed of {len(scenarios)}."
    report = {
        "format": "app.redlamp.e2e-report", "tier": tier, "commit": sha, "dirty": dirty,
        "started": started.isoformat(timespec="seconds"), "seconds": (dt.datetime.now().astimezone() - started).total_seconds(),
        "machine": f"{platform.machine()} macOS {platform.mac_ver()[0]}", "load": {"before": load_before, "after": load_after},
        "noisy": max(load_before, load_after) > QUIET_LOAD, "app": str(built), "seed": args.seed,
        "verdict": "Failed: " + ", ".join(problems) if problems else "Passed",
        "summary": summary, "scenarios": scenarios, "crashes": crashes, "hangs": hangs,
        "coverage": cover, "coverageRequired": coverage_required,
        "ownerState": {"changed": changed, "ownerAppRunning": owner_running, "summary": state_summary},
        "relay": relay.count,
    }
    write_report(run_dir, report)
    defaults("delete", BUNDLE_ID)
    log(f"{report['verdict']}. {summary}")
    log(f"Report: {run_dir / 'report.md'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
