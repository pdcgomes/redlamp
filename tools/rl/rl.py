#!/usr/bin/env python3
"""rl: Redlamp's launcher for the repository's tools.

`rl` alone opens a menu of the tools, grouped, each with a line saying what it does; picking one
asks for what it needs (with choices from the repository's state), shows the exact command and
runs it. Every menu item is also a command: `rl bench show <task>`. The tools are described once,
in registry.toml, which also makes `rl help`, `rl list --json` and docs/tools.md.

    rl                     the menu
    rl status              where things stand: the branch, the bench's hub and folders, the builds
    rl <group> <tool> ...  a tool, with its answers in order (asked for when missing)
    rl <tool> ... --print  the command a tool would run, without running it
    rl help [<tool>]       what a tool does, its command and its doc
    rl list [--json]       every tool
    rl check               the registry against the repository's tools, and docs/tools.md up to date
    rl docs                writes docs/tools.md

Standard library only: it starts at once and needs no packages.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH = Path.home() / "Library/Application Support/Redlamp/Bench"
RECENT = Path.home() / "Library/Caches/Redlamp/rl-recent.json"
CLI = "build/DerivedData/Build/Products/Debug/redlamp"


def repo_root() -> Path:
    """The checkout rl runs in: the current folder's, so a worktree gets its own tools."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
        root = Path(out)
        if (root / "tools/rl/registry.toml").exists():
            return root
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return HERE.parent.parent


ROOT = repo_root()


# ---------------------------------------------------------------- the registry


@dataclass
class Ask:
    name: str
    prompt: str
    kind: str = "text"  # text, choice, path, list, yesno
    source: str | None = None
    options: list[str] = field(default_factory=list)
    default: str | None = None
    optional: bool = False


@dataclass
class Tool:
    id: str
    group: str
    title: str
    summary: str
    run: str
    needs: list[str] = field(default_factory=list)
    asks: list[Ask] = field(default_factory=list)
    doc: str | None = None
    confirm: bool = False
    detail: str | None = None

    @property
    def words(self) -> list[str]:
        return self.id.split(".")


@dataclass
class Group:
    id: str
    title: str
    summary: str


@dataclass
class Registry:
    groups: list[Group]
    tools: list[Tool]
    later: dict[str, list[str]]

    def tool(self, words: list[str]) -> tuple[Tool | None, list[str]]:
        """The tool named by the first words, and the words left over."""
        for count in (3, 2, 1):
            if len(words) >= count:
                key = ".".join(words[:count])
                for tool in self.tools:
                    if tool.id == key:
                        return tool, words[count:]
        return None, words


def load(path: Path | None = None) -> Registry:
    data = tomllib.loads((path or ROOT / "tools/rl/registry.toml").read_text())
    groups = [Group(g["id"], g["title"], g["summary"]) for g in data["group"]]
    tools = []
    for t in data["tool"]:
        asks = [Ask(**a) for a in t.pop("ask", [])]
        tools.append(Tool(**t, asks=asks))
    return Registry(groups, tools, data.get("later", {}))


# ---------------------------------------------------------------- choices from the repository


