# Tools: `rl`

`rl` is the repository's launcher (`tools/rl`). Run it alone for a menu of the tools; each tool is also a command, `rl <group> <tool>`, with its answers in order. `rl status` says where things stand: the branch, the bench's hub and folders, the builds and the last push gate. This page is generated from `tools/rl/registry.toml` by `rl docs`; `rl check` (in `mise run lint`) fails when a mise task or `redlamp` subcommand is in neither the registry nor its `later` list, or when this page is out of date.

To have `rl` everywhere: `alias rl="$HOME/src/darkroom/bin/rl"` in `~/.zshrc`. In a worktree it runs that worktree's tools. `mise run rl` works too.

## Bench tasks

Steps for the owner in Lightroom or another app, through the iPhone app and the Recipe Lab's hub (docs/bench-tasks.md).

| Command | What it does |
| --- | --- |
| `rl bench lab` | The harness at the Recipe Lab's Bench tab: the hub, pairing requests, phones nearby, what waits and what came back. ([doc](bench-tasks.md#in-the-recipe-lab)) |
| `rl bench list` | What waits in the outbox and what came back to Done. |
| `rl bench show <task>` | A task's results and how each one paired. |
| `rl bench new <draft>` | A task in the outbox from a draft.json, for the phone to pull. ([doc](../.cursor/skills/redlamp-bench/SKILL.md)) |
| `rl bench check <task>` | What's wrong with a task in the outbox, as the hub sees it. |
| `rl bench wait <task> <timeout>` | Returns once the task is back in Done and complete. |
| `rl bench withdraw <task>` | Takes a task back; the phone drops it unless it has results. |
| `rl bench serve` | The hub in the terminal, until interrupted: y or n for pairing requests, and what arrives. |
| `rl bench folders` | Outbox, Done and Templates in the Finder. |

## Looks

Looks captured from other apps: the kit, references, fitting and evaluating (docs/bench-and-looks.md).

| Command | What it does |
| --- | --- |
| `rl looks lab` | The harness at the Recipe Lab's Looks tab, where references are fitted as they arrive and evaluated. ([doc](recipes/app-looks.md#candidates-and-the-looks-tab)) |
| `rl looks show <reference>` | A reference that came back: its filter, settings and how each export paired. |
| `rl looks fit <reference> <name>` | app-import with its candidates, report and contact sheet, into build/app-looks/out/<name>/. ([doc](recipes/app-looks.md#the-importer)) |
| `rl looks new <app> <filter> [variant] [settings] <set> [folder]` | A reference from the kit, as New Look makes on the phone, for a filter in a Mac app. |
| `rl looks add <folder> <files>` | Files exports into a task or reference and pairs them, as the share sheet does. |
| `rl looks kit` | Writes both kits and publishes them as the template new references start from. ([doc](recipes/app-looks.md#the-full-kit)) |
| `rl looks raws` | The CC0 raws the kit photos and look development use. |

## The apps

Redlamp, the harness and the Recipe Lab, built from this checkout.

| Command | What it does |
| --- | --- |
| `rl app run` | Builds and opens the Mac app. |
| `rl app harness [scene]` | The component harness, at a scene if you pick one. |
| `rl app build <scheme>` | One scheme, into build/DerivedData. |
| `rl app generate` | Tuist, after adding or removing source files. |

## iPhone

Redlamp Bench, the iPhone app.

| Command | What it does |
| --- | --- |
| `rl iphone install <device>` | Builds the app for a connected iPhone and installs it. |
| `rl iphone simulator <simulator>` | Builds the app for the simulator, then installs and opens it there. |

## Tests and checks

Tests, lint, the push gate and the tracker's sync.

| Command | What it does |
| --- | --- |
| `rl test scheme <scheme>` | One scheme's tests, with Swift Testing's results. |
| `rl test all` | The purity gate and all unit tests, as mise run test does. |
| `rl test lint` | Purity, licences, the roadmap and camera checks, SwiftFormat, SwiftLint and rl check. |
| `rl test gate <commit>` | CI's checks and the build's tests on a commit, as the push to main runs them. |
| `rl test suite <commit>` | The push gate with every test, as CI runs it; for work that spans packages. |
| `rl test e2e [tier]` | The smoke tier by default, in a home of its own. |
| `rl test tracker` | The roadmap and Lightroom comparison against the tracker, then the issue sync's dry run. |

## Not in the menu yet

Run these as before; they join the menu as they're described in the registry.

- **mise tasks:** `fixtures`, `fixtures-shoots`, `maskeval`, `notarize`, `profile-data`, `release`, `render`, `screenshots`, `setup`, `site`, `vendor`, `video`
- **redlamp subcommands:** `stack`, `mask`, `noise`, `bench`, `camera-bench`, `library`, `mcp`
