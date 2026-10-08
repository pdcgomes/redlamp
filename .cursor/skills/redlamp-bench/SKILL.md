---
name: redlamp-bench
description: Redlamp Bench, the way an agent asks the owner to do a step in another app and gets the results back without anyone moving files. The agent writes a bench task (a folder with a manifest, one-screen steps and reference images) with `redlamp task new`; the owner's iPhone pulls it from the Recipe Lab's hub, he follows the steps in Lightroom (or Prequel, Photos, another app) and shares the exports back, and the phone sends the task to Done once every result is paired. Use whenever you need the owner to check, measure, compare or produce something in Lightroom or another app (Lightroom's masks, sliders, presets or exports against Redlamp's), when you're about to ask him to add photos to Lightroom and send results back, when writing such a task's steps, or when reading a task's results.
---

# Redlamp Bench: a step in another app, as a task

When work needs Lightroom's own answer, such as how its masks combine, what a slider does to a ramp or what a preset renders, don't ask the owner to move photos around. Make a **bench task**. It reaches his phone by itself, opens on its steps one at a time, and comes back to a folder you can read, with each result paired with the photo it came from. [docs/bench-tasks.md](../../../docs/bench-tasks.md) has the format, the hub and the app in full.

**Use it for:** anything only the owner can do in another app, with files going in and coming out: Lightroom checks (masks, sliders, profiles, presets, exports), and a phone app's output on given images.

**Don't use it for:**
- What you can measure yourself, from the CLI or tests.
- A question with no files: put that on your workstream canvas's Needs you instead.
- A phone app's filter to rebuild as a Redlamp look: the owner makes those himself on the phone as look references (New Look).

## How a task travels