def task_folders(area: str, kind: str | None = None, exclude_kind: str | None = None) -> list[tuple[str, str]]:
    folder = BENCH / area
    out = []
    if folder.is_dir():
        for child in sorted(folder.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            manifest = child / "task.json"
            if not manifest.is_file():
                continue
            try:
                m = json.loads(manifest.read_text())
            except json.JSONDecodeError:
                continue
            if kind and m.get("kind") != kind or exclude_kind and m.get("kind") == exclude_kind:
                continue
            look = m.get("look")
            title = m.get("title", child.name)
            if look:
                title = " · ".join(x for x in [look.get("app"), " ".join(filter(None, [look.get("filter"), look.get("variant")]))] if x)
            out.append((child.name if kind != "path" else str(child), title))
    return out


def harness_scenes() -> list[tuple[str, str]]:
    out = []
    for path in sorted((ROOT / "apps/RedlampHarness/Sources").rglob("*.swift")):
        text = path.read_text(errors="ignore")
        for match in re.finditer(r'id: "([a-z0-9-]+)",\s*title: "([^"]+)"', text):
            out.append((match.group(1), match.group(2)))
    return out


def schemes() -> list[tuple[str, str]]:
    text = (ROOT / "Tuist/ProjectDescriptionHelpers/Module.swift").read_text()
    modules = re.findall(r'case \w+ = "(Redlamp\w+)"', text)
    return [(m, "package") for m in modules] + [("Redlamp", "the app"), ("redlamp", "the CLI")]


def ios_devices() -> list[tuple[str, str]]:
    """Connected iPhones, by UDID, as devicectl lists them."""
    out_file = Path("/tmp/rl-devices.json")
    try:
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(out_file)],
            capture_output=True, timeout=20, check=False,
        )
        devices = json.loads(out_file.read_text()).get("result", {}).get("devices", [])
    except (OSError, json.JSONDecodeError, subprocess.TimeoutExpired):
        return []
    out = []
    for d in devices:
        hardware, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
        if hardware.get("platform") != "iOS" or not hardware.get("udid"):
            continue
        state = d.get("connectionProperties", {}).get("tunnelState", "")
        out.append((hardware["udid"], f"{props.get('name', 'iPhone')} ({hardware.get('marketingName', '')}, {state})"))
    return out


SOURCES = {
    "bench.outbox": lambda: task_folders("Outbox"),
    "bench.tasks": lambda: task_folders("Outbox") + task_folders("Done", exclude_kind="look-reference"),
    "bench.looks": lambda: task_folders("Done", kind="look-reference"),
    "harness.scenes": harness_scenes,
    "schemes": schemes,
    "ios.devices": ios_devices,
}


# ---------------------------------------------------------------- asking


def choices_for(ask: Ask) -> list[tuple[str, str]]:
    if ask.source:
        return SOURCES[ask.source]()
    return [(o, "") for o in ask.options]


def ask_value(ask: Ask) -> str | list[str]:
    if ask.kind in ("choice",):
        choices = choices_for(ask)
        if not choices:
            if ask.optional:
                return ask.default or ""
            raise SystemExit(f"rl: nothing to choose for “{ask.prompt}” ({ask.source or 'no options'})")
        print(f"\n{ask.prompt}")
        for index, (value, note) in enumerate(choices, 1):
            print(f"  {index:>2}. {value}" + (f"  — {note}" if note else ""))
        default = ask.default if ask.default in [c[0] for c in choices] else ("" if ask.optional else choices[0][0])
        while True:
            answer = input(f"Number or name [{default or 'none'}]: ").strip()
            if not answer:
                return default
            if answer.isdigit() and 1 <= int(answer) <= len(choices):
                return choices[int(answer) - 1][0]
            if answer in [c[0] for c in choices]:
                return answer
            print("  Not one of those.")
    if ask.kind == "list":
        print(f"\n{ask.prompt} (one a line; an empty line ends)")
        items = []
        while True:
            line = input(f"  {len(items) + 1}: ").strip()
            if not line:
                return items
            items.append(os.path.expanduser(line) if line.startswith("~") else line)
    if ask.kind == "yesno":
        answer = input(f"{ask.prompt} [{'Y/n' if ask.default != 'no' else 'y/N'}]: ").strip().lower()
        return "yes" if (answer or (ask.default or "yes")[0]) in ("y", "yes") else "no"
    suffix = f" [{ask.default}]" if ask.default else ""
    while True:
        answer = input(f"{ask.prompt}{suffix}: ").strip() or (ask.default or "")
        if answer or ask.optional:
            return os.path.expanduser(answer) if ask.kind == "path" else answer
        print("  It needs an answer.")


