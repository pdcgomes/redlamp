"""Where Redlamp's social posts stand, for the social room (.cursor/skills/redlamp-social/SKILL.md).

    python3 .cursor/skills/redlamp-social/room.py status [--canvas PATH]
    python3 .cursor/skills/redlamp-social/room.py room [--canvas PATH]
    python3 .cursor/skills/redlamp-social/room.py thumbs [--canvas PATH]

status checks docs/social/posts.json: each part has the fields it needs and no others; times are ISO
with an offset; platforms are instagram or tiktok; each post's episode and hook exist; every line on
screen has at most 17 characters, and a hook or end line at most two lines; the captions, alt text and
lines have no em or en dashes, exclamation marks, emoji or banned words; and each caption has the
standard lines and ends with 3 to 5 hashtags. It then lists each episode's storyboard files in
video/out/features/boards/ and its renders in ~/src/redlamp-social/renders/, says whether the room's schedule
and images are up to date, and gives the next three posts due. It exits with 1 when a check fails.

room writes the room's POSTS block, between its // POSTS:BEGIN and // POSTS:END lines, from posts.json,
and only when status's checks pass.

thumbs writes the room's THUMBS block from video/out/features/boards/<episode>-hook.png and
<episode>-result.png, as base64 PNG data URIs, leaving out the files that aren't there.

Paths are this checkout's, so the script works in any worktree. Boards are rendered, not committed, so a
board missing here is taken from the main checkout or another worktree that has it. The room is
~/.cursor/projects/<project>/canvases/social-room.canvas.tsx unless --canvas gives another path.

The Instagram publisher's commands, auth, publish, sync and tick, aren't written yet.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = Path(__file__).resolve().parents[3]
SCHEDULE = "docs/social/posts.json"
BOARDS = "video/out/features/boards"
RENDERS = Path.home() / "src" / "redlamp-social" / "renders"

PLATFORMS = {"instagram": "Instagram", "tiktok": "TikTok"}
STAGES = ("storyboard", "building", "in review", "approved", "rendered")
TRIALS = ("MANUAL", "SS_PERFORMANCE")
LINE = 17
LINES = 2
TAGS = (3, 5)
CAPTION = 2200
PNG = b"\x89PNG\r\n\x1a\n"

FIELDS = {
    "schedule": {"timeZone": str, "campaign": dict, "standard": dict, "episodes": list, "posts": list},
    "campaign": {"id": str, "title": str, "doc": str},
    "standard": {"about": str, "cta": str, "requirements": str, "endCard": list},
    "episode": {"id": str, "title": str, "feature": str, "audience": str, "source": str, "stage": str,
                "hooks": dict, "endLine": list, "result": str},
    "post": {"id": str, "episode": str, "hook": str, "at": str, "platforms": list, "file": str, "coverMs": int,
             "caption": str, "alt": str},
}
OPTIONAL = {"post": {"trial": str, "check": str}}
TYPES = {str: "text", dict: "an object", list: "a list", int: "a whole number"}

DASHES = {"\u2014": "an em dash", "\u2013": "an en dash"}
EMOJI = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\u231A-\u23FF\uFE0F\u200D]")
BANNED = re.compile(
    r"\b(seamless(ly)?|effortless(ly)?|unlock(s|ed|ing)?|elevat(e|es|ed|ing)|game[- ]?changers?|magic(al|ally)?"
    r"|level(s|led|ling)?[- ]up|supercharg(e|es|ed|ing)|revolutionary|ultimate(ly)?)\b",
    re.IGNORECASE,
)
THUMB = re.compile(r'^\s*"([^"]+)": "([^"]*)",?$')


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout


def checkouts():
    """This checkout first, then the main one and the other worktrees."""
    trees = [Path(line.split(" ", 1)[1]) for line in git("worktree", "list", "--porcelain").splitlines()
             if line.startswith("worktree ")]
    return [ROOT] + [tree for tree in trees if tree.resolve() != ROOT]


def default_canvas():
    main = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir").strip()).parent
    project = str(main).strip("/").replace("/", "-")
    return Path.home() / ".cursor/projects" / project / "canvases/social-room.canvas.tsx"


def load():
    path = ROOT / SCHEDULE
    try:
        schedule = json.loads(path.read_text())
    except FileNotFoundError:
        sys.exit(f"{path} doesn't exist")
    except ValueError as error:
        sys.exit(f"{path} isn't valid JSON: {error}")
    if not isinstance(schedule, dict):
        sys.exit(f"{path} should hold an object")
    return schedule


# ---------------------------------------------------------------- checks

def typed(value, expected):
    if expected is int:
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, expected)


def fields(where, item, kind, errors):
    """Whether `item` has every field its kind needs, each of the right type. Unknown fields are errors
    too, because the room's types can't hold them, but they don't stop the other checks."""
    if not isinstance(item, dict):
        errors.append(f"{where}: should be an object")
        return False
    known = {**FIELDS[kind], **OPTIONAL.get(kind, {})}
    usable = True
    for name in FIELDS[kind]:
        if name not in item:
            errors.append(f"{where}: {name} is missing")
            usable = False
    for name, value in item.items():
        if name not in known:
            errors.append(f"{where}: {name} isn't a field the room knows; add it to template.tsx's types and to "
                          "room.py's FIELDS first")
        elif not typed(value, known[name]):
            errors.append(f"{where}: {name} should be {TYPES[known[name]]}")
            usable = False
    return usable


