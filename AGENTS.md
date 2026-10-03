# Rules for agents working on Redlamp

Redlamp is a macOS raw editor in Swift and Metal (`README.md`). These rules apply to any agent working in this repository, and especially to domain agents working in parallel during an agent wave (`docs/plans/2026-10-03-wave-1-plan.md`).

## Environment

- **Tools sit behind mise.** Run `mise exec -- tuist generate --no-open` after adding or removing source files, and `mise exec -- swiftformat <files>` on every Swift file you change (CI lints the whole tree).
- **Build and test** with your own build directory:
  `xcodebuild test -workspace Redlamp.xcworkspace -scheme <Scheme> -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/<your-key>-dd -only-testing:<Target>/<Suite>`.
  Schemes: `RedlampEngine`, `RedlampEngineAPI`, `RedlampKernels`, `RedlampMasking`, `RedlampServices`, `RedlampDocument`, `RedlampRecipes`, `RedlampUI`, `Redlamp` (app), `redlamp` (CLI). Run targeted tests while working and your scheme's full suite once at the end; never run several full builds at once.
- **Swift Testing:** `xcodebuild` prints XCTest's "Executed 0 tests" plus one "Test run with N tests … passed" line per bundle. Read the Swift Testing lines.
- **A fresh worktree needs the gitignored build inputs.** From the worktree root, with `MAIN=/Users/pedrogomes/src/darkroom`, clone them (never symlink: scripts in the worktree would write into the main checkout):

  ```bash
  mkdir -p tests/fixtures vendor Tuist
  cp -cR "$MAIN/tests/fixtures/raw" tests/fixtures/
  [ -d "$MAIN/tests/fixtures/shoots" ] && cp -cR "$MAIN/tests/fixtures/shoots" tests/fixtures/
  cp -cR "$MAIN/vendor/build" "$MAIN/vendor/cache" vendor/
  cp -cR "$MAIN/Tuist/.build" Tuist/
  mise exec -- tuist generate --no-open
  ```

- **Sandbox:** the npm and yarn registries are unreachable; don't add packages of any kind (Swift packages included). PyPI works for research scripts. Never print secrets (the Hugging Face token in `~/.cache/huggingface/token` included).
- **Headless Chrome**, if you need it, starts only with `--no-sandbox --disable-gpu-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader` and a throwaway `--user-data-dir`.

## Working in parallel

- **Stay inside the paths you own** (the plan's table). Everything else is read-only, including `EditRecipe.currentProcessVersion`, `docs/research/research-tracker.md`, `README.md`, this file, the plan, `Project.swift`, `Workspace.swift` and `.github/`. Ask for changes in your final report.
- **Bugs that produce wrong pixels** (NaN, black or out-of-range values) are fixed in every process version: no edit relies on them. A reference that recorded such a pixel is re-recorded in the same change, and the commit says which pixels changed and that nothing else did.
- **No agent changes how an existing edit renders.** A rendering change needs a new process version, and that is the orchestrator's call. The process-stability gate (`ProcessStabilityTests`) catches it; a new version records its references with `TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1`, which writes only missing ones, and raises the process version's maximum in `docs/recipes/sidecar-format.schema.json` and its table in `sidecar-format.md` (`SidecarSchemaTests` checks both).
- **Off limits:** removal (RM-*), the audit fixes (AUD-*), noise (DN-*), `video/` and `web/`; other sessions are working there.
- **Commit to your own branch** in small, described commits. Never push, merge or rebase onto `main`.
- **Commit messages** are short and name the tracker row and its issue: `LCP lens profiles: parse and match (LNS-04, #82)`.

## Conventions

- Write code that reads like the code around it: its naming, comment density and idiom. Comments state constraints the code can't show; not what the next line does, nor why your change is right.
- Tests sit with their package (`packages/<Package>/Tests`) and use Swift Testing (`@Test`, `#expect`, backticked names that read as sentences).
- Docs are plain and precise, in complete sentences, with no superlatives.
- Licences: implement from published specifications and papers. Never copy code from GPL projects, and never ship or convert Adobe's files.

## Reporting during a wave

The orchestrator's tracker canvas has one progress line per agent between `// AGENT_PROGRESS:BEGIN` and `// AGENT_PROGRESS:END`. Update only your own line, as your brief describes, when you start, after each milestone, when blocked and at the end.