def fill(tool: Tool, given: list[str], interactive: bool) -> dict[str, str | list[str]]:
    values: dict[str, str | list[str]] = {}
    rest = list(given)
    for ask in tool.asks:
        if ask.kind == "list":
            if rest:
                values[ask.name], rest = rest, []
            elif interactive:
                values[ask.name] = ask_value(ask)
            else:
                values[ask.name] = []
        elif rest:
            values[ask.name] = rest.pop(0)
        elif ask.optional and not interactive:
            values[ask.name] = ask.default or ""
        elif interactive:
            values[ask.name] = ask_value(ask)
        elif ask.default is not None:
            values[ask.name] = ask.default
        else:
            raise SystemExit(f"rl: {' '.join(tool.words)} needs {ask.name} ({ask.prompt})")
    return values


PLACEHOLDER = re.compile(r"\{(\w+)(\*([^}]*))?\}")


def command(tool: Tool, values: dict[str, str | list[str]]) -> str:
    """The tool's shell command with its answers quoted in. `{name}` is one value, `{name*}`
    a list's items, `{name*--flag}` each item after the flag, and `[name?--flag]` the flag and
    its value only when the answer isn't empty."""
    builtins = {"redlamp": shlex.quote(str(ROOT / CLI)), "root": shlex.quote(str(ROOT)), "bench": shlex.quote(str(BENCH))}

    def replace(match: re.Match) -> str:
        name, star, flag = match.group(1), match.group(2), match.group(3) or ""
        if name in builtins:
            return builtins[name]
        value = values.get(name, "")
        if star:
            items = value if isinstance(value, list) else [value] if value else []
            return " ".join(f"{flag} {shlex.quote(i)}".strip() for i in items)
        return shlex.quote(str(value)) if value != "" else "''"

    text = PLACEHOLDER.sub(replace, tool.run)
    # `{name?--flag}`: the flag and its value only when answered.
    def optional(match: re.Match) -> str:
        name, flag = match.group(1), match.group(2)
        value = values.get(name, "")
        return f"{flag} {shlex.quote(str(value))}" if value else ""

    return re.sub(r"\[(\w+)\?([^\]]+)\]", optional, text).strip()


# ---------------------------------------------------------------- running


def newest_source(paths: list[Path]) -> float:
    newest = 0.0
    for base in paths:
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in ("build", ".build", "Derived")]
            for name in filenames:
                if name.endswith(".swift"):
                    newest = max(newest, os.stat(os.path.join(dirpath, name)).st_mtime)
    return newest


def cli_state() -> str:
    binary = ROOT / CLI
    if not binary.exists():
        return "not built"
    sources = [ROOT / "apps/RedlampCLI"] + [p / "Sources" for p in (ROOT / "packages").iterdir() if (p / "Sources").is_dir()]
    return "out of date" if newest_source(sources) > binary.stat().st_mtime else "up to date"


def ensure(needs: list[str]) -> None:
    if "workspace" in needs or "cli" in needs:
        if not (ROOT / "Redlamp.xcworkspace").exists():
            run_shell("mise run generate", "generating the workspace")
    if "cli" in needs and cli_state() != "up to date":
        run_shell("SCHEME=redlamp mise run build", "building the redlamp CLI")


def run_shell(text: str, why: str | None = None) -> int:
    if why:
        print(f"\033[2m({why})\033[0m")
    print(f"\033[1m→ {text}\033[0m", flush=True)
    start = time.time()
    code = subprocess.call(text, shell=True, cwd=ROOT, executable="/bin/zsh")
    seconds = time.time() - start
    if why is None:
        status = "done" if code == 0 else f"failed (exit {code})"
        print(f"\033[2m{status} in {seconds:.0f} s\033[0m")
    if code != 0 and why:
        raise SystemExit(code)
    return code


def remember(tool: Tool) -> None:
    try:
        recent = json.loads(RECENT.read_text()) if RECENT.exists() else []
    except json.JSONDecodeError:
        recent = []
    recent = [tool.id] + [r for r in recent if r != tool.id]
    RECENT.parent.mkdir(parents=True, exist_ok=True)
    RECENT.write_text(json.dumps(recent[:6]))


