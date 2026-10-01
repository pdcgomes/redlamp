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

### Feed and publishing

- **Feed URL:** `https://redlamp.app/appcast.xml`. The site answers it with a temporary redirect (`redirects()` in `web/next.config.ts`) to `https://github.com/pdcgomes/redlamp/releases/latest/download/appcast.xml`, which GitHub serves from the release marked Latest. Publishing a release publishes the update, with no website deploy or commit. The URL every installed copy checks is on our domain, so the feed can move later (to a generated feed, channels or another host) without stranding them.
- **Appcast:** after stapling and zipping, `mise run release` runs `scripts/appcast.sh`, which writes a one-item `appcast.xml`: build number, version, minimum macOS (from the built app's `LSMinimumSystemVersion`), the zip's URL on the release, and its EdDSA signature and length from Sparkle's `sign_update`. Both go up in the same `gh release create`. The tools come from the resolved package (`Tuist/.build/artifacts/sparkle/Sparkle/bin`), so they match the framework.
- **Release notes:** the commit subjects since the previous release tag, as a Markdown list, without the cask workflow's `Cask: redlamp …` commits. Sparkle shows Markdown embedded in the appcast item (2.9 and later). The same list is the GitHub release's notes, ahead of GitHub's "Full Changelog" link; nothing lands through pull requests, so GitHub's generated notes alone are only that link.
- **Check:** after publishing, the script fetches the feed URL and fails unless it lists the new build, which proves the redirect, the Latest flag and the asset line up.
- **Not now:** delta updates, channels and signed feeds (`SURequireSignedFeed`). A signed feed protects only the notes and links, since the archive's signature already protects the code, and it requires `SUVerifyUpdateBeforeExtraction`, after which a new EdDSA key can only arrive in a Developer ID–signed disk image.

### The app

- **Dependency:** Sparkle 2.10.0, pinned, through Tuist (`Tuist/Package.swift`, with `Package.resolved` committed), the project's first external package. `mise run generate` runs `tuist install` first. Only the app target links it.
- **Which builds update:** only builds made by `mise run release`, dry runs included. `SUFeedURL` in Info.plist is `$(REDLAMP_UPDATE_FEED)`, which only the release script sets, and the app creates no updater without it. A Release build from source has build number 1, so with Sparkle running it would take any release as an update and replace a newer source build with an older app.
- **Info.plist:** `SUFeedURL` and `SUPublicEDKey`, nothing else. Sparkle's defaults stand: it asks on the second launch whether to check automatically, checks daily, and its alert offers to install future updates automatically.
- **App:** `AppDelegate` owns `Updates`, an `@Observable` wrapper around `SPUStandardUpdaterController` that follows `canCheckForUpdates` and `automaticallyChecksForUpdates` by KVO. **Check for Updates…** follows About in the app menu, disabled while a check runs. Settings › About has an "Automatically check for updates" checkbox bound to Sparkle's own setting, which Sparkle keeps in user defaults, so there's no second copy. `SettingsView` takes it as an optional `Binding<Bool>`, since RedlampUI doesn't link Sparkle. Builds without an updater show neither.

### Signing and keys

- **Signing:** Sparkle ships its helpers ad-hoc signed, and Code Sign on Copy re-signs only the framework, so the release script finishes the job as Sparkle documents for apps signed outside Xcode's archive-and-export. It deletes the XPC services, which only sandboxed apps use, then re-signs `Autoupdate`, `Updater.app` and `Sparkle.framework` with the Developer ID, the hardened runtime and a timestamp, before signing the app.
- **Keys:** `generate_keys --account redlamp`, run once on the release Mac, keeps the EdDSA private key in the login keychain under its own account, apart from any other app's; the public key goes in Info.plist. Export a backup with `generate_keys --account redlamp -x <file>` to the password manager and delete the file. If the key is lost, the next update has to change to a new one, which Sparkle accepts only because the app's Developer ID certificate stays the same; losing both at once would strand every installed copy.
- **Check:** before notarizing, the release fails unless the keychain's key matches the app's `SUPublicEDKey`.

### Testing

- `codesign --verify --deep --strict` and notarization check the signing on every release. `REF=<commit> DRY_RUN=1 mise run release` builds a commit that isn't on `origin/main` yet, such as changes to the release itself; a real release only builds `origin/main`. Notarizing a dry run with `mise run notarize` checks the signing without publishing.
- `scripts/test-update.sh` runs a real update locally. It takes a dry-run build and makes two copies under a test bundle ID, so Sparkle's state stays out of the real app's preferences: an old one with build number 1 and a new one, zipped and signed. It serves the zip and a one-item appcast (from `scripts/appcast.sh`) on `127.0.0.1` and opens the old copy; **Check for Updates…** should download, verify, install and relaunch it as the new build. Sparkle accepts a plain-HTTP feed when updates carry EdDSA signatures, and App Transport Security lets apps reach loopback addresses.

### Rollout

- **First Sparkle release:** 0.2.0-prealpha, once the redirect is live. Copies of 0.1.0-prealpha and 0.1.1-prealpha can't update themselves, so their users download once more or run `brew upgrade --cask redlamp`.
- **Cask:** `auto_updates true`, so `brew upgrade` leaves Sparkle-managed installs alone, waits for the release after 0.2.0-prealpha. Plain `brew upgrade` skips casks marked that way (naming the cask still upgrades it), so adding it with 0.2.0-prealpha would leave Homebrew installs of 0.1.x behind.
