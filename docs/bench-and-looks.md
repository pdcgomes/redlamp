# Looks and the bench

Redlamp has two workflows that take a photo out to another app and bring the result back to measure it:

- **Comparing with Lightroom and other apps.** An agent working on Redlamp needs to know what Lightroom does with a mask, a slider or an export. It writes a bench task, the owner does it in Lightroom on his phone, and the exports come back to the agent.
- **Capturing looks.** A filter in Prequel, a Lightroom preset or a grade made in any other app is run over Redlamp's capture kit, and the Recipe Lab rebuilds it as a Redlamp look from what the app exported.

Both run on the same pieces: an iPhone app, Redlamp Bench, and a hub in the Recipe Lab on the Mac. This page explains why each exists, how it works from start to finish, and how to contribute a look. The details are in [bench-tasks.md](bench-tasks.md) (the folder format, the hub and the app) and [recipes/app-looks.md](recipes/app-looks.md) (the capture kit, the importer and the candidates).

## Why they exist

### Comparing with Lightroom

Redlamp is measured against Lightroom: [lightroom-comparison.md](lightroom-comparison.md) lists every feature beside Lightroom's, and many decisions in the research tracker end in "measure Lightroom, then match it". DEC-08 is one: when two masks are intersected, does Lightroom multiply them or take the smaller of the two? Nothing in Lightroom's documentation says, and an agent can't run Lightroom. The owner can, on his phone.

Before the bench, each such question meant a chat message describing the steps, files sent by AirDrop in both directions, exports renamed by hand so they could be told apart, and an agent waiting on a person it couldn't reach. The bench turns that into a task the agent writes once and reads back when it's done. The owner sees one step at a time, with the photos one tap from Lightroom, and the exports find their way back without being renamed or moved.

### Capturing looks

Many photographers have a filter they keep returning to, in an app that will never open their raw files. Redlamp can rebuild such a look from the app's own output: run a set of known images through the filter, compare each export with the original, and fit a colour table, a vignette and grain that turn one into the other. The measurement isn't a guess at the look; it is what the app did to every colour on the charts.

That process was first done by hand on 30 September for a few Prequel filters: AirDrop the kit to the phone, apply the filter, AirDrop the exports back, then one command per filter on the Mac. It worked, but it was too slow to do for more than a handful of filters. The look workflow keeps the measurement and removes the bookkeeping, so capturing a filter takes a few minutes on the phone and a choice in the Lab.

## The pieces

| Piece | What it does |
| --- | --- |
| A bench folder | One task or look reference: `task.json` (the steps, the photos and what counts as complete), the photos in `assets/`, and the exports in `results/` once they're back |
| Redlamp Bench, the iPhone app | Pulls tasks from the Lab, shows each step one at a time, shares or saves the photos, takes the exports back through the share sheet, and sends the folder to the Lab once it's complete. New Look starts a look reference on the phone |
| The hub, in the Recipe Lab | Runs in the harness on the Mac, found on the local network with Bonjour. It serves the waiting tasks and the capture kit to the phone, and checks what comes back before filing it in Done |
| `redlamp task` | Writes, checks, lists and reads tasks from the command line |
| The `redlamp-bench` skill | Tells an agent when to ask for a bench task and how to write its steps |

The phone finds the Lab by itself on the same network. It pairs once: tap Pair on the phone and Allow in the Lab's Bench tab.

## Comparing with Lightroom, step by step

1. **An agent writes a task.** It makes the photos the question needs (for DEC-08, four flat grey frames, numbered), and writes the steps in plain words: one action per step, with the exact menu path and values. `redlamp task new` puts it in the Lab's outbox.
2. **The phone pulls it.** Redlamp Bench lists it under To do, with who asked and why.
3. **The owner follows the steps.** Each step fills the screen. The first one shares the photos to Lightroom; the ones after say what to do there ("Masking › Create New Mask › Linear Gradient, from the left edge to the right edge, Exposure −2.00"); one may ask a question with fixed answers. Back and Next move between steps, and All Steps shows the whole list.
4. **The exports come back.** In Lightroom, export and share to Redlamp Bench. The share sheet suggests the last task used and pairs each export with the photo it came from: by file name first, then by the capture kit's barcode, then by the image itself. It shows which photo each export matched.
5. **The phone sends the task.** As soon as every photo has its export and every question has an answer, the task goes to the Lab, with its progress shown on the phone. If the Lab isn't reachable, it waits on the phone and goes when it is.
6. **The agent reads the results.** The task lands in `Done/` on the Mac, and the agent measures the exports against what Redlamp makes from the same photos. For DEC-08, that settles whether Redlamp's Intersect should multiply or take the minimum.

Lightroom's exports stay on the owner's Mac, in the bench's `Done` folder. They are references for a measurement, never committed to the repository or shipped: what Redlamp keeps is the decision and, where the tracker allows it, numbers measured from them (DEC-17, DEC-41).

The same task works for any app on the phone: Photos, Prequel, a camera maker's app. A task names its app, and the steps say what to do in it. For an app on the Mac, `redlamp task add` files the exports into the task instead of the share sheet.

## Capturing a look, step by step

