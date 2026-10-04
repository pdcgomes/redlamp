#!/usr/bin/env python3
"""Creates the labels in-app reports carry: `in-app`, and a `component:` label for each area in
docs/feedback/areas.json (generated from the hierarchy in packages/RedlampUI/Sources/Feedback).

A dry run by default; --apply makes the changes. Run it after the areas change. The relay files
reports with only the labels that exist, so a report never creates one. Other labels are left alone,
and the `component:` labels are outside the namespaces scripts/tracker-issues.py manages.
"""

import argparse
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Production files into the first; Preview deployments into the second.
REPOS = ("pdcgomes/redlamp", "pdcgomes/redlamp-feedback")
IN_APP = ("in-app", "1d76db", "Filed from Redlamp's Report a Bug or Send Feedback")
COMPONENT_COLOUR = "f9d0c4"


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def wanted():
    areas = json.loads((ROOT / "docs/feedback/areas.json").read_text())["areas"]
    return [IN_APP] + [(area["label"], COMPONENT_COLOUR, area["summary"]) for area in areas]


def existing(repo):
    labels = json.loads(gh("label", "list", "-R", repo, "--limit", "500", "--json", "name,color,description"))
    return {label["name"]: label for label in labels}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--apply", action="store_true", help="make the changes (default: a dry run)")
    parser.add_argument("--repo", action="append", help="only this repository (repeatable)")
    options = parser.parse_args()

    for repo in options.repo or REPOS:
        present = existing(repo)
        changes = []
        for name, colour, description in wanted():
            label = present.get(name)
            if label is None:
                changes.append(("create", name, colour, description))
            elif label["color"].lower() != colour or label["description"] != description:
                changes.append(("update", name, colour, description))
        print(f"{repo}: {len(changes)} to create or update, {len(wanted()) - len(changes)} unchanged")
        for action, name, _, _ in changes:
            print(f"  {action:6s} {name}")
        if options.apply:
            for _, name, colour, description in changes:
                gh("label", "create", name, "-R", repo, "--color", colour, "--description", description, "--force")
    if not options.apply:
        print("\nDry run: nothing changed. Run with --apply to make the labels.")


if __name__ == "__main__":
    main()