1. You run `redlamp task new`. The task lands in `~/Library/Application Support/Redlamp/Bench/Outbox/<id>/`, outside every checkout, so it doesn't matter which worktree you're in.
2. When the owner's iPhone can reach the Recipe Lab's hub (the harness open on the Recipe Lab with its Bench tab's Receive on), Redlamp Bench pulls the task.
3. He follows the steps: share the photos to Lightroom, do exactly what each step says, export, and share the exports back to Redlamp Bench. Each export pairs with its photo.
4. Once every photo has its result and every required question has an answer, the phone sends the task back. It's checked as untrusted input and filed in `.../Bench/Done/<id>/`, and it leaves the outbox.

## Make the task

Build the CLI once (`SCHEME=redlamp mise run build`), then use `build/DerivedData/Build/Products/Debug/redlamp`. It's written `redlamp` below.

**Quick form,** for a few photos and plain steps:

```bash
redlamp task new --title "Sky masks on the coverage set" --app "Lightroom" \
    --workstream masking --tracker MSK-16 --issue 52 \
    --step "Select Sky on each | Masking › Create New Mask › Select Sky, nothing else." \
    --step "Show the mask | Set the mask's Exposure to −2.00, nothing else." \
    --step "Export | JPG, quality 100, full size, sRGB, no output sharpening, original file names." \
    --question "edge | Did Select Sky miss any sky at the trees? | Yes, No, Partly" \
    photos/*.dng
```

Without `--no-auto-steps`, it adds a first step that shares the photos to the app and a last one that waits for the results. Add `--manual` when the number of results isn't one per photo; the owner then marks the task done.

**Draft form,** when steps need actions, pictures or their own pairing: write a draft as `task.json`'s fields, with each asset as `{"source": "path", "id", "label", "counts"}` and step pictures listed in `"pictures"` (copied into `pictures/`, named in steps as `pictures/<name>`). Then run `redlamp task new --draft draft.json`. [examples/dec-08](examples/dec-08) is a complete one, with the script that made its photos.

Then run `redlamp task check <id>`, and fix every error and warning.

### Steps that work on a phone

The app shows one step at a time, full screen, while the owner switches between it and Lightroom:

- **One action per step:** "Frame 1: gradient A", not "make the gradients and export". `check` warns when a step's detail won't fit one screen (over 320 characters) or its title is over 60.
- **Lightroom's own words and exact values:** menu paths as Lightroom shows them (Masking › Create New Mask › Linear Gradient), every value with its sign and decimals (Exposure −2.00), and "nothing else" when other settings must stay at their defaults.
- **Say how to export, once, in its own step:** TIF if offered (otherwise JPG at quality 100), full size, sRGB, no output sharpening, and original file names.
- **Give a step an action** when it has one. `share` and `save` put the photos one tap away; `results` waits for the exports and ticks itself; `answer` asks a question.
- **A picture** (`"picture": "pictures/where.png"`) when a setting is hard to find.

### Assets that pair

- **Name assets for what they're for** (`1-gradient-a.tif`, `exposure-plus-50.jpg`): with original file names on export, each result pairs by name.
- **Make look-alike assets distinguishable.** When several assets are the same picture with different instructions, put a visible label in a corner (as the DEC-08 frames do). That tells the owner which is which in Lightroom, and lets similarity pair them if Lightroom renames the exports.
- **Keep tasks small:** at most 20 assets and 1 GB.
- **Use fixture, CC0 or synthetic images only,** never the owner's own photos.

## Make Lightroom's results measurable

Lightroom only gives back rendered images, so design the task so that the export answers the question:

- **A mask:** apply one fixed adjustment inside it (Exposure −2.00, nothing else) on a flat or known image, and export an untouched copy as the baseline. In linear light, Exposure −2 scales by 2^(−2m), so the mask's strength at each pixel is m = −log2(out / baseline) / 2. Keep the adjustment moderate: −4 crushes the strong end into a few 8-bit levels.
- **Combining masks:** two masks that vary along different axes (two crossing linear gradients), exported alone and combined. A product and a minimum differ everywhere both are partial. This is DEC-08's task, [examples/dec-08](examples/dec-08).
- **A slider:** one copy of the photo per value (`exposure-minus-100`, …, `exposure-plus-100`), each with its own step, so each result pairs by name and its value is known.
- **Profiles and presets:** apply them to a known image, such as the capture kit's charts (`build/app-looks/kit`) or a fixture. For a phone app's filter to rebuild as a look, see the owner's look references instead.

Results are references only: never commit them or ship them, and never convert or ship Adobe's files (AGENTS.md).

## Tell the owner

Add a Needs you item on your workstream canvas (`.cursor/skills/workstream-canvas/SKILL.md`):

- **Title:** "Do the <task title> task in Lightroom".
- **Detail:** where it comes from ("It appears in Redlamp Bench on your phone while the harness's Recipe Lab is open, Bench tab on"), roughly how long it takes, and what you'll do with the results.
- **Unblocks:** the row it unblocks; mark it `blocking` when your work waits on it.
- **Command:** `mise run harness -- --scene recipe-lab --lab-tab bench`.

Then carry on with other work; don't wait in a loop for hours.

## Read the results

- **`redlamp task show <id>`:** each asset's result, how it paired (file name, barcode, similarity with its score, or by hand), the answers and the owner's note. Add `--json` for the manifest and `results.json` together.
- **`redlamp task wait <id> --timeout 60`:** returns once the task is in Done and complete; exit 2 means it isn't yet.
- **The files:** in `Done/<id>/results/`, byte for byte as the other app exported them. `results.json` names each one's asset. An unpaired result (`asset` absent) is one the phone couldn't place: compare it with the assets yourself, or ask the owner.
- **Record what you measured:** on your canvas, and in the tracker row's Status or the decision it settles. Name the task's ID.

## Changing or taking back a task

- **Before the phone has it,** edit the outbox folder freely, then run `redlamp task check` again.
- **After it's been pulled:** run `redlamp task withdraw <id>`. The phone drops it unless it already has results. Then make a new task with a new ID. Never reuse an ID.
- **Done folders stay,** as the record of what Lightroom answered.