def problems(text):
    """What in a piece of copy breaks the rules a script can check."""
    found = [name for char, name in DASHES.items() if char in text]
    if "!" in text:
        found.append("an exclamation mark")
    if EMOJI.search(text):
        found.append("an emoji")
    found += [f'the word "{match.group(0)}"' for match in BANNED.finditer(text)]
    return found


def copy(where, text, errors):
    errors.extend(f"{where} has {problem}" for problem in problems(text))


def screen(where, lines, errors):
    """Lines shown on screen together: one or two, of at most 17 characters each."""
    if not isinstance(lines, list) or not lines or not all(isinstance(line, str) and line.strip() for line in lines):
        errors.append(f"{where}: should be one or two lines of text")
        return
    if len(lines) > LINES:
        errors.append(f"{where}: has {len(lines)} lines, and at most {LINES} are on screen at once")
    for line in lines:
        if len(line) > LINE:
            errors.append(f'{where}: "{line}" has {len(line)} characters, and a line holds at most {LINE}')
        copy(f'{where}: "{line}"', line, errors)


def moment(value):
    """A post's time, or None when it isn't ISO with an offset."""
    try:
        parsed = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo is not None else None


def zone_of(schedule):
    try:
        return ZoneInfo(schedule.get("timeZone", ""))
    except (ZoneInfoNotFoundError, ValueError, TypeError):
        return None


