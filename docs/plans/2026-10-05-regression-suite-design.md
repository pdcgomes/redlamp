# End-to-end regression suite: design (2026-10-05)

Tracker rows: ARC-07 (the foundation and the release gate) and ARC-08 (every feature, the soak tier and the performance tier). The owner approved the plan on 5 October 2026.

## Goal

Before every release, one command runs the real app through every feature, the way a person uses it, and fails if anything is missing, not wired up, behaving wrongly, crashing, hanging or slow. Pixels stay with the engine and golden tests (`ProcessStabilityTests`, the camera and recipe goldens); this suite checks that the features are there and work.

## Decisions

- **The app is driven from inside a test build of the same commit** (owner, 2026-10-05). A driver linked into Debug and profiling builds sends real key, menu, click and drag events through AppKit's own dispatch, so the key monitor, menu validation, hit-testing, the panels, the model, the engine, the GPU and the decode service all take part. It runs in the background without taking over the Mac's mouse and keyboard. The signed release app gets a separate black-box check. XCUITest is kept for the accessibility audit in Phase 4: it would need accessibility values on every custom control first, takes over the Mac for the whole run, and tests the window server's path rather than the app's.
- **Performance blocks a release only when measured on a quiet Mac** (owner, 2026-10-05): a load average of 8 or below before and after, the threshold `scripts/perf-history.py` already uses. A busy run waits for quiet, then asks the owner whether to accept it unmeasured.

## What exists

- `--script` (`apps/RedlampMac/Sources/DebugSnapshot.swift`, `EditorModel.applyDebugCommand`) already reaches every `ShortcutAction` and any `ParameterID`, opens windows, AI masks and the command palette, under `#if DEBUG || REDLAMP_PROFILING`. It waits with fixed sleeps, asserts nothing and reports nothing.
- Catalogues a suite can enumerate: `ShortcutAction` (97 actions on 96 key bindings), `ParameterCatalog` (152 parameters, 118 of them panel sliders), `PanelID`, `SidebarSection`, `EditTool`, `MaskKind`, and `FeedbackArea.catalog` (16 areas, 131 features, mirrored in `docs/feedback/areas.json`), whose feature IDs are the ones bug reports carry.
- Instruments: `MainThreadMonitor`, `MainThreadSampler`, `MemorySnapshot`, `ActivityLog`, the typed `PaletteEvent` stream, and the engine's Open and Render signposts.
- Gaps found while planning: no accessibility identifiers anywhere, and the custom AppKit panels expose nothing to the accessibility tree; nothing detects crashes or hangs; the release task runs no tests; storage is hard-coded under `~/Library/Application Support/Redlamp`; and feedback and the camera bench sent dry runs only in Debug builds, so a profiling build would have filed real issues.

## Architecture

