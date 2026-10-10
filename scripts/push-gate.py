#!/usr/bin/env python3
"""The push gate: CI's checks and reference tests on a commit, before it is pushed to main.

The pre-push hook (.githooks/pre-push) runs it on every push that updates main, and stops the push
if it fails. Run by hand (mise run gate), it checks a commit, so that pushing it afterwards finds
it checked and goes straight through:

    scripts/push-gate.py                 # HEAD, as a push of it to main would be checked
    scripts/push-gate.py origin/main     # another commit
    scripts/push-gate.py --suite         # the whole test suite, as CI runs it
    scripts/push-gate.py --full          # and CI's Release builds of the app and the harness

What a push gets depends on what it changes:

  - only files the build and the tests don't read (docs, the site, the video, research notes and
    tools: NOT_READ below): CI's quick checks, in seconds
  - anything else: those, SwiftFormat, a build of everything with its tests, and the reference
    tests, which compare what the code makes with what the repository records (golden renders,
    process references, recorded reports, the sidecar schema, scenario coverage). A commit that
    changes one without recording the other again is what has turned CI red most often; the rest
    of the suite is left to CI, and to --suite.

It runs in a worktree of its own beside the main checkout (../darkroom-push-gate), with its own
DerivedData. The worktree holds the commit's files and, of what a clone lacks, only the sample
raws, vendored LibRaw and the Swift packages, cloned from the main checkout, so a golden render
recorded but never added can't make it pass. It isn't inside the main checkout, where tools that
read their configuration from parent folders would find the main checkout's (SwiftFormat's
excludes build/, and would lint nothing). The lock, the logs and the passes it remembers are in
the main checkout's build/push-gate.

A pass is remembered by the commit's tree, so the same files aren't checked twice. One gate runs
at a time: a second push waits for the first, and gives up if origin's main moved meanwhile,
since git would refuse it then. Tests stop at the first bundle that fails.

It exits with 1 when a step fails, and git then stops the push. `git push --no-verify` skips it.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZERO = "0" * 40
MAIN = "refs/heads/main"
# What a check runs, each level adding to the one before: CI's quick checks; SwiftFormat, a build
# with the tests and the reference tests; the whole suite; CI's Release builds.
LEVELS = ("checks", "reference", "suite", "full")
DOING = {
    "checks": "CI's quick checks",
    "reference": "CI's checks, SwiftFormat, a build with the tests, and the reference tests",
    "suite": "CI's checks, SwiftFormat and the whole test suite",
    "full": "everything CI runs, with its Release builds",
}
# Paths neither the build nor the tests read: a push that changes nothing else gets the checks...
NOT_READ = (
    "docs/", "research/", "web/", "video/", "scripts/", "mise/tasks/", ".cursor/", ".github/", ".githooks/",
    "Casks/", "README.md", "AGENTS.md", "LICENSE", "Version.xcconfig",
)
# ...except these: SidecarSchemaTests builds its path to sidecar-format.md, and CI runs the
# fixtures and generate tasks, and generate the LibRaw script. Paths the Swift code names in full
# are found in it (named_in_code).
READ = ("docs/recipes/", "mise/tasks/fixtures", "mise/tasks/generate", "scripts/vendor-libraw.sh")
QUOTED = re.compile(r'"(?:\.\./)*((?:docs|research|scripts)/[^"\\\s]*)')
# The reference tests: every suite in a test file with a record or update switch, golden renders or
# tests/golden; every suite named for its golden files; and these, whose references are
# docs/recipes and tests/e2e's exemptions.
RECORDS = re.compile(r"REDLAMP_(?:RECORD|UPDATE)_|GoldenRender|tests/golden")
SUITE = re.compile(r"\b(?:struct|class|enum|actor)\s+(\w+Tests)\b")
NAMED_SUITES = ("RedlampDocumentTests/SidecarSchemaTests", "RedlampAutomationTests/ContractTests")
# Sample raws: cloned from the main checkout as they arrive there, then fetched as CI fetches them.
FIXTURES = ("tests/fixtures/raw", "tests/fixtures/cameras", "tests/fixtures/shoots")
# Built inputs, cloned once; generate brings them up to date with each commit.
BUILT = ("vendor/build", "vendor/cache", "Tuist/.build")
# Worth showing while a long step runs: failures, errors, crashes and each test bundle's result.
SHOWN = re.compile(r"✘|(?:^|: )error: |Test run with \d+ tests|unexpected exit|\*\* [A-Z ]+ \*\*")
# A test bundle that failed. The push is stopped either way, so testing stops there, with every
# failure in that bundle shown, rather than running the other bundles (`mise run test` runs them).
BUNDLE_FAILED = re.compile(r"✘ Test run with \d+ tests|Test Suite '[^']+\.xctest' failed")
KEPT_LOGS = 20
# Git exports GIT_DIR and the like to its hooks; git in the gate's worktree mustn't see them.
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def say(message: str) -> None:
    print(f"==> {message}", flush=True)


def took(seconds: float) -> str:
    seconds = round(seconds)
    return f"{seconds} s" if seconds < 60 else f"{seconds // 60} min {seconds % 60} s"


def git(*args: str, cwd: Path = ROOT, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True)
    if result.returncode != 0 and check:
        sys.exit(f"push gate: git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip() if result.returncode == 0 else ""


CHECKOUT = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent
GATE = CHECKOUT / "build/push-gate"
SRC = CHECKOUT.parent / f"{CHECKOUT.name}-push-gate"


def known(name: str) -> bool:
    return subprocess.run(["git", "cat-file", "-e", name], cwd=ROOT, env=ENV, capture_output=True).returncode == 0


def is_ancestor(older: str, newer: str) -> bool:
    command = ["git", "merge-base", "--is-ancestor", older, newer]
    return subprocess.run(command, cwd=ROOT, env=ENV, capture_output=True).returncode == 0


# ---------------------------------------------------------------- what to check


def from_hook(remote: str, lines: list[str]) -> list[tuple[str, str | None]]:
    """Each commit the push puts on main, with the commit the remote's main is at now."""
    pushes = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[2] != MAIN or parts[1] == ZERO:
            continue
        commit, theirs = parts[1], parts[3]
        if theirs == ZERO:
            pushes.append((commit, None))
        elif not known(f"{theirs}^{{commit}}"):
            sys.exit(
                f"push gate: {remote}'s main is at {theirs[:7]}, which this clone hasn't fetched. "
                "Fetch and rebase onto it first (.cursor/rules/main-branch.mdc)."
            )
        elif not is_ancestor(theirs, commit):
            sys.exit(f"push gate: this doesn't build on {remote}'s main ({theirs[:7]}); rebase onto it first.")
        else:
            pushes.append((commit, theirs))
    return pushes