def check(schedule):
    """The problems in posts.json that keep it out of the room, and the warnings that don't."""
    errors, warnings = [], []
    if not fields("posts.json", schedule, "schedule", errors):
        return errors, warnings
    zone = zone_of(schedule)
    if zone is None:
        errors.append(f'posts.json: timeZone "{schedule["timeZone"]}" isn\'t a time zone')
    fields("campaign", schedule["campaign"], "campaign", errors)
    standard = schedule["standard"]
    if fields("standard", standard, "standard", errors):
        for name in ("about", "cta", "requirements"):
            copy(f"standard {name}", standard[name], errors)
        screen("standard endCard", standard["endCard"], errors)
        if "link in bio" not in standard["cta"]:
            errors.append('standard cta: should say "link in bio"')
        if "early development" not in standard["requirements"]:
            errors.append('standard requirements: should say "early development"')

    episodes = {}
    for index, episode in enumerate(schedule["episodes"]):
        where = f"episode {episode.get('id', index + 1) if isinstance(episode, dict) else index + 1}"
        if not fields(where, episode, "episode", errors):
            continue
        if episode["id"] in episodes:
            errors.append(f"{where}: its id is used twice")
        episodes[episode["id"]] = episode
        if episode["stage"] not in STAGES:
            errors.append(f'{where}: stage "{episode["stage"]}" should be one of {", ".join(STAGES)}')
        if sorted(episode["hooks"]) != ["a", "b"]:
            errors.append(f"{where}: hooks should be a and b")
        for hook, lines in episode["hooks"].items():
            screen(f"{where}, hook {hook}", lines, errors)
        screen(f"{where}, endLine", episode["endLine"], errors)

    ids = set()
    for index, post in enumerate(schedule["posts"]):
        where = f"post {post.get('id', index + 1) if isinstance(post, dict) else index + 1}"
        if not fields(where, post, "post", errors):
            continue
        if post["id"] in ids:
            errors.append(f"{where}: its id is used twice")
        ids.add(post["id"])
        episode = episodes.get(post["episode"])
        if episode is None:
            errors.append(f'{where}: episode "{post["episode"]}" isn\'t one of the episodes')
        elif post["hook"] not in episode["hooks"]:
            errors.append(f'{where}: hook "{post["hook"]}" isn\'t one of {post["episode"]}\'s hooks')
        at = moment(post["at"])
        if at is None:
            errors.append(f'{where}: at "{post["at"]}" should be an ISO time with an offset, as in '
                          "2026-10-27T18:00:00+00:00")
        elif zone is not None and at.astimezone(zone).utcoffset() != at.utcoffset():
            local = at.astimezone(zone)
            warnings.append(f"{where}: {post['at']} is {local:%H:%M} in {zone.key}, which is on "
                            f"{local.isoformat()[-6:]} then")
        platforms = post["platforms"]
        if not platforms or any(p not in PLATFORMS for p in platforms) or len(set(platforms)) != len(platforms):
            errors.append(f"{where}: platforms should be instagram, tiktok or both, each once")
        if "trial" in post:
            if post["trial"] not in TRIALS:
                errors.append(f"{where}: trial should be {' or '.join(TRIALS)}")
            if platforms != ["instagram"]:
                errors.append(f"{where}: a trial reel goes on Instagram only")
        if post["coverMs"] < 0:
            errors.append(f"{where}: coverMs can't be negative")
        if not post["file"].strip():
            errors.append(f"{where}: file is empty")
        caption = post["caption"]
        copy(f"{where}, caption", caption, errors)
        copy(f"{where}, alt", post["alt"], errors)
        for name in ("cta", "requirements"):
            line = standard.get(name)
            if isinstance(line, str) and line not in caption:
                errors.append(f"{where}, caption: should include the standard {name} line")
        tags = caption.rstrip().rsplit("\n\n", 1)[-1].split()
        if not all(re.fullmatch(r"#\w+", tag) for tag in tags) or not TAGS[0] <= len(tags) <= TAGS[1]:
            errors.append(f"{where}, caption: should end with a paragraph of {TAGS[0]} to {TAGS[1]} hashtags")
        if len(caption) > CAPTION:
            errors.append(f"{where}, caption: has {len(caption)} characters, more than Instagram's {CAPTION}")
    return errors, warnings


# ---------------------------------------------------------------- files

def board(name, trees):
    """A storyboard file and the checkout it's in, from the first checkout that has it."""
    for tree in trees:
        path = tree / BOARDS / name
        if path.is_file():
            return path, tree
    return None


def renders():
    """The names in the renders folder, or None and why when this shell can't read it."""
    try:
        return set(os.listdir(RENDERS)), ""
    except FileNotFoundError:
        return set(), "~/src/redlamp-social/renders/ doesn't exist yet"
    except OSError:
        return None, "this shell can't read ~/src/redlamp-social/renders/"