def recent_ids() -> list[str]:
    try:
        return json.loads(RECENT.read_text()) if RECENT.exists() else []
    except json.JSONDecodeError:
        return []


def launch(tool: Tool, given: list[str], interactive: bool) -> int:
    if interactive:
        print(f"\n\033[1m{tool.title}\033[0m\n{tool.summary}")
        if tool.detail:
            print(f"\033[2m{tool.detail}\033[0m")
    values = fill(tool, given, interactive)
    text = command(tool, values)
    if tool.confirm and interactive:
        answer = input(f"\nRun {text}? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Not run.")
            return 1
    ensure(tool.needs)
    remember(tool)
    return run_shell(text)


# ---------------------------------------------------------------- status


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def hub_listening() -> list[str]:
    """Hubs advertising over Bonjour, by name (dns-sd never ends, so read it for a moment)."""
    try:
        proc = subprocess.run(
            ["dns-sd", "-B", "_redlamp-bench._tcp", "local."], capture_output=True, text=True, timeout=1.5
        )
        out = proc.stdout
    except subprocess.TimeoutExpired as expired:
        out = (expired.stdout or b"").decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
    except FileNotFoundError:
        return []
    names = []
    for line in out.splitlines():
        parts = line.split(None, 6)
        if len(parts) == 7 and parts[1] == "Add":
            names.append(parts[6].strip())
    return sorted(set(names))


def status() -> int:
    branch = git("branch", "--show-current") or "(detached)"
    ahead_behind = git("rev-list", "--left-right", "--count", "origin/main...HEAD").split()
    changes = len([l for l in git("status", "--short").splitlines() if l])
    print(f"\033[1mCheckout\033[0m  {ROOT}  on {branch}")
    if len(ahead_behind) == 2:
        print(f"          {ahead_behind[1]} ahead of origin/main, {ahead_behind[0]} behind; {changes} uncommitted change{'s' if changes != 1 else ''}")

    print("\n\033[1mBench\033[0m")
    hubs = hub_listening()
    print(f"  Hub       {', '.join(hubs) if hubs else 'not advertising (open the harness, Recipe Lab, Bench tab; or rl bench serve)'}")
    devices = []
    try:
        devices = json.loads((BENCH / "hub-devices.json").read_text()).get("devices", [])
    except (OSError, json.JSONDecodeError):
        pass
    print(f"  Paired    {', '.join(d['name'] for d in devices) if devices else 'no phone yet'}")
    outbox = task_folders("Outbox")
    print(f"  Outbox    {len(outbox)} waiting for the phone" + (": " + "; ".join(t for _, t in outbox[:3]) if outbox else ""))
    looks = task_folders("Done", kind="look-reference")
    unpicked = [title for name, title in looks if not (BENCH / "Done" / name / "lab/pick.json").exists()]
    print(f"  Looks     {len(unpicked)} to evaluate" + (": " + "; ".join(unpicked[:3]) if unpicked else ""))
    done = task_folders("Done", exclude_kind="look-reference")
    print(f"  Done      {len(done)} task{'s' if len(done) != 1 else ''} back" + (": " + "; ".join(t for _, t in done[:3]) if done else ""))

    print("\n\033[1mBuilds\033[0m")
    print(f"  CLI       {cli_state()} ({CLI})")
    harness = ROOT / "build/DerivedData/Build/Products/Debug/RedlampHarness.app"
    print(f"  Harness   {'built' if harness.exists() else 'not built'}")
    logs = sorted((Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent / "build/push-gate/logs").glob("*.log"))
    if logs:
        last = logs[-1]
        tail = last.read_text(errors="ignore").strip().splitlines()[-1:] or [""]
        verdict = "passed" if "passed" in tail[0] else "failed" if "fail" in tail[0].lower() else "unfinished"
        print(f"  Push gate {verdict}: {last.stem}")
    return 0