1. **New Look, on the phone.** Fill in the app, the filter's name as the app shows it, its variant, and the settings used, as free notes, so the record says exactly which look was captured. A screenshot of the filter's settings can go with it. Then choose how many images to run through the filter:

   | Set | Images | When |
   | --- | --- | --- |
   | Quick | 1: the one-image kit, a single chart with eight small photo tiles | Most filters: one apply and one export |
   | Standard | 5: the three full charts and two photos (a high-contrast scene and a portrait) | A filter worth a closer fit |
   | Full | 11: the three charts and all eight photos | A filter with grain, glow or other effects to match |

2. **Save the kit to Photos** from the first step, apply the filter to each image in the other app, and export at full size with no crop.
3. **Share the exports to Redlamp Bench.** The share sheet suggests the reference just made; when that one is complete, it offers a new one with the next variant. Charts pair by their barcodes and photos by name or by content, and the sheet shows each match.
4. **The reference goes to the Lab** once every image of its set is back. The Lab fits it as it arrives and posts a notification when it's ready.
5. **Evaluate it in the Recipe Lab's Looks tab.** Each reference is fitted into up to four candidates:
   - **Measured:** the table as the charts measured it, with their vignette and grain.
   - **Smoothed:** the same table with the noise of JPEG compression and patch spread smoothed out.
   - **Charts and photos:** a fit to the charts and the photos together, with two photos or more.
   - **With film effects:** the best of the others with grain, bloom or halation added, kept only when that matches the photos better.

   Each candidate renders the kit photos through Redlamp's engine and is scored against the app's own exports, on colour difference, grain, sharpness and glow. Compare any candidate with the app's export on each photo (Split, A | B or Flicker), and pick between two when it's close: the picks are recorded to tune the score.
6. **Install it** under a name of your own. The Lab refuses a name that contains the app's or the filter's name; those are kept only in the look's private record (DEC-19).

On the Cine Film 1 capture of 30 September, the measured candidate scored 93.6, with a mean colour difference of 0.58 ΔE from the app's export on a photo, rendered through the engine.

### What a look can and can't capture

A look becomes a table when the filter does the same thing to every photo. Filters that adapt to each image (auto tone, scene detection, "smart" or AI filters) give a different transform each time, and local effects such as face retouching, sky replacement, portrait blur and texture overlays can't be captured at all. Vignettes, grain and glow are matched with Redlamp's own effects, which come close but not exactly. The Lab reports when a capture shows any of these. [app-looks.md](recipes/app-looks.md#limits) lists every limit.

## Contributing a look

A contributed look reaches Redlamp as its measurement, not as a finished recipe: the exports and the record of the filter that made them. The fit can then be redone as the Lab improves, and the look can be checked against its own exports.

**What makes a good contribution.**

- A look that is the same on every photo: a Lightroom preset, a filter in a phone app at a fixed strength, or a grade you made in any editor.
- Looks you made yourself are the most welcome: your own Lightroom presets or grades. They are your work to give.
- The Standard or Full set, so there are photos to score against, exported at full size with no crop, rotation, frame or watermark.
- The record filled in: the app, the filter, its variant and the settings used, and a name of your own for the look.

**How to capture one today.** The iPhone app is the owner's tool for now, installed from Xcode (DEC-53), so a contributor uses Redlamp's command line, built from source:

1. `mise run lookdev` fetches the raws the kit photos are made from. Then `redlamp recipe app-kit` writes the full kit and `redlamp recipe app-kit --compact` the one-image kit, in `build/app-looks/`. `redlamp recipe app-kit --task` publishes both as the template look references start from.
2. `redlamp task look --app "…" --filter "…" --variant "…" --settings "…" --set standard --in <folder>` makes a look reference with the kit images in its `assets/`.
3. Run those images through the filter on the phone or the Mac, and export them.
4. `redlamp task add <reference folder> <exports…>` files and pairs the exports, as the share sheet does. `redlamp task check <reference folder>` says whether anything is missing.
5. `redlamp recipe app-import <reference folder> --name "Your name" --candidates` fits it and writes the candidates, their scores and a contact sheet, to look at before sending.

**How to send it.** Zip the reference folder and attach it to a [GitHub issue](https://github.com/pdcgomes/redlamp/issues) titled "Look: " and your name for it, or share it on the [Redlamp Discord](https://discord.gg/4VZpxpgRCA). Say in the issue that you made the exports yourself.

**What happens to it.** The owner fits it in the Recipe Lab and compares the candidates with your exports. A look that's kept is given its final name, checked by the recipe linter, recorded as a golden render and shipped in a later release, as any bundled look is ([look-development.md](recipes/look-development.md#shipping-a-recipe)). A shipped look never carries the app's or the filter's name; that stays in the private record.

## Further reading

- [bench-tasks.md](bench-tasks.md): the bench folder, pairing, the hub's API, the iPhone app and the commands.
- [recipes/app-looks.md](recipes/app-looks.md): the capture kits, the importer, the candidates and their score, the limits and the accuracy tests.
- [recipes/look-development.md](recipes/look-development.md): the Recipe Lab, recipes and how a look ships.
- `.cursor/skills/redlamp-bench/SKILL.md`: how an agent writes a bench task.