def images(schedule, trees):
    """Each episode's hook and result frames as data URIs, by "<episode>-hook" and "<episode>-result",
    and the files that couldn't be used."""
    found, missing = {}, []
    for episode in schedule.get("episodes", []):
        if not isinstance(episode, dict) or not isinstance(episode.get("id"), str):
            continue
        for frame in ("hook", "result"):
            key = f"{episode['id']}-{frame}"
            hit = board(f"{key}.png", trees)
            if hit is None:
                missing.append(f"{key}.png")
                continue
            data = hit[0].read_bytes()
            if not data.startswith(PNG):
                missing.append(f"{key}.png (not a PNG)")
                continue
            found[key] = "data:image/png;base64," + base64.b64encode(data).decode()
    return found, missing


def block(canvas, name):
    """The lines of the canvas, and where its NAME block begins and ends."""
    lines = canvas.read_text().splitlines()
    begin = [i for i, line in enumerate(lines) if line.startswith(f"// {name}:BEGIN")]
    end = [i for i, line in enumerate(lines) if line.startswith(f"// {name}:END")]
    if len(begin) != 1 or len(end) != 1 or end[0] < begin[0]:
        return lines, None
    return lines, (begin[0], end[0])


def write_block(canvas, name, new):
    if not canvas.is_file():
        sys.exit(f"There's no room at {canvas}; copy {Path(__file__).with_name('template.tsx')} there first")
    lines, span = block(canvas, name)
    if span is None:
        sys.exit(f"{canvas} needs one // {name}:BEGIN line, and one // {name}:END line after it")
    canvas.write_text("\n".join(lines[:span[0]] + new + lines[span[1] + 1:]) + "\n")


def posts_block(schedule):
    return ["// POSTS:BEGIN (room.py room writes this block from docs/social/posts.json)",
            "const POSTS: Schedule = " + json.dumps(schedule, indent=2, ensure_ascii=False) + ";",
            "// POSTS:END"]


def thumbs_block(found):
    return ["// THUMBS:BEGIN (room.py thumbs writes this block from video/out/features/boards/)",
            "const THUMBS: Record<string, string> = {",
            *[f"  {json.dumps(key)}: {json.dumps(uri)}," for key, uri in found.items()],
            "};",
            "// THUMBS:END"]


def room_state(canvas, schedule, found):
    """What the room holds against posts.json and the boards, in a line or two."""
    if not canvas.is_file():
        return [f"No room at {canvas}."]
    lines, span = block(canvas, "POSTS")
    said = []
    if span is None:
        said.append("The room has no POSTS block.")
    else:
        text = "\n".join(lines[span[0] + 1:span[1]]).strip()
        prefix = "const POSTS: Schedule = "
        try:
            written = json.loads(text[len(prefix):].rstrip(";")) if text.startswith(prefix) else None
        except ValueError:
            written = None
        if written == schedule:
            said.append("The room's schedule matches posts.json.")
        else:
            said.append("The room's schedule differs from posts.json: run room.py room.")
    lines, span = block(canvas, "THUMBS")
    if span is None:
        said.append("The room has no THUMBS block.")
    else:
        shown = {}
        for line in lines[span[0] + 1:span[1]]:
            match = THUMB.match(line)
            if match:
                shown[match.group(1)] = match.group(2)
        if shown == found:
            said.append(f"Its images match the boards ({len(shown)} shown).")
        else:
            said.append(f"Its images differ from the boards ({len(shown)} shown, {len(found)} found): "
                        "run room.py thumbs.")
    return said


# ---------------------------------------------------------------- commands

def when(at, zone):
    local = at.astimezone(zone) if zone else at
    return f"{local:%a} {local.day} {local:%b}, {local:%H:%M}"


def listed(have, missing):
    if not have:
        return "none"
    return ", ".join(have) + (f" (missing {', '.join(missing)})" if missing else "")


