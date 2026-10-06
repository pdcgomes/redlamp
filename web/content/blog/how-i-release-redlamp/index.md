---
title: How I release Redlamp
summary: Agents build Redlamp on a bunch of branches at once, but a release still needs one person to say yes. This is the room where that happens, and the test suite I'm building to back it up.
date: 2026-10-05
cover: release-room-overview.png
coverAlt: The release room for 0.2.4-prealpha in Cursor, with its readiness lines on the left and the Needs you list on the right
---

Redlamp's first release went out on 1 October. By the evening of the 4th, there had been six. With several agents working in separate branches and worktrees, changes are reaching main throughout the day. At the time of writing, I have more than a dozen worktrees on my SSD.

That makes it relatively easy to keep building. Keeping track of what's ready to release has needed more attention.

Publishing a release offers an update to everyone who has the app installed. I want to know exactly what's going into it, which checks have run, and what problems remain before I do that. The first few releases made it clear that asking an agent for a summary wasn't sufficient.

## The release command

The mechanics are handled by [`mise run release`](https://github.com/pdcgomes/redlamp/blob/main/mise/tasks/release). It builds `origin/main` in a clean worktree, bumps the patch version if the current version is already tagged, then signs, notarises, tags and publishes the app on GitHub. It also publishes the update feed.

Installed copies check `redlamp.app/appcast.xml`, so publishing the release makes the update available. Building from a clean checkout of `origin/main` also means uncommitted work on my Mac can't accidentally end up in the app.

The uncertainty was in the preparation. An agent could describe its own changes accurately while missing work merged by other agents. A completed branch that hasn't been merged won't ship. Neither will commits on local main that haven't been pushed. Meanwhile, a known failing test can end up in a release simply because nobody explicitly decided what to do about it.

That happened here. CI on main hasn't passed since the morning of 3 October, and releases 0.2.1, 0.2.2 and 0.2.3 went out with it failing. I wanted the release process to make that visible and require a decision.

## A shared place for release preparation

I asked for a release skill with a canvas that acts as the checklist. I wanted to be able to keep its chat open or start a fresh one, and have it establish the latest released version and the next candidate from the current repository state.

I already use [workstream canvases](https://github.com/pdcgomes/redlamp/blob/main/.cursor/skills/workstream-canvas/SKILL.md) to follow individual pieces of work. The release room uses the same idea, but it continues across releases. When one ships, its record moves into the history and preparation starts for the next.

Whenever the skill starts, it first runs [`scripts/release-status.py`](https://github.com/pdcgomes/redlamp/blob/main/scripts/release-status.py). That queries git and GitHub for the current state.

This morning, it reported 0.2.3-prealpha as the latest release and 0.2.4-prealpha, build 601, as the upcoming one. There were 59 commits on `origin/main` since the previous release. The changes were grouped by tracker item, including camera diagnostics, the Camera Bench window, filmstrip context-menu actions, early generative-fill work and What's New.

```
Latest release:   0.2.3-prealpha (2026-10-04, from GitHub)
Upcoming release: 0.2.4-prealpha, build 601 (the next patch, …)
origin/main:      1065b5b Blog: publish Testing cameras I don't own

Changes since 0.2.3-prealpha: 59 commits
  CAM-14  Done         Camera bench: decode diagnostics …  (10 commits)
  CAM-15  Done         The Camera Bench window: …  (8 commits)
  CAM-16  In progress  Camera bench submissions: …  (2 commits)
  EDT-19  Done         The filmstrip's context menu: …  (3 commits)
  RM-10   In progress  Opt-in generative fill on Macs …  (2 commits)
  UX-14   Done         What's New: after an update, …  (10 commits)
  …

What's New for 0.2.4-prealpha on origin/main: Test your camera
CI on main: in_progress at 1065b5b
```

On its previous refresh, there had been 33 commits and the expected build number was 567. Pushing main changed both. That's exactly the kind of detail I don't want an agent to infer from a previous conversation.

The room uses that information to show the release scope, What's New content, checks, known problems and the steps needed to publish and verify the update.

Everything on `origin/main` is in scope. Unmerged work is listed separately, and the agent asks me what should be included rather than merging another session's branch itself. Tracker items that aren't complete are flagged so I can see when a release includes only part of a feature.

For 0.2.4, some of that partial work is research material and an initial generative-fill implementation that isn't used anywhere in the app yet. It still needs to be visible when I'm reviewing the scope.

## The decisions I need to make

The part I use most is “Needs you”. Each entry describes something I need to do or decide, what it enables, and a command to copy when relevant.

I can mark it Done or Skip, or use **Ask the agent** to open a chat with the room attached and the item already described. That lets me hand off an investigation without reconstructing the brief. The room records that it's with an agent, and picks up my responses on its next update.

![The release room's Needs you list, before and after the first item is marked done](needs-you.gif "Done folds an item away, and Undo brings it back. The agent reads the marks at its next update.")

The final item is always release approval, and it always blocks publication. I have to approve it on the canvas or explicitly in the chat before any of the release steps run. The agent also tells me what it's about to execute.

Approval applies to the state I've reviewed. If `origin/main` changes or a check fails after that, the approval expires and the room asks again.

At the time of writing, the What's New copy for 0.2.4 is approved. I still need to confirm the scope, decide whether to enable the Camera Bench submission relay or ship without Send Results, resolve each recorded problem, try the candidate myself and approve the release.

![The release room's Problems tab, with five problems and the decision on each](release-room-problems.png "Every known problem waits for a decision.")

For each problem, the choices are to ship as it is, fix it first, leave it out or defer it. The decision stays in the release record.

## What's New

0.2.4 will be the first release with a What's New window. It opens once after an update and presents up to four highlights. Sparkle's update window already lists every commit, but I wanted a shorter introduction to the changes people are likely to use.

The content comes from redlamp.app, which means I can correct it after a release. Each highlight can also include a button that opens the relevant feature.

![What's New for 0.2.4, listing its two highlights under the logo](whats-new-highlights.png "The highlights, under the logo as it rises.")

![The Test your camera page in What's New, with a screenshot of the Camera Bench and a Test Your Camera button](whats-new-test-your-camera.png "Each highlight gets a page.")

That content needs to be live before the app ships. In the release room, each highlight moves through candidate, drafted, approved and published. Only I can approve it, and published means the live feed has been checked.

For this release, the two highlights are [Test your camera](/blog/testing-cameras-i-dont-own) and copying settings through the filmstrip's context menu. Both are already live.

## Checking the candidate

Checks are recorded against the candidate commit, with their result and when they ran. A check that hasn't run is shown as not run.

The main validation is the full set of tests on my Mac, including GPU tests skipped by CI. Within that, I look separately at the process-stability tests. They render existing edits and compare them against recorded results; a change in how an existing edit renders blocks the release.

The remaining checks cover lint, the website build, a release dry run, an actual Sparkle update from an older installation and performance measurements on a quiet Mac. I still click Install Update myself for the update check.

![The release room's Checks tab: CI on main failed, and the other checks not run yet, each with its command](release-room-checks.png "Each check says what it runs and how it went. One that hasn't run says so.")

The latest completed CI run on main fails in the dust-detection evaluations, process-stability tests and a welcome-window test. Some failures may be related to the GitHub runner, but that needs to be established. I chose to fix CI before shipping 0.2.4, and an agent is investigating on a separate branch. The release is waiting for CI to pass.

## Testing the app as a whole

There is still a gap in this process. The existing tests cover individual parts of the app: rendering, cameras and compatibility with older edits. They don't establish that every menu item, shortcut and control is connected correctly in the application.

Today, I check much of that by trying the candidate myself. The release command doesn't currently run tests, and manual coverage will become harder as the app grows.

I've approved a [design for an end-to-end regression suite](https://github.com/pdcgomes/redlamp/blob/main/docs/plans/2026-10-05-regression-suite-design.md). I want it to run the app and exercise its features, checking that they're present, connected, behave as expected and don't crash. Rendering correctness remains covered by the engine tests.

The planned suite drives a test build of the app from inside the process. Keyboard events, menu actions, clicks and drags use AppKit's normal event paths so it can catch broken shortcuts and disabled menu items. It can run in the background without taking over the mouse and keyboard on the Mac I'm using. XCUITest would take over the Mac during the run and would first require accessibility information for custom controls that Redlamp doesn't yet provide.

Coverage will be checked against the app's existing inventories: 97 actions on 96 key bindings, 152 parameters including 118 sliders, and 131 features across 16 areas. Each needs a scenario or a written reason for excluding it. Adding a feature without either will fail CI.

The test build will use a separate bundle ID and home folder, with no network access. Bug reports and Camera Bench submissions will go to a local stand-in relay, allowing the suite to inspect what would be sent, including checking for file paths, folder names and serial numbers.

The design has several tiers: a smoke run under five minutes, a full run under thirty, performance checks on a quiet Mac, replayable random walks through the app, and a black-box check of the signed application.

The first implementation will cover the smoke tier and release gate (`ARC-07`). The release command will refuse to publish without a passing run for the same commit. Scenarios for the remaining feature areas follow in `ARC-08`.

For now, 0.2.4 is waiting on the outstanding checks and decisions in the room. I'll keep adjusting the process as I find gaps. The [release skill](https://github.com/pdcgomes/redlamp/blob/main/.cursor/skills/redlamp-release/SKILL.md) and [canvas template](https://github.com/pdcgomes/redlamp/blob/main/.cursor/skills/redlamp-release/template.tsx) are in the repository if you'd like to adapt them.

Thanks for reading,\
Pedro
