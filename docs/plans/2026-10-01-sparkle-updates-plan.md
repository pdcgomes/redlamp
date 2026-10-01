# Plan: automatic updates with Sparkle

**Goal**: copies built by `mise run release` check `https://redlamp.app/appcast.xml` and update themselves through Sparkle, starting with 0.2.0-prealpha ([design](2026-10-01-releases-and-updates-design.md#iteration-2-automatic-updates-with-sparkle)).
**Architecture**: Sparkle 2.10.0 as a Tuist external package, linked by the app target only. `Updates` in the app target wraps `SPUStandardUpdaterController` and exists only when Info.plist has a feed URL, which only the release script sets. The release script re-signs Sparkle's helpers, writes a one-item appcast with `scripts/appcast.sh` and publishes it with the zip; the website redirects the feed URL to the latest release's appcast.
**Tech Stack**: Swift 6 and SwiftUI (`apps/RedlampMac`, `packages/RedlampUI`), Tuist 4, bash, Sparkle's `generate_keys` and `sign_update`, Next.js config (`web/`).

There are no unit tests to write: the Swift changes are wiring around Sparkle, and the rest is build and release plumbing. Each step is verified by building, inspecting the built bundle, or running the scripts; the last step runs a real update.

Work in the checkout is shared with other in-progress changes, so every commit names its paths (`git commit -- <paths>`), and no step edits a file that already has uncommitted changes (`web/package.json` and `web/package-lock.json` do at the start).

## Changes during implementation

None yet.

## Step 1: Sparkle through Tuist

**Files**: `Tuist/Package.swift` (new), `Tuist/Package.resolved` (generated), `mise/tasks/generate`, `apps/RedlampMac/Project.swift`

- `Tuist/Package.swift`: a manifest whose only dependency is `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")`.
- `mise/tasks/generate`: run `tuist install` before `tuist generate --no-open`.
- `apps/RedlampMac/Project.swift`: add `.external(name: "Sparkle")` to the app target's dependencies.

Verify: `mise run generate`, then `ls Tuist/.build/artifacts/sparkle/Sparkle/bin` lists `generate_keys` and `sign_update`; `mise run build` succeeds and `build/DerivedData/Build/Products/Debug/Redlamp.app/Contents/Frameworks/Sparkle.framework` exists.

## Step 2: The signing key

Run `Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account redlamp` once. It stores the private key in the login keychain and prints the public key.

Verify: `generate_keys --account redlamp -p` prints the same public key. The owner exports a backup (`generate_keys --account redlamp -x <file>`) to the password manager and deletes the file.

## Step 3: Info.plist

**File**: `apps/RedlampMac/Project.swift`

- `"SUFeedURL": "$(REDLAMP_UPDATE_FEED)"` and `"SUPublicEDKey": "<the public key>"` in `infoPlist`.
- `"REDLAMP_UPDATE_FEED": ""` in the target's base settings, so local builds have no feed.

Verify: after `mise run generate && mise run build`, `plutil -extract SUFeedURL raw` on the Debug app's Info.plist prints an empty string and `SUPublicEDKey` is the key. Building with `REDLAMP_UPDATE_FEED=https://redlamp.app/appcast.xml` on the `xcodebuild` command line puts the URL in.

## Step 4: `Updates` and the menu item

**Files**: `apps/RedlampMac/Sources/Updates.swift` (new), `apps/RedlampMac/Sources/RedlampApp.swift`, `apps/RedlampMac/Sources/AppCommands.swift`

- `Updates`: `@MainActor @Observable final class`, `init?()` returns nil unless Info.plist's `SUFeedURL` is non-empty, otherwise creates `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`. `private(set) var canCheck` and `private(set) var checksAutomatically` follow `updater.canCheckForUpdates` and `updater.automaticallyChecksForUpdates` through `observe(_:options: [.initial, .new])`. `check()` calls `controller.checkForUpdates(nil)`; `setChecksAutomatically(_:)` sets the updater's property, which Sparkle wants set only on a user's change.
- `AppDelegate` owns `let updates = Updates()`.
- `AppCommands` takes `updates: Updates?` and adds `CommandGroup(after: .appInfo)` with **Check for Updates…**, disabled while `!updates.canCheck`.

Verify: `mise run build`, then `mise run lint`. A Debug build launched with `mise run run` has no Check for Updates… item.

## Step 5: Settings › About

**Files**: `packages/RedlampUI/Sources/Settings/SettingsView.swift`, `apps/RedlampMac/Sources/RedlampApp.swift`

- `SettingsView.init` gains `checksForUpdates: Binding<Bool>? = nil`, passed to `AboutSettings`, which shows `Toggle("Automatically check for updates", isOn:)` under the version line when it's set.
- `RedlampApp` passes `Binding(get: { updates.checksAutomatically }, set: updates.setChecksAutomatically)` when `appDelegate.updates` exists.

Verify: `mise run build` and `mise run test` (RedlampUI compiles and its tests pass). A Debug build's Settings › About shows no checkbox.

## Step 6: The feed's redirect

**File**: `web/next.config.ts`

`redirects()` answers `/appcast.xml` with a temporary redirect to `${site.github}/releases/latest/download/appcast.xml`. Temporary, so clients don't cache it and the feed can move later.

Verify: `cd web && npm run typecheck && npm run build`, then `npx next start -p 3123` and `curl -sI http://localhost:3123/appcast.xml` shows `307` and the GitHub location.

## Step 7: The appcast writer

**File**: `scripts/appcast.sh` (new)

`scripts/appcast.sh <Redlamp.app> <zip> <zip URL> <notes.md>` prints a one-item appcast: title, `pubDate`, `link` (`https://redlamp.app`), `sparkle:version` (`CFBundleVersion`), `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` (`LSMinimumSystemVersion` as three parts), `sparkle:fullReleaseNotesLink` (the GitHub releases page), the notes as `<description sparkle:format="markdown">` in CDATA, and an enclosure with the URL and `sign_update --account redlamp`'s signature and length. The tools come from `Tuist/.build` next to the script.

Verify: run it on a dry-run build from step 9's check (or any signed zip) and pass the output to `xmllint --noout -`.

## Step 8: The release script

**File**: `mise/tasks/release`

- `REF` (default `origin/main`) picks the commit; a real release fails unless it is `origin/main`.
- `xcodebuild` gets `REDLAMP_UPDATE_FEED=https://redlamp.app/appcast.xml`.
- After assembling the app: delete `Sparkle.framework/Versions/B/XPCServices` and its `XPCServices` link, then re-sign `Versions/B/Autoupdate`, `Versions/B/Updater.app` and the framework with `--force --options runtime --timestamp --sign "$IDENTITY"`, before the app is signed.
- Before notarizing: fail unless `generate_keys --account redlamp -p` equals the app's `SUPublicEDKey`.
- Notes: `Changes since <previous version>:` and `git log --no-merges --format='- %s' --invert-grep --grep='^Cask: ' <previous tag>..<commit>`, the previous tag from `git describe --tags --abbrev=0 --match 'v*'`.
- After zipping: `scripts/appcast.sh` (from the worktree) writes `appcast.xml` with the zip's release URL; `gh release create` uploads the zip and the appcast, with `--notes-file` and `--generate-notes`.
- After publishing: fetch the feed URL (retrying for a minute) and fail unless it lists the new build.

Verify: `REF=HEAD DRY_RUN=1 mise run release` succeeds. In `build/release/Redlamp.app`, `codesign --verify --deep --strict` passes, the XPC services are gone, and `codesign -dvv` on `Autoupdate` and `Updater.app` shows the Developer ID authority, a timestamp and `flags=0x10000(runtime)`. Info.plist's `SUFeedURL` is the redlamp.app URL. Then `mise run notarize -- build/release/Redlamp.app` is accepted.

## Step 9: An update, end to end

**File**: `scripts/test-update.sh` (new)

From `build/release/Redlamp.app` (a dry run), the script makes a new copy and an old copy under the bundle ID `app.redlamp.mac.update-test`, with the feed at `http://127.0.0.1:<port>/appcast.xml`. The old copy's `CFBundleVersion` is `1`. It re-signs both apps' outer bundles with the same Developer ID, zips the new copy, writes the feed with `scripts/appcast.sh`, serves it with `python3 -m http.server`, and opens the old copy. Interactively, you choose **Check for Updates…** and **Install Update**. With `--auto`, it turns on Sparkle's automatic checks and installs for the test bundle ID, waits for the installer, and quits the app. Either way it then waits until the old copy's `CFBundleVersion` is the new build, checks the signature, and removes the test bundle ID's preferences, caches and temporary files.

Verify: `scripts/test-update.sh --auto` reports the update; an interactive run shows Sparkle's alert with the notes.

## Step 10: README and version

**Files**: `README.md`, `Version.xcconfig`

- Installation: the app updates itself (asks on the second launch; Settings › About; Check for Updates…), and copies before 0.2.0-prealpha need one more download or `brew upgrade --cask redlamp`.
- Releasing: the signing key (generate once, back up), the feed and its redirect, notes from commit subjects, `REF` for dry runs and `scripts/test-update.sh`. The tasks table's release row mentions `REF`.
- `MARKETING_VERSION = 0.2.0-prealpha`.

Verify: `cd web && npm run build` (the site parses the README).

## Order

| Group | Steps | Can parallelize |
| --- | --- | --- |
| 1 | 1 | No |
| 2 | 2 | No (needs Sparkle's tools) |
| 3 | 3, 4, 5 and 6 | 6 is independent of 3–5 |
| 4 | 7 and 8 | No |
| 5 | 9 | No (needs a dry run from 8) |
| 6 | 10 | No |
| 7 | End-to-end verification: `mise run lint`, `mise run test`, `REF=HEAD DRY_RUN=1 mise run release`, notarize the dry run, `scripts/test-update.sh --auto` | No |
