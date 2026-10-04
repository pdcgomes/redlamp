#!/usr/bin/env python3
"""List what Lightroom has added since the Lightroom comparison was last checked.

docs/lightroom-comparison.md records how far its Lightroom side goes in a comment,
`<!-- lightroom-checked: 2026-10-04; through: 2026-09 -->`. This finds The Lightroom Queen's
"What's new" post for each month after that release (one per Lightroom release, covering Lightroom
Classic, Desktop and mobile) and prints each post's version and feature headings as a checklist.

    scripts/lightroom-releases.py                  # releases after the comparison's `through` month
    scripts/lightroom-releases.py --since 2025-06  # from a given month

It writes nothing. For each feature, decide whether photographers would recognise it in the
comparison (`.cursor/rules/roadmap-and-comparison.mdc`), note it in your own words in
docs/lightroom-feature-inventory.md with a link to the post, then update the comment and the
"Lightroom checked against" line. Never copy the posts' text. Adobe's own "What's new" pages are the
authority, but they refuse automated requests from the agent sandbox.
"""

import argparse
import datetime
import html
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMPARISON = ROOT / "docs/lightroom-comparison.md"
POST = "https://www.lightroomqueen.com/whats-new-in-lightroom-{month}/"
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129 Safari/537.36"
# Headings every post repeats, which aren't features.
ROUTINE = re.compile(r"bug|update\?|camera support|lens profiles|tether|books updated|find out more|"
                     r"system requirements|other changes|other smaller|and finally|operating system", re.I)


def checked():
    """The comparison's (checked date, through month), from its lightroom-checked comment."""
    found = re.search(r"<!-- lightroom-checked: (\d{4}-\d{2}-\d{2}); through: (\d{4}-\d{2}) -->", COMPARISON.read_text())
    if not found:
        sys.exit("docs/lightroom-comparison.md has no <!-- lightroom-checked: YYYY-MM-DD; through: YYYY-MM --> comment")
    return found.group(1), found.group(2)


def months(start, end):
    year, month = map(int, start.split("-"))
    while (year, month) <= end:
        yield f"{year:04d}-{month:02d}"
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def text(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", fragment))).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--since", help="first month to look at, YYYY-MM (default: the month after `through`)")
    options = parser.parse_args()

    date, through = checked()
    if options.since:
        start = options.since
    else:
        year, month = map(int, through.split("-"))
        start = f"{year + month // 12:04d}-{month % 12 + 1:02d}"
    today = datetime.date.today()
    print(f"Comparison checked {date}, through {through}. Looking from {start}.\n")
    found = 0
    for month in months(start, (today.year, today.month)):
        url = POST.format(month=month)
        try:
            page = fetch(url)
        except (urllib.error.URLError, TimeoutError) as error:
            print(f"{month}: couldn't reach The Lightroom Queen ({error})")
            continue
        if page is None:
            continue
        found += 1
        title = text(re.search(r"<title>(.*?)</title>", page, re.S).group(1)).split("|")[0].strip()
        article = re.search(r"<article.*?</article>", page, re.S)
        headings = [text(h) for h in re.findall(r"<h4[^>]*>(.*?)</h4>", article.group(0) if article else page, re.S)]
        print(f"{month}: {title}\n  {url}")
        for heading in headings:
            if heading and not heading.endswith(":") and not ROUTINE.search(heading):
                print(f"  - [ ] {heading}")
        print()
    if not found:
        print("No release posts since then.")


if __name__ == "__main__":
    main()