def moved_since(lines: list[str]) -> list[str]:
    """The branches the push names that no longer name the commit the hook was given. Over HTTPS,
    git reads a branch again when it sends, so it would send what landed meanwhile, unchecked."""
    moved = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[2] != MAIN or parts[1] == ZERO:
            continue
        name, commit = parts[0], parts[1]
        if not (name.startswith("refs/") or name == "HEAD"):
            continue
        now = git("rev-parse", "--verify", "--quiet", f"{name}^{{commit}}", check=False)
        if now != commit:
            moved.append(f"{name} names {now[:7] or 'nothing'} now, not the {commit[:7]} it checked")
    return moved


def from_argument(name: str) -> tuple[str, str | None]:
    """The commit, with where it leaves origin/main, which is what a push of it would build on."""
    commit = git("rev-parse", "--verify", f"{name}^{{commit}}")
    return commit, git("merge-base", commit, "origin/main", check=False) or None


def changed(base: str | None, commit: str) -> list[str]:
    if base is None:
        return []
    return [path for path in git("diff", "--name-only", "--no-renames", "-z", base, commit).split("\0") if path]


def named_in_code(commit: str) -> tuple[str, ...]:
    """The docs/, research/ and scripts/ paths the commit's Swift code names in a string."""
    command = ["git", "grep", "-h", "-o", "-E", r'"(\.\./)*(docs|research|scripts)/[^"]*', commit, "--",
               "packages/*.swift", "apps/*.swift"]
    lines = subprocess.run(command, cwd=ROOT, env=ENV, capture_output=True, text=True).stdout.splitlines()
    return tuple(sorted({match.group(1) for line in lines if (match := QUOTED.match(line))}))