# ---------------------------------------------------------------- the menu


def menu(registry: Registry) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return numbered_menu(registry)
    import curses

    rows: list[tuple[str, Tool | None]] = []
    recent = [t for r in recent_ids() for t in registry.tools if t.id == r]
    if recent:
        rows.append(("Recent", None))
        rows += [("", t) for t in recent]
    for group in registry.groups:
        rows.append((group.title, None))
        rows += [("", t) for t in registry.tools if t.group == group.id]

    def draw(screen) -> Tool | None:
        curses.curs_set(0)
        curses.use_default_colors()
        selectable = [i for i, (_, tool) in enumerate(rows) if tool]
        position, query, top = 0, "", 0
        while True:
            visible = [i for i in selectable if not query or query.lower() in (rows[i][1].id + rows[i][1].title).lower()]
            position = max(0, min(position, len(visible) - 1))
            screen.erase()
            height, width = screen.getmaxyx()
            screen.addnstr(0, 0, "rl — Redlamp's tools.  ↑↓ choose, Enter run, / filter, ? help, s status, q quit", width - 1, curses.A_BOLD)
            if query:
                screen.addnstr(1, 0, f"filter: {query}", width - 1)
            lines = []
            for i, (header, tool) in enumerate(rows):
                if tool is None:
                    if not query:
                        lines.append((header, None))
                elif i in visible:
                    lines.append((f"  {' '.join(tool.words):<24} {tool.title}", i))
            chosen_line = next((n for n, (_, i) in enumerate(lines) if visible and i == visible[position]), 0)
            area = height - 5
            top = min(max(top, chosen_line - area + 1), chosen_line)
            for n, (text, index) in enumerate(lines[top : top + area]):
                attribute = curses.A_REVERSE if visible and index == visible[position] else (curses.A_BOLD if index is None else 0)
                screen.addnstr(2 + n, 0, text, width - 1, attribute)
            if visible:
                tool = rows[visible[position]][1]
                screen.addnstr(height - 2, 0, tool.summary, width - 1, curses.A_DIM)
            screen.refresh()
            key = screen.getch()
            if key in (ord("q"), 27) and not query:
                return None
            if key == 27:
                query = ""
            elif key in (curses.KEY_UP, ord("k")) and not query:
                position -= 1
            elif key == curses.KEY_UP:
                position -= 1
            elif key in (curses.KEY_DOWN, ord("j")) and not query:
                position += 1
            elif key == curses.KEY_DOWN:
                position += 1
            elif key in (10, 13, curses.KEY_ENTER) and visible:
                return rows[visible[position]][1]
            elif key == ord("/"):
                query = " "
            elif key in (curses.KEY_BACKSPACE, 127):
                query = query[:-1]
            elif query and 32 <= key < 127:
                query = (query + chr(key)).lstrip()
            elif key == ord("?") and visible:
                return Tool(id="__help__:" + rows[visible[position]][1].id, group="", title="", summary="", run="")
            elif key == ord("s"):
                return Tool(id="__status__", group="", title="", summary="", run="")

    choice = curses.wrapper(draw)
    if choice is None:
        return 0
    if choice.id == "__status__":
        return status()
    if choice.id.startswith("__help__:"):
        return help_for(registry, choice.id.split(":", 1)[1].split("."))
    return launch(choice, [], interactive=True)


def numbered_menu(registry: Registry) -> int:
    tools = registry.tools
    for group in registry.groups:
        print(f"\n\033[1m{group.title}\033[0m")
        for tool in tools:
            if tool.group == group.id:
                print(f"  {tools.index(tool) + 1:>2}. {' '.join(tool.words):<24} {tool.title}")
    answer = input("\nNumber (or q): ").strip()
    if not answer.isdigit() or not 1 <= int(answer) <= len(tools):
        return 0
    return launch(tools[int(answer) - 1], [], interactive=True)


# ---------------------------------------------------------------- help, list, docs, check