- **The QA build** is a Release build with `REDLAMP_PROFILING` (as `scripts/perf-sweep.sh` builds), copied to `build/e2e/Redlamp E2E.app` with the bundle ID `app.redlamp.mac.e2e` and re-signed. It has its own defaults domain, and the supervisor starts its executable directly with its arguments and environment, so a run never reads `/tmp/redlamp-launch-args` and never takes a developer's or another agent's arguments. It is never activated unless the run allows focus, with App Nap off.
- **The driver** is `packages/RedlampAutomation`, a UI-layer package whose sources compile only in Debug and profiling builds. The app starts it from its launch closure, beside `DebugSnapshot`, when `--e2e <run directory>` is given.
  - Input goes through the user's own paths. Keys are synthetic `NSEvent`s handed to `NSApplication.sendEvent`, so the Develop key monitor and menu key equivalents see them as they would a key press. Clicks and drags are mouse events at a view's position in its window, hit-tested as usual. Menu items are invoked with `NSMenu.performActionForItem(at:)` after the menu has validated them, so a disabled item is caught. SwiftUI sheets are operated through their accessibility actions where that works, and through their models where it doesn't (see the spike). The model API only sets up state.
  - Targets are found by catalogue ID: identifiers are set once, in the shared components, from the IDs they already hold (`slider.basic.exposure` from `SliderRowView.parameter`, `panel.basic` from the panel's header, `tool.masking`, `sidebar.history`, `filmstrip.cell.<n>`).
  - Steps wait on conditions (observed model state, a frame count, a file), never on fixed sleeps.
  - Checks are about wiring, not pixels: the model's value and the history step, the frame re-rendered and the histogram moved the expected way, the sidecar on disk, exported files' format, size, bit depth and metadata, and no unexpected error in the activity log.
  - Each step records its feature IDs, input path, duration, main-thread p99 and memory footprint, and a window snapshot on failure (as `--snapshot` takes one, without Screen Recording permission). A watchdog thread flags a main thread that hasn't turned its run loop for 2 s.
  - Results go to `<run>/events.jsonl` as they happen, and coverage (which actions, parameters, menu items and features were exercised, by which path) to `<run>/coverage.json`.
- **The supervisor** is `scripts/e2e.py`, behind `mise run e2e`. It builds or takes a QA app, prepares the run directory, launches the app for each scenario group with a deadline, collects new crash reports from `~/Library/Logs/DiagnosticReports`, retries a failed group once in a fresh app (a pass on retry is reported as flaky), and writes `report.md` and `report.json` under `build/e2e/<commit>-<time>/`. It exits non-zero on any failure, crash, hang or uncovered feature.

## Hermetic runs

- Preferences live in the QA bundle ID's own domain, which the supervisor seeds (the welcome window shown, the stub relay's endpoints) and deletes afterwards.
- Files: `CFFIXED_USER_HOME` points the app's home at `<run>/home`, so Application Support and Caches land in the run directory (verified by the spike).
- Fixtures are APFS clones (`cp -c`) of `tests/fixtures/raw` and `tests/fixtures/shoots`, plus files the supervisor makes: a damaged raw and a folder to change while it's watched.
- Models are cloned from the owner's downloads in `~/Library/Application Support/Redlamp/Models`; a scenario needing one that isn't there is reported as skipped, by name.
- No network: the feedback and camera-bench endpoints point at a stub relay the supervisor serves on 127.0.0.1, which records what it is sent, so the suite can check that a report holds no paths, folder names or serial numbers. Feedback and the camera bench send dry runs in profiling builds as they do in Debug.
- A run leaves the owner's Application Support, caches and preferences as they were; the supervisor checks this before and after.

## Tiers

- **Contract**, in CI on every pull request: Swift Testing suites in `packages/RedlampAutomation/Tests`. Every available action, live parameter, panel, tool, sidebar section and feedback feature is claimed by a scenario or exempted with a reason in `tests/e2e/exemptions.json`, and the panel controls are present in real offscreen views.
- **Smoke**, under 5 minutes: launch, open every fixture format, every action by its key and its menu item, every panel slider once, export, quit, relaunch.
- **Full**, under 30 minutes, with `MTL_DEBUG_LAYER=1`: the scenario packs.
- **Performance**, quiet Mac, validation off: budgets in `tests/e2e/budgets.json`, recorded to `docs/performance/history.jsonl` with the source `e2e`.
- **Soak**: seeded random walks over the catalogue with invariants after each step, and a replayable failure.
- **Release artifact**, black box on the signed app: opens the fixtures, stays up, quits cleanly with no crash report; its bundled CLI renders; it carries no automation code; and `scripts/test-update.sh --auto` updates an old copy to it.

## Release gate

`mise/tasks/release`, after the bundled-CLI check and before the dry-run exit, builds the QA variant from the same worktree, runs the release tier (or accepts a passing report for the same commit) and the black-box checks. `REF=HEAD DRY_RUN=1 mise run release` rehearses it all. CI runs the contract tests only, since hosted runners can't be relied on for a Metal device.

## Spike results (2026-10-05)

A throwaway probe in a Debug build, re-identified as `app.redlamp.mac.e2e` and never activated, tried each way of delivering input on the Sony sample:

