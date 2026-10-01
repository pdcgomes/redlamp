# Releases and updates: design

The owner's goal: publish the first release, offer it from redlamp.app, version the app with its stage in plain view, and then keep installed copies up to date automatically. The first three ship with 0.1.0-prealpha; automatic updates are a separate iteration.

## Versions

- `MARKETING_VERSION` in `Version.xcconfig` is semver with the stage as a pre-release suffix until 1.0: `0.1.0-prealpha`, then `-alpha` and `-beta`. It appears unchanged in the About window, the tag (`v0.1.0-prealpha`), the zip, the release title and the Homebrew cask.
- The build number (`CFBundleVersion`) is the number of commits in the released commit's history, stamped by `mise run release`. It only goes up, which Sparkle relies on: it compares build numbers, not version strings, so the suffix never affects update order.
- GitHub releases are not marked as prereleases, even though the versions are. The site's download button, the cask workflow and Homebrew's livecheck all follow the release marked Latest, which a prerelease can't be. The release script passes `--latest`.

## Releasing

`mise run release` always builds `origin/main` in a temporary worktree, so uncommitted or untracked work in the checkout (other agents' included) never ships, and the tag points at exactly what was built. It reuses the checkout's vendored LibRaw when its stamp matches the pin. It refuses to run while `Version.xcconfig` has unpushed changes, so a forgotten push can't publish the previous version. `DRY_RUN=1` makes the same build and stops after signing.

## Download button

- `latestRelease()` in `web/lib/github.ts` reads the latest release, revalidated hourly like the star count. The hero shows **Download for Mac** first, next to View on GitHub and Build from source, linking to the release's `Redlamp-<version>.zip`. The status pill shows the version: "Pre-alpha 0.1.0 · macOS 26".
- Before the first release, GitHub answers 404 and the button is hidden. If GitHub can't be reached, the button links to the latest release's page without a version, so the main action never disappears.

## Iteration 2: automatic updates with Sparkle

Sparkle 2 is still the standard for Mac apps distributed outside the App Store (2.10.0, September 2026), and Apple offers no replacement. A Mac App Store build would get its updates from the store and must leave Sparkle out.

- **Dependency:** Sparkle 2.10.x, pinned, through Tuist (`Tuist/Package.swift` and `tuist install`), the project's first external package. Only the app target links it.
- **App:** an `SPUStandardUpdaterController` owned by `AppDelegate`, a **Check for Updates…** item after About in the app menu, and an "Automatically check for updates" toggle in Settings › About. Debug builds don't start the updater, so a local build never offers to replace itself with a release.
- **Info.plist:** `SUFeedURL` is `https://github.com/pdcgomes/redlamp/releases/latest/download/appcast.xml`, plus `SUPublicEDKey`. Sparkle's default stands: it asks on the second launch whether to check automatically.
- **Keys:** `generate_keys`, run once on the release Mac, keeps the EdDSA private key in the login keychain; the public key goes in Info.plist. Export a backup with `generate_keys -x` to the password manager: without the private key, installed copies can't accept further updates.
- **Signing:** Sparkle's helpers (Installer.xpc, Downloader.xpc, Autoupdate, Updater.app) need the Developer ID, the hardened runtime and a timestamp to pass notarization. Sparkle documents the commands for apps signed outside Xcode's archive-and-export, which is the release script's case; it runs them before signing the app.
- **Feed:** after stapling and zipping, the script runs `sign_update` on the zip and writes a one-item `appcast.xml` (build number, version, minimum macOS 26.0, the zip's URL, its signature and length, and a link to the release notes). Both go up in the same `gh release create`, so publishing a release publishes the update, with no website deploy or commit. The tools come from the resolved package (`Tuist/.build/artifacts/sparkle/Sparkle/bin`), so they match the framework.
- **Cask:** add `auto_updates true`, so `brew upgrade` leaves Sparkle-managed installs alone (`--greedy` still upgrades them).
- **First Sparkle release:** 0.2.0-prealpha. Copies of 0.1.0-prealpha can't update themselves, so their users download once more or run `brew upgrade`.
- **Testing:** notarize a dry-run build with `mise run notarize` to prove the helpers are signed correctly. Then run an update end to end: install an older build whose feed points at a local appcast listing a newer dry-run zip, and check that it downloads, verifies, installs and relaunches.