def help_for(registry: Registry, words: list[str]) -> int:
    if not words:
        print(__doc__)
        return 0
    tool, _ = registry.tool(words)
    if not tool:
        print(f"rl: no tool {' '.join(words)}; rl list shows them all")
        return 1
    print(f"\033[1mrl {' '.join(tool.words)}\033[0m — {tool.title}\n\n{tool.summary}")
    if tool.detail:
        print(f"\n{tool.detail}")
    if tool.asks:
        print("\nAsks, in order:")
        for ask in tool.asks:
            where = f" (from {ask.source})" if ask.source else f" ({', '.join(ask.options)})" if ask.options else ""
            print(f"  {ask.name}: {ask.prompt}{where}{' [optional]' if ask.optional else ''}")
    print(f"\nRuns: {tool.run}")
    if tool.needs:
        print(f"Builds first when needed: {', '.join(tool.needs)}")
    if tool.doc:
        print(f"Doc: {tool.doc}")
    return 0


def listing(registry: Registry, as_json: bool) -> int:
    if as_json:
        print(json.dumps([
            {"command": f"rl {' '.join(t.words)}", "id": t.id, "group": t.group, "title": t.title, "summary": t.summary,
             "run": t.run, "asks": [a.__dict__ for a in t.asks], "doc": t.doc}
            for t in registry.tools
        ], indent=2))
        return 0
    for group in registry.groups:
        print(f"\n{group.title}: {group.summary}")
        for tool in registry.tools:
            if tool.group == group.id:
                print(f"  rl {' '.join(tool.words):<24} {tool.title}")
    return 0


def docs_text(registry: Registry) -> str:
    lines = [
        "# Tools: `rl`",
        "",
        "`rl` is the repository's launcher (`tools/rl`). Run it alone for a menu of the tools; each tool is also a command, "
        "`rl <group> <tool>`, with its answers in order. `rl status` says where things stand: the branch, the bench's hub and "
        "folders, the builds and the last push gate. This page is generated from `tools/rl/registry.toml` by `rl docs`; "
        "`rl check` (in `mise run lint`) fails when a mise task or `redlamp` subcommand is in neither the registry nor its "
        "`later` list, or when this page is out of date.",
        "",
        "To have `rl` everywhere: `alias rl=\"$HOME/src/darkroom/bin/rl\"` in `~/.zshrc`. In a worktree it runs that worktree's "
        "tools. `mise run rl` works too.",
        "",
    ]
    for group in registry.groups:
        lines += [f"## {group.title}", "", group.summary, "", "| Command | What it does |", "| --- | --- |"]
        for tool in registry.tools:
            if tool.group == group.id:
                asks = " ".join(f"<{a.name}>" if not a.optional else f"[{a.name}]" for a in tool.asks)
                doc = f" ([doc]({os.path.relpath(ROOT / tool.doc, ROOT / 'docs')}))" if tool.doc else ""
                lines.append(f"| `rl {' '.join(tool.words)}{(' ' + asks) if asks else ''}` | {tool.summary}{doc} |")
        lines.append("")
    later = registry.later
    lines += [
        "## Not in the menu yet",
        "",
        "Run these as before; they join the menu as they're described in the registry.",
        "",
        f"- **mise tasks:** {', '.join(f'`{t}`' for t in later.get('mise', []))}",
        f"- **redlamp subcommands:** {', '.join(f'`{t}`' for t in later.get('redlamp', []))}",
        "",
    ]
    return "\n".join(lines)


def repository_tools() -> dict[str, set[str]]:
    mise = {p.name for p in (ROOT / "mise/tasks").iterdir() if p.is_file() and not p.name.startswith(".")} - {"rl"}
    main = (ROOT / "apps/RedlampCLI/Sources/main.swift").read_text()
    redlamp = set(re.findall(r'^\s*case "([a-z-]+)":', main, re.M)) & {
        m for m in re.findall(r'case "([a-z-]+)":\s*\n\s*try await \w+', main)
    }
    return {"mise": mise, "redlamp": redlamp}