- **Keys** reach the Develop key monitor both through `NSApplication.sendEvent` and through `postEvent` (`\` toggled Before/After). ⌘ shortcuts reach the menu bar either way (⌘2 toggled Tone Curve). For a ⇧⌘ shortcut, `charactersIgnoringModifiers` must be the unshifted character (`e` for ⇧⌘E), as AppKit's own events have it; with `E` nothing matched.
- **Menu items** built by SwiftUI read as disabled until their menu is about to open: SwiftUI updates them in its menu delegate's `menuNeedsUpdate` and `menuWillOpen`. Calling those first, as AppKit does when a menu opens, enabled Export, Auto Settings and Reset All, and Auto Settings then ran from its item.
- **AppKit controls** take synthetic mouse events in a background window: two drags on the Exposure track moved it 0.00 → +2.07 → −2.76, each one history step.
- **SwiftUI gestures** over the canvas (drawing a gradient) ignore synthetic mouse events unless the window is key, and a window can only be key while the app is active. With the app activated, the same drag drew a linear gradient. `CGEvent.postToPid` didn't help either way.
- **Sheets** were attached to `NSApp.keyWindow ?? NSApp.mainWindow`, which are nil while Redlamp has never been active, so Export and the recipe sheets opened nothing in the background. They now use `EditorWindowController.frontWindow`, which falls back to the editor's window as Feedback already did, and the Export sheet opens in the background from ⇧⌘E and from its menu item.
- **Modal loops stop main-actor tasks**: while `NSApp.runModal` runs the Export sheet, a `Task` on the main actor doesn't resume. Work scheduled with `CFRunLoopPerformBlock` in the common modes does, so the driver runs on a thread of its own and enters the main thread that way, and never waits on a call that can start a modal loop.
- **SwiftUI sheets' accessibility** in-process is sparse without an assistive app connected: the Export sheet exposed 8 elements with no labels or identifiers. Sheets are opened and closed by their real paths, and their actions run through the sheet's own entry points (an export job with given settings); the dialog's controls themselves stay with the harness's Export scenes.
- **Storage**: `open --env` passed no variables at all here; launching the executable directly does, and `CFFIXED_USER_HOME` then moves the home, Application Support and Caches into the run directory. The bundle ID gives the run its own defaults domain. (The owner's `app.redlamp.mac` domain has `FeedbackSendsLive` on, so a run in that domain would have filed real issues even from Debug.)
- **Background rendering** isn't throttled: sweeping Exposure for a second delivered a frame for every change (101 to 114 across runs), with the window reported visible.

## Results (2026-10-05)

- **Built:** the driver (`packages/RedlampAutomation`: 63 scenarios in the full tier, 4 in the performance tier and the soak walk), the supervisor (`scripts/e2e.py`, `mise run e2e`), the contract and driver tests (14, in `mise run test`), identifiers and their presence tests (3, in `RedlampUITests`), and the release gate in `mise/tasks/release`.
- **Timing on the owner's M1 Ultra, busy (load averages of 20 to 58):** the smoke tier about 2.3 minutes, the full tier about 5 minutes, the performance tier about 3 minutes after its build.
- **Coverage:** 412 claims from the app's catalogues: 385 claimed by scenarios, 27 exempt with a reason in `tests/e2e/exemptions.json` (the catch-all "Something else" features, rendering quality owned by the golden and decode tests, and what only the release's black box can check).
- **A dry-run release** (`REF=HEAD DRY_RUN=1 mise run release`) built and signed with Developer ID, ran the suite from its worktree and stopped on a failing check, as the gate should. The black box passed 8 of 8 on a Release candidate; an agent's shell can't send the app Apple events, so it quit the app by SIGTERM there.
- **Found in the app:**
  - Rotate Left and Right (⌘[ and ⌘]) had no menu item, and the Develop key monitor leaves ⌘ keys to the menu bar, so the keys did nothing; they're in the Photo menu now.
  - `canPerform` had no case for Depth Range Mask, so the command palette always showed it as unavailable; fixed.
  - Sheets attached only to a key or main window, so nothing could open them while Redlamp wasn't active; they fall back to the editor's window now.
  - A long session's memory keeps growing after its caches fill, by about 1.8 MB an editing step (5 GB over about 3,000 steps of the soak walk, with and without Metal's validation layer). The soak tier bounds it at 3 MB a step; finding where it goes is for the owner to schedule.
  - On a Portuguese keyboard, SwiftUI shows Zoom In as ⌘* rather than ⌘=, and `[` and `]` have no key of their own, so Decrease and Increase Rating can't be typed there; the suite runs those from the command palette.
- **What the suite can't do with synthetic events:** SwiftUI's menu shortcuts with ⇧ or ⌥ (⇧⌘C, ⇧⌘V, ⇧⌘Z, ⌥⌘A, ⇧⌘U, ⇧⌘N) are taken by the menu bar but don't run, while their menu items do; the suite checks those items' key equivalents and runs them from the menu, and the owner checks the keys by hand. The Previous Photo menu item is sometimes stale on a first try straight after its photo changes; the retry passes, and the report shows it as flaky.

Decision (measured): the supervisor launches the executable directly with its environment, not through `open`. A run is background by default; steps that need a key window (SwiftUI gestures on the canvas) activate the app only when the run allows focus (`--focus`, which the release tier uses, saying so before it starts), and otherwise take the model's path, which the coverage records as such.