def read_by_build(paths: list[str], commit: str) -> list[str]:
    """The changed paths the build or the tests read; with nothing to compare against, all of them."""
    if not paths:
        return ["(everything)"]
    unsure = [path for path in paths if path.startswith(NOT_READ) and not path.startswith(READ)]
    named = named_in_code(commit) if unsure else ()
    return [path for path in paths if path not in unsure or path.startswith(named)]


def reference_suites() -> list[str]:
    """The reference suites in the gate's worktree, as -only-testing identifiers."""
    found, declared = set(), set()
    for path in sorted(SRC.glob("packages/*/Tests/**/*.swift")):
        target = f"{path.relative_to(SRC).parts[1]}Tests"
        text = path.read_text(errors="replace")
        suites = {f"{target}/{name}" for name in SUITE.findall(text)}
        declared |= suites
        found |= suites if RECORDS.search(text) else {suite for suite in suites if "Golden" in suite}
    return sorted(found | (set(NAMED_SUITES) & declared))


def steps(level: str) -> list[tuple[str, list[str], bool]]:
    """CI's steps, by their names in ci.yml where it has them: (name, command, whether it runs long)."""
    common = ["xcodebuild", "-workspace", "Redlamp.xcworkspace", "-destination", "platform=macOS,arch=arm64",
              "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO"]
    xcodebuild = [*common, "-scheme", "Redlamp-Workspace"]
    out = [
        ("Engine purity gate", ["scripts/check-engine-purity.sh"], False),
        ("Focus ring gate", ["scripts/check-focus-rings.py"], False),
        ("Model licence gate", ["scripts/check-model-licenses.py"], False),
        ("Roadmap and Lightroom comparison in step with the tracker", ["scripts/roadmap-sync.py", "--check"], False),
        ("Camera list in step with the decode tests and LibRaw", ["scripts/camera-list.py", "--check"], False),
        ("Performance card in step with the history", ["scripts/perf-card.py", "--check"], False),
    ]
    if level == "checks":
        return out
    out += [
        ("Generate workspace", ["mise", "run", "generate"], False),
        ("Lint (SwiftFormat)", ["mise", "exec", "--", "swiftformat", "--lint", "."], False),
    ]
    if level == "reference":
        only = [f"-only-testing:{suite}" for suite in reference_suites()]
        return out + [
            ("Build with the tests", [*xcodebuild, "build-for-testing"], True),
            (f"Reference tests ({len(only)} suites)", [*xcodebuild, "test-without-building", *only], True),
        ]
    out.append(("Test", [*xcodebuild, "test"], True))
    if level == "full":
        out += [
            ("Build app (Release)", [*common, "build", "-scheme", "Redlamp", "-configuration", "Release"], True),
            ("Build harness (Release)",
             [*common, "build", "-scheme", "RedlampHarness", "-configuration", "Release"], True),
        ]
    return out


# ---------------------------------------------------------------- remembered passes and the lock


def covered(tree: str, level: str) -> dict | None:
    """The pass remembered for these files at this level or above, if there is one."""
    try:
        record = json.loads((GATE / "passed" / tree).read_text())
    except (OSError, ValueError):
        return None
    if record.get("level") not in LEVELS or LEVELS.index(record["level"]) < LEVELS.index(level):
        return None
    return record


def passed_before(commit: str, base: str | None) -> tuple[str, dict] | None:
    """The newest of the commits being pushed, before this one, whose files passed beyond the checks."""
    span = [f"{commit}~1", f"^{base}"] if base else [f"{commit}~1"]
    for line in git("log", "--format=%H %T", "-n", "100", *span, check=False).splitlines():
        sha, tree = line.split()
        record = covered(tree, "reference")
        if record:
            return sha, record
    return None


def remember(tree: str, commit: str, level: str) -> None:
    (GATE / "passed").mkdir(parents=True, exist_ok=True)
    record = {"commit": commit, "level": level, "at": dt.datetime.now().astimezone().isoformat()}
    (GATE / "passed" / tree).write_text(json.dumps(record) + "\n")