def check(registry: Registry) -> int:
    problems: list[str] = []
    group_ids = {g.id for g in registry.groups}
    ids = [t.id for t in registry.tools]
    for duplicate in {i for i in ids if ids.count(i) > 1}:
        problems.append(f"two tools are {duplicate}")
    covered = {"mise": set(), "redlamp": set()}
    for tool in registry.tools:
        if tool.group not in group_ids:
            problems.append(f"{tool.id}: no group {tool.group}")
        names = {a.name for a in tool.asks}
        used = {m.group(1) for m in PLACEHOLDER.finditer(tool.run)} | set(re.findall(r"\[(\w+)\?", tool.run))
        for name in used - names - {"redlamp", "root", "bench"}:
            problems.append(f"{tool.id}: runs {{{name}}}, which it doesn't ask for")
        for ask in tool.asks:
            if ask.source and ask.source not in SOURCES:
                problems.append(f"{tool.id}: unknown source {ask.source}")
            if ask.kind not in ("text", "choice", "path", "list", "yesno"):
                problems.append(f"{tool.id}: unknown kind {ask.kind}")
        for need in tool.needs:
            if need not in ("cli", "workspace"):
                problems.append(f"{tool.id}: unknown need {need}")
        if tool.doc and not (ROOT / tool.doc.split("#")[0]).exists():
            problems.append(f"{tool.id}: no doc {tool.doc}")
        for task in re.findall(r"mise run ([a-z0-9-]+)", tool.run):
            covered["mise"].add(task)
        for sub in re.findall(r"\{redlamp\} ([a-z0-9-]+)", tool.run):
            covered["redlamp"].add(sub)
    present = repository_tools()
    for kind in ("mise", "redlamp"):
        later = set(registry.later.get(kind, []))
        for name in sorted(present[kind] - covered[kind] - later):
            problems.append(f"{kind} {name} is neither in a tool nor in later.{kind}: describe it in tools/rl/registry.toml")
        for name in sorted(later & covered[kind]):
            problems.append(f"{kind} {name} is in a tool and in later.{kind}: take it out of later")
        for name in sorted(later - present[kind]):
            problems.append(f"later.{kind} lists {name}, which no longer exists")
    docs = ROOT / "docs/tools.md"
    if not docs.exists() or docs.read_text() != docs_text(registry):
        problems.append("docs/tools.md is out of date: run rl docs")
    for problem in problems:
        print(f"rl check: {problem}")
    if not problems:
        print(f"rl check: OK ({len(registry.tools)} tools)")
    return 1 if problems else 0


# ---------------------------------------------------------------- entry


def main(argv: list[str]) -> int:
    registry = load()
    if not argv:
        return menu(registry)
    head = argv[0]
    if head in ("-h", "--help"):
        print(__doc__)
        return 0
    if head == "status":
        return status()
    if head == "help":
        return help_for(registry, argv[1:])
    if head == "list":
        return listing(registry, "--json" in argv)
    if head == "check":
        return check(registry)
    if head == "docs":
        (ROOT / "docs/tools.md").write_text(docs_text(registry))
        print("wrote docs/tools.md")
        return 0
    tool, rest = registry.tool(argv)
    if tool is None:
        group = next((g for g in registry.groups if g.id == head), None)
        if group:
            print(f"{group.title}: {group.summary}")
            for t in registry.tools:
                if t.group == group.id:
                    print(f"  rl {' '.join(t.words):<24} {t.title}")
            return 0
        print(f"rl: no tool {' '.join(argv)}; rl list shows them all")
        return 1
    if "--help" in rest:
        return help_for(registry, tool.words)
    if "--print" in rest:
        rest.remove("--print")
        print(command(tool, fill(tool, rest, interactive=False)))
        return 0
    return launch(tool, rest, interactive=sys.stdin.isatty())


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