def status(canvas):
    schedule = load()
    errors, warnings = check(schedule)
    zone = zone_of(schedule)
    episodes = [e for e in schedule.get("episodes", []) if isinstance(e, dict)]
    posts = [p for p in schedule.get("posts", []) if isinstance(p, dict)]
    campaign = schedule.get("campaign") if isinstance(schedule.get("campaign"), dict) else {}
    print(f"{SCHEDULE}: {campaign.get('title', 'no title')}, {len(episodes)} episodes and {len(posts)} posts, "
          f"times in {schedule.get('timeZone')}")
    doc = campaign.get("doc")
    if isinstance(doc, str):
        print(f"Campaign document: {doc}" + ("" if (ROOT / doc).is_file() else " (not in this checkout yet)"))
    if errors:
        print(f"Checks: {len(errors)} problem{'' if len(errors) == 1 else 's'}")
        for error in errors:
            print(f"  {error}")
    else:
        print("Checks: passed")
    for warning in warnings:
        print(f"  Warning: {warning}")

    trees = checkouts()
    names, why = renders()
    print(f"\nStoryboards in {BOARDS}/ and renders in ~/src/redlamp-social/renders/:")
    if why:
        print(f"  {why}" + (", so the renders weren't checked." if names is None else "."))
    for episode in episodes:
        eid = str(episode.get("id"))
        print(f"  {eid} {episode.get('title')}, {episode.get('stage')}")
        have, missing = [], []
        for name in (f"{eid}.png", f"{eid}-hook.png", f"{eid}-result.png"):
            hit = board(name, trees)
            if hit is None:
                missing.append(name)
            else:
                have.append(name + ("" if hit[1] == ROOT else f" (from {hit[1]})"))
        print(f"      boards: {listed(have, missing)}")
        files = [p["file"] for p in posts if p.get("episode") == eid and isinstance(p.get("file"), str)]
        if names is None:
            print("      renders: not checked")
        else:
            print(f"      renders: {listed([f for f in files if f in names], [f for f in files if f not in names])}")

    found, _ = images(schedule, trees)
    print()
    for line in room_state(canvas, schedule, found):
        print(line)

    now = datetime.now(timezone.utc)
    titles = {e.get("id"): e.get("title") for e in episodes}
    timed = [(moment(post.get("at")), post) for post in posts]
    due = sorted([pair for pair in timed if pair[0] and pair[0] > now], key=lambda pair: pair[0])[:3]
    print("\nNext posts due:" + ("" if due else " none"))
    for at, post in due:
        hook = f"hook {str(post.get('hook')).upper()}" + (", trial reel" if post.get("trial") else "")
        where = " and ".join(PLATFORMS.get(p, str(p)) for p in post.get("platforms", []))
        print(f"  {when(at, zone)}  {str(post.get('id')):<10}  {titles.get(post.get('episode'), post.get('episode'))}, "
              f"{hook}; {where}")
    return 1 if errors else 0


def room(canvas):
    schedule = load()
    errors, _ = check(schedule)
    if errors:
        print(f"posts.json has {len(errors)} problem{'' if len(errors) == 1 else 's'}, so the room wasn't changed:")
        for error in errors:
            print(f"  {error}")
        return 1
    write_block(canvas, "POSTS", posts_block(schedule))
    print(f"Wrote {len(schedule['episodes'])} episodes and {len(schedule['posts'])} posts into {canvas}")
    return 0


def thumbs(canvas):
    found, missing = images(load(), checkouts())
    write_block(canvas, "THUMBS", thumbs_block(found))
    print(f"Wrote {len(found)} image{'' if len(found) == 1 else 's'} into {canvas}")
    if missing:
        print(f"Not there: {', '.join(missing)}")
    heavy = [key for key, uri in found.items() if len(uri) > 1_000_000]
    if heavy:
        print(f"Over 1 MB as data, which makes the room slow to load: {', '.join(heavy)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("status", "room", "thumbs"))
    parser.add_argument("--canvas", type=Path, help="the room's .canvas.tsx, if not the default one")
    args = parser.parse_args()
    canvas = args.canvas.expanduser() if args.canvas else default_canvas()
    sys.exit({"status": status, "room": room, "thumbs": thumbs}[args.command](canvas))


if __name__ == "__main__":
    main()
