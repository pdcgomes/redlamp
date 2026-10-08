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
- The release copy: `~/src/redlamp-release`, a worktree of this repository kept only for releases. The candidate's checks that need a checkout (every test suite, the regression suite, the dry run) and the release itself run there, never in the main checkout, which other sessions share. Put it on the commit being checked with `git checkout --detach <commit>`; it has the gitignored build inputs (`AGENTS.md`, A fresh worktree). If it's missing, make it with `git worktree add --detach ~/src/redlamp-release origin/main` and copy those inputs in.

## The owner runs the release

The agent never runs `mise run release` without `DRY_RUN=1`: notarizing needs the owner's keychain and a connection to Apple that the agent's sandbox doesn't have, and publishing is the owner's act. When the plan reaches it, give the owner the exact line to run in their own Terminal, as a blocking Needs you item and in the chat, then verify what it did. Start it with `caffeinate -i`, so a Mac that sleeps or locks doesn't stop notarizing halfway; the notarize task reports any failure of `notarytool history` as a missing profile, so ask the owner to run `xcrun notarytool history --keychain-profile <profile>` to see the real error.

## Every time: know where things stand

1. **Read the owner's marks first.** Needs you takes Done, Skip and Ask the agent (Done reads Approve on the approval). They are kept in `release-room.canvas.data.json` under `needsYou` as `{ "<id>": { "state": "done" | "skipped" | "asked", "at": "…" } }`. Fold them into `room` as `.cursor/skills/workstream-canvas/SKILL.md` describes; never write that file.
2. **Run `scripts/release-status.py`** (`--json` for the details). Never take versions from memory. It reports:
   - the latest release (GitHub's Latest, or the newest `v*` tag) and the upcoming one, by `mise run release`'s rule: `Version.xcconfig` on origin/main, or its next patch when that version is already tagged; the build number is the count of commits on main;
   - the commits on origin/main since the latest release, by tracker row, and those rows' statuses: a row with commits in the release that isn't Done ships part of a feature;
   - What's New on origin/main for the upcoming version; unmerged branches and unpushed commits on local main; open bug and in-app reports; CI's latest run on main; the tracker rows In progress or Blocked; the README's Known limitations.
3. **Bring the room up to date** in the same turn: `upcoming` (version, build, stage, summary, gate, base commit), `scope`, `heldBack`, `whatsNew`, `checks`, `problems`, `needsYou`, a `log` entry and `updated`. Say plainly what you didn't check.

## Preparing a release

The stages are preparing, awaiting approval, approved, releasing and released. While preparing:

1. **Scope.** What's on origin/main ships; nothing else does. List each change in `scope` (user-facing or internal). Put whatever isn't on origin/main in `heldBack` (unmerged branches, unpushed commits on local main) and ask the owner which of them go in. Never merge or push another session's branch without the owner saying so. For each user-facing change, name the regression scenarios that cover it (`packages/RedlampAutomation/Sources/Scenarios/`); a change without one is a problem, fixed before approval, so the suite always covers what the release ships.
2. **What's New.** Offer the release's user-facing changes as candidates and let the owner choose (at most four, `AskQuestion` with several answers allowed). Write each chosen highlight in `web/content/whats-new/<id>/` as `web/README.md` (What's New) describes, with a real screenshot of the app (`apps/RedlampMac/Sources/DebugSnapshot.swift` lists the capture commands), and show the owner captures of the window. A highlight is `approved` only when the owner says so; it is `published` once `https://redlamp.app/api/whats-new` serves it. It must be live before the release is, since 0.2.4 and later open it straight after updating.
3. **Release notes.** Offer the release's main changes and let the owner choose its highlights. Write them, plainly, in `docs/releases/<version>.md` (`Highlights:` then a bullet each); `mise run release` puts that file above the commit list in the GitHub release and the update window. It must be on origin/main before the release runs.
4. **Checks.** Run them on the release candidate: origin/main with whatever the owner put in scope merged. Each records its result, with counts and the commit, and the time.
   - Every test suite on this Mac (`Redlamp-Workspace`): it runs the GPU tests CI skips, so it is the one that counts. Read `ProcessStabilityTests` on its own: an existing edit that renders differently blocks the release.
   - CI on main (`gh run list --branch main --workflow ci.yml`). A failure that this Mac doesn't reproduce is a problem for the owner to decide, not a pass.
   - Lint and the repository's checks: `mise exec -- swiftformat --lint .`, `scripts/check-engine-purity.sh`, `scripts/roadmap-sync.py --check`, `scripts/camera-list.py --check`.
   - The site: `cd web && npm test && npm run typecheck && npm run build`.
   - The regression suite (`README.md`, Regression suite): `mise run e2e -- --tier release` in the release copy, on the candidate with nothing uncommitted, while no other session is building. About 15 minutes; it drives a test build of the app through every feature and writes `report.md` in `build/e2e/<commit>-<time>/`. Record its verdict, the counts (passed, flaky, failed), the claims covered, stalls, isolation and the storage section. `mise run release` accepts this report for the same commit rather than running the suite again.
   - A dry run in the release copy: `REF=<candidate> DRY_RUN=1 mise run release` (signed, not notarized).
   - An update from an older copy: `scripts/test-update.sh`, which needs the owner to click Install Update.
   - Performance on a quiet Mac: `scripts/perf-record.sh`, against the last record (`.cursor/rules/performance.mdc`).
   - Trying the candidate: the owner's, as a Needs you item listing what to try.
5. **Problems.** Each failing check, each scenario the suite reports as flaky or each storage problem it finds, each partly shipped row, each open bug or in-app report that touches the release (the reports room lists them, and the fixes from reports the release brings), and any risk (unpushed work, a relay that isn't switched on, a feature that depends on something outside the app). Each takes the owner's decision: ship as is, fix first, leave out or later. The README's Known limitations go in as one row, with what's new among them.
6. **Docs.** The README (What works today, In progress, Known limitations), the tracker's statuses, `scripts/roadmap-sync.py` and the landing page's by-hand items (`.cursor/rules/landing-page.mdc`) say what the release brings.

Needs you holds only what the owner does or decides: the scope, each problem, What's New's copy, trying the candidate, and, always last and blocking, **Approve the release**. Move the stage to awaiting approval when everything else is settled. The owner's marks are kept by item ID, so each release's items carry its version in their IDs (`scope-0.3.0`, `approve-0.3.0`; the Approve button shows on any ID starting with `approve`), and a mark on one release never settles the next.

## The approval gate

The release plan runs only when **Approve the release** is done, by the owner's mark or their word in the chat, and every other blocking item is settled. A mark on the canvas is the owner's approval, but say in the chat what you are about to run before running it. If anything changes after approval (a new commit on origin/main, a check that fails again), the approval lapses: say so, and ask again.

## Running the release

Once approved, set the stage to releasing and work through `steps`, recording each:

1. Merge what's in scope and push main, as the owner approved.
2. Confirm What's New is live: `curl -s https://redlamp.app/api/whats-new`.
3. Run `scripts/release-status.py` again: origin/main's head must be the candidate the checks passed on.
4. The owner runs `mise run release` from the release copy, put on origin/main first (the task is the copy's own). It runs the regression suite unless the release copy holds a passing release-tier report for this commit, then checks the signed app as a black box; `SKIP_E2E="<why>"` skips the suite only with the owner's word, and the reason goes in the room's log. It needs this Mac's keychain (the Developer ID certificate, the notarytool profile and the Sparkle key) and reaches Apple, GitHub and redlamp.app.
   - To release an earlier commit of main without what came after it (work in progress landed meanwhile), `REF=<commit>` names it: the task tags its version bump instead of pushing it, and gives main the version so the next release moves on. The highlights come from main's `docs/releases/<version>.md`. If such a run stops after it pushed main's bump, rerun it without moving the release copy: on origin/main, `Version.xcconfig` no longer matches the commit being released, and the task refuses.
5. Verify: the GitHub release is Latest, `https://redlamp.app/appcast.xml` offers the build, the Update cask workflow has pointed `Casks/redlamp.rb` at it, and the site's download button follows. Then the owner downloads the zip from redlamp.app in a browser and opens it from Finder, as someone new to Redlamp would, on a Mac that hasn't opened this build: Gatekeeper's command-line checks (`spctl`, `syspolicy_check`) accepted 0.2.5 and 0.2.6 while Finder refused to open them (#333).
   - A refused download can be fixed without a new release when the app inside is sound: rezip it, sign the zip with `sign_update --account redlamp`, give the feed's enclosure the new `sparkle:edSignature` and `length`, upload both with `gh release upload <tag> <zip> appcast.xml --clobber`, then run the Update cask workflow for the tag (`gh workflow run cask.yml -f tag=<tag>`).
6. The owner updates an installed copy of the previous release with Check for Updates…, and What's New opens.
7. Records: tracker rows the release finishes become Done (naming their commits), `scripts/roadmap-sync.py` then `scripts/tracker-issues.py --apply`, the README, the release's download and installed size (`scripts/perf-history.py release <tag> --apply` measures its zip on GitHub, adds them to `docs/performance/history.jsonl` and redraws the README's performance card; commit both), and in this room a `history` entry. Then bring the reports room up to date (`.cursor/skills/redlamp-reports/SKILL.md`, After a release): each report the release fixed gets a reply saying it's out, and any fix it left out a correction. Then open the next release: `latest` becomes this one, `upcoming` the next, and the lists start again from `scripts/release-status.py`. Problems still open carry over; the log and decisions keep their history. A minor or major release needs `MARKETING_VERSION` set by hand in `Version.xcconfig` (the task bumps only the patch), so it starts as a Needs you item and the first step of the plan.

## Writing

- Plain, complete sentences in the project's voice: calm, precise, no superlatives, British spelling (`docs/brand/README.md`).
- Only what you verified: counts and commits from the commands you ran. A check that didn't run says "not run", never "passed".
- Decisions are history: append them, never rewrite them.

## Evolving the room

The owner shapes the room as needs come up. A new kind of check, list or step goes into the template and this skill in the same change, and the room picks it up. Commit both on main: `Release room: …`.
