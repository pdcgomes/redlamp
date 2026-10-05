---
name: redlamp-release
description: The release room, where every Redlamp release is prepared, checked, approved and shipped. Knows the latest and the upcoming release, what has changed since, What's New, known problems and incomplete features, and keeps a canvas checklist the owner approves before anything runs. Use when preparing, checking, approving or running a release, writing a release's What's New, asking what ships next or what's in the latest release, or following up after one ships.
---

# The release room

Every release happens in one canvas, the release room: what ships, its What's New, the checks, the problems, the owner's approvals and the plan that publishes it. It carries the next release from the moment one ships, so the owner can keep a chat open on it or start this skill at any time. Nothing in the release plan runs until the owner has approved the release.

## Where

- The room: `~/.cursor/projects/<workspace>/canvases/release-room.canvas.tsx` (`<workspace>` is the Cursor project folder for this repository, `Users-pedrogomes-src-darkroom`). One room for every release; it is never replaced, only brought up to date.
- Its template: [template.tsx](template.tsx). Edit only the `room` object; the rendering code is shared. A change to the rendering goes into the template and the room together.
- Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first write. Link the room in every reply that changes it: `[Release room](/absolute/path/release-room.canvas.tsx)`.

## Every time: know where things stand

1. **Read the owner's marks first.** Needs you takes Done, Skip and Ask the agent (Done reads Approve on the approval). They are kept in `release-room.canvas.data.json` under `needsYou` as `{ "<id>": { "state": "done" | "skipped" | "asked", "at": "…" } }`. Fold them into `room` as `.cursor/skills/workstream-canvas/SKILL.md` describes; never write that file.
2. **Run `scripts/release-status.py`** (`--json` for the details). Never take versions from memory. It reports:
   - the latest release (GitHub's Latest, or the newest `v*` tag) and the upcoming one, by `mise run release`'s rule: `Version.xcconfig` on origin/main, or its next patch when that version is already tagged; the build number is the count of commits on main;
   - the commits on origin/main since the latest release, by tracker row, and those rows' statuses: a row with commits in the release that isn't Done ships part of a feature;
   - What's New on origin/main for the upcoming version; unmerged branches and unpushed commits on local main; open bug and in-app reports; CI's latest run on main; the tracker rows In progress or Blocked; the README's Known limitations.
3. **Bring the room up to date** in the same turn: `upcoming` (version, build, stage, summary, gate, base commit), `scope`, `heldBack`, `whatsNew`, `checks`, `problems`, `needsYou`, a `log` entry and `updated`. Say plainly what you didn't check.

## Preparing a release

The stages are preparing, awaiting approval, approved, releasing and released. While preparing:

1. **Scope.** What's on origin/main ships; nothing else does. List each change in `scope` (user-facing or internal). Put whatever isn't on origin/main in `heldBack` (unmerged branches, unpushed commits on local main) and ask the owner which of them go in. Never merge or push another session's branch without the owner saying so.
2. **What's New.** Offer the release's user-facing changes as candidates and let the owner choose (at most four, `AskQuestion` with several answers allowed). Write each chosen highlight in `web/content/whats-new/<id>/` as `web/README.md` (What's New) describes, with a real screenshot of the app (`apps/RedlampMac/Sources/DebugSnapshot.swift` lists the capture commands), and show the owner captures of the window. A highlight is `approved` only when the owner says so; it is `published` once `https://redlamp.app/api/whats-new` serves it. It must be live before the release is, since 0.2.4 and later open it straight after updating.
3. **Release notes.** Offer the release's main changes and let the owner choose its highlights. Write them, plainly, in `docs/releases/<version>.md` (`Highlights:` then a bullet each); `mise run release` puts that file above the commit list in the GitHub release and the update window. It must be on origin/main before the release runs.
4. **Checks.** Run them on the release candidate: origin/main with whatever the owner put in scope merged. Each records its result, with counts and the commit, and the time.
   - Every test suite on this Mac (`Redlamp-Workspace`): it runs the GPU tests CI skips, so it is the one that counts. Read `ProcessStabilityTests` on its own: an existing edit that renders differently blocks the release.
   - CI on main (`gh run list --branch main --workflow ci.yml`). A failure that this Mac doesn't reproduce is a problem for the owner to decide, not a pass.
   - Lint and the repository's checks: `mise exec -- swiftformat --lint .`, `scripts/check-engine-purity.sh`, `scripts/roadmap-sync.py --check`, `scripts/camera-list.py --check`.
   - The site: `cd web && npm test && npm run typecheck && npm run build`.
   - A dry run: `REF=HEAD DRY_RUN=1 mise run release` (signed, not notarized).
   - An update from an older copy: `scripts/test-update.sh`, which needs the owner to click Install Update.
   - Performance on a quiet Mac: `scripts/perf-record.sh`, against the last record (`.cursor/rules/performance.mdc`).
   - Trying the candidate: the owner's, as a Needs you item listing what to try.
5. **Problems.** Each failing check, each partly shipped row, each open bug or in-app report that touches the release, and any risk (unpushed work, a relay that isn't switched on, a feature that depends on something outside the app). Each takes the owner's decision: ship as is, fix first, leave out or later. The README's Known limitations go in as one row, with what's new among them.
6. **Docs.** The README (What works today, In progress, Known limitations), the tracker's statuses, `scripts/roadmap-sync.py` and the landing page's by-hand items (`.cursor/rules/landing-page.mdc`) say what the release brings.

Needs you holds only what the owner does or decides: the scope, each problem, What's New's copy, trying the candidate, and, always last and blocking, **Approve the release**. Move the stage to awaiting approval when everything else is settled.

## The approval gate

The release plan runs only when **Approve the release** is done, by the owner's mark or their word in the chat, and every other blocking item is settled. A mark on the canvas is the owner's approval, but say in the chat what you are about to run before running it. If anything changes after approval (a new commit on origin/main, a check that fails again), the approval lapses: say so, and ask again.

## Running the release

Once approved, set the stage to releasing and work through `steps`, recording each:

1. Merge what's in scope and push main, as the owner approved.
2. Confirm What's New is live: `curl -s https://redlamp.app/api/whats-new`.
3. Run `scripts/release-status.py` again: origin/main's head must be the candidate the checks passed on.
4. `mise run release`. It needs this Mac's keychain (the Developer ID certificate, the notarytool profile and the Sparkle key) and reaches Apple, GitHub and redlamp.app. If the agent's sandbox can't, the owner runs it in their own terminal; give them the line.
5. Verify: the GitHub release is Latest, `https://redlamp.app/appcast.xml` offers the build, the Update cask workflow has pointed `Casks/redlamp.rb` at it, and the site's download button follows.
6. The owner updates an installed copy of the previous release with Check for Updates…, and What's New opens.
7. Records: tracker rows the release finishes become Done (naming their commits), `scripts/roadmap-sync.py` then `scripts/tracker-issues.py --apply`, the README, and in this room a `history` entry. Then open the next release: `latest` becomes this one, `upcoming` the next, and the lists start again from `scripts/release-status.py`.

## Writing

- Plain, complete sentences in the project's voice: calm, precise, no superlatives, British spelling (`docs/brand/README.md`).
- Only what you verified: counts and commits from the commands you ran. A check that didn't run says "not run", never "passed".
- Decisions are history: append them, never rewrite them.

## Evolving the room

The owner shapes the room as needs come up. A new kind of check, list or step goes into the template and this skill in the same change, and the room picks it up. Commit both on main: `Release room: …`.