def lock(commit: str):
    """Waits for any other gate to finish: (the lock, held until it's closed, and whether it waited)."""
    GATE.mkdir(parents=True, exist_ok=True)
    handle = open(GATE / "lock", "a+")
    waited = False
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.seek(0)
        say(f"Waiting for the gate already checking {handle.read().strip() or 'another push'}")
        fcntl.flock(handle, fcntl.LOCK_EX)
        waited = True
    handle.seek(0)
    handle.truncate()
    handle.write(f"{commit[:7]} (pid {os.getpid()}, since {dt.datetime.now():%H:%M})")
    handle.flush()
    return handle, waited


# ---------------------------------------------------------------- the worktree


def prepare(commit: str, level: str) -> None:
    """Puts the gate's worktree at the commit, with no file the commit doesn't have."""
    if (SRC / ".git").is_file():
        git("checkout", "--detach", "--force", "--quiet", commit, cwd=SRC)
        git("clean", "-d", "--force", "--quiet", cwd=SRC)
    else:
        if SRC.exists():
            shutil.rmtree(SRC)
        git("worktree", "prune")
        SRC.parent.mkdir(parents=True, exist_ok=True)
        git("worktree", "add", "--detach", "--quiet", str(SRC), commit)
    if level == "checks":
        return
    for item in BUILT:
        if (CHECKOUT / item).exists() and not (SRC / item).exists():
            (SRC / item).parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-cR", str(CHECKOUT / item), str(SRC / item)], check=True)
    for item in FIXTURES:
        source = CHECKOUT / item
        for path in sorted(source.rglob("*")) if source.is_dir() else []:
            target = SRC / item / path.relative_to(source)
            # Not partial downloads, or sidecars written by opening a sample, which CI never has.
            if path.is_file() and not path.name.startswith(".") and path.suffix not in (".part", ".redlamp") \
                    and not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(["cp", "-c", str(path), str(target)], check=True)
    # CI downloads every sample; here only what the main checkout lacks, and the tests skip what
    # can't be fetched, as they do in any checkout without them.
    fetch = subprocess.run("mise run fixtures && mise run fixtures-shoots", shell=True, cwd=SRC, env=ENV,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if fetch.returncode != 0:
        say("Some sample raws couldn't be fetched; the tests that need them skip")


def run(name: str, command: list[str], log, long: bool) -> bool:
    started = beat = time.monotonic()
    log.write(f"\n==> {name}: {' '.join(command)}\n")
    log.flush()
    if long:
        say(f"{name}...")
    tail = collections.deque(maxlen=60)
    shown = 0
    stopped = False
    try:
        process = subprocess.Popen(command, cwd=SRC, env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, errors="replace")
    except FileNotFoundError:
        say(f"{name}: {command[0]} isn't on the PATH (run the push where mise is active)")
        return False
    try:
        for line in process.stdout:
            log.write(line)
            tail.append(line)
            if long and SHOWN.search(line):
                print(f"    {line.rstrip()[:400]}", flush=True)
                shown += 1
            if long and not stopped and BUNDLE_FAILED.search(line):
                process.send_signal(signal.SIGINT)
                stopped = True
            if long and time.monotonic() - beat >= 180:
                beat = time.monotonic()
                print(f"    {name}: {took(beat - started)} so far", flush=True)
        code = process.wait()
    except KeyboardInterrupt:
        process.terminate()
        process.wait()
        raise
    result = "ok" if code == 0 and not stopped else "failed"
    early = " (stopped after the first bundle that failed)" if stopped else ""
    summary = f"{name}: {result}, {took(time.monotonic() - started)}{early}"
    log.write(f"==> {summary}\n")
    log.flush()
    say(summary)
    if code != 0 and not shown:
        for line in tail:
            print(f"    {line.rstrip()}", flush=True)
    return code == 0 and not stopped


def check(commit: str, theirs: str | None, asked: str, remote: str | None) -> bool:
    """Checks the commit at the level its changes need, or the one asked for if that's higher."""
    tree = git("rev-parse", f"{commit}^{{tree}}")
    short = git("rev-parse", "--short", commit)
    say(f"Push gate: {short} {git('log', '-1', '--format=%s', commit)}")
    # A commit on top of one that passed, changing only what the build and the tests don't read,
    # needs only the quick checks, and then counts as passed at that commit's level.
    base, inherited = theirs, "checks"
    earlier = passed_before(commit, theirs)
    since_earlier = changed(earlier[0], commit) if earlier else []
    if earlier and since_earlier and not read_by_build(since_earlier, commit):
        base, inherited, paths, read = earlier[0], earlier[1]["level"], since_earlier, []
        level = "checks" if LEVELS.index(inherited) >= LEVELS.index(asked) else asked
    else:
        paths = changed(base, commit)
        read = read_by_build(paths, commit)
        level = max("reference" if read else "checks", asked, key=LEVELS.index)
    record = covered(tree, level)
    if record:
        say(f"Its files passed the gate ({record['level']}) on {record['at'][:16].replace('T', ' at ')} "
            f"({record['commit'][:7]}); nothing to check")
        return True
    files = f"{len(paths)} file{'' if len(paths) == 1 else 's'} changed"
    since = f" since {git('rev-parse', '--short', base)}" if base else ""
    if inherited != "checks":
        say(f"{files}{since}, which passed the gate ({inherited}), none read by the build or the tests: "
            f"{DOING[level]}")
    elif base and paths and not read:
        say(f"{files}{since}, none read by the build or the tests: {DOING[level]}")
    elif base and paths:
        others = f" and {len(read) - 1} more" if len(read) > 1 else ""
        say(f"{files}{since}, {read[0]}{others} read by the build or the tests: {DOING[level]}")
    else:
        say(DOING[level][0].upper() + DOING[level][1:])
    started = time.monotonic()
    holder, waited = lock(commit)
    try:
        record = covered(tree, level)
        if record:
            say(f"Its files passed the gate meanwhile ({record['commit'][:7]}); nothing to check")
            return True
        if remote and theirs and waited:
            now = (git("ls-remote", remote, MAIN, check=False).split() or [theirs])[0]
            if now != theirs:
                say(f"Push gate: {remote}'s main moved to {now[:7]} while this push waited, so git would refuse "
                    "it; nothing was sent. Fetch, rebase onto it and push again.")
                return False
        prepare(commit, level)
        logs = GATE / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        for old in sorted(logs.glob("*.log"))[:-KEPT_LOGS]:
            old.unlink()
        log_path = logs / f"{dt.datetime.now():%Y%m%d-%H%M%S}-{short}.log"
        if level != "checks":
            say(f"Log: {log_path}")
        with log_path.open("w") as log:
            log.write(f"==> Push gate: {commit} at the {level} level, {'pushed to ' + remote if remote else 'by hand'}\n")
            for name, command, long in steps(level):
                if not run(name, command, log, long):
                    log.write(f"==> Push gate: {name} failed after {took(time.monotonic() - started)}\n")
                    say(f"Push gate: {name} failed{'; the push is stopped and nothing was sent' if remote else ''}.")
                    print(f"    Log: {log_path}\n    Worktree: {SRC}", flush=True)
                    if remote:
                        print("    Fix it and push again. If origin/main fails the same way, it needs fixing first; "
                              "`git push --no-verify` skips the gate.", flush=True)
                    return False
            log.write(f"==> Push gate: passed in {took(time.monotonic() - started)}\n")
        remember(tree, commit, max(level, inherited, key=LEVELS.index))
        say(f"Push gate: passed in {took(time.monotonic() - started)}")
        return True
    finally:
        holder.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Check a commit as CI would, before it's pushed to main.")
    parser.add_argument("commit", nargs="?", default="HEAD", help="the commit to check (HEAD by default)")
    parser.add_argument("--suite", action="store_true", help="the whole test suite, not only the reference tests")
    parser.add_argument("--full", action="store_true", help="the whole suite and CI's Release builds")
    parser.add_argument("--hook", nargs=2, metavar=("REMOTE", "URL"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    asked = "full" if args.full else "suite" if args.suite else "checks"
    lines = sys.stdin.read().splitlines() if args.hook else []
    pushes = from_hook(args.hook[0], lines) if args.hook else [from_argument(args.commit)]
    try:
        for commit, theirs in pushes:
            if not check(commit, theirs, asked, args.hook[0] if args.hook else None):
                return 1
    except KeyboardInterrupt:
        say("Push gate: interrupted")
        return 130
    if moved := moved_since(lines):
        say(f"Push gate: stopped, since {'; '.join(moved)}")
        say("Push again to check what it names now, or push the checked commit: git push origin <commit>:refs/heads/main")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
