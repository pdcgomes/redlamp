# Looks explainer videos: the brief for the promo studio

A handover for the chat that makes these videos with the promo studio (`.cursor/skills/redlamp-promo-studio/SKILL.md`). The owner asked for them on 8 October 2026. Nothing has been written or built yet.

## What the owner asked for

- **Two cuts explaining how looks are captured and contributed:** a short one for X and a longer one for YouTube. The idea is new and hard to convey in words, so the visuals carry it.
- **The pixel-art style of `~/src/pixelartvisuals`** as the explainers' visual language from now on.
- **The Redlamp intro (`video/src/introducing`) redone in that style,** so the explainers open the same way.

## The first deliverable

The design doc, `docs/plans/<date>-looks-explainer-promo.md`, following the studio's [brief.md](../../.cursor/skills/redlamp-promo-studio/brief.md): the brief, one to three concepts, five hooks, and the script and storyboard for both cuts ([script.md](../../.cursor/skills/redlamp-promo-studio/script.md)). That is owner checkpoint 1; nothing is built before he has seen the script.

## The story to tell

1. **The problem.** You have a filter you love, in a phone app that will never open your raw files.
2. **The idea.** Redlamp rebuilds the look from what the app outputs: run known images through the filter, compare each export with its original, and fit the colours, vignette and grain that turn one into the other. A measurement, not a guess.
3. **On the phone.** New Look (the app, the filter, its variant and settings), save the kit to Photos, apply the filter, export, share back to Redlamp Bench. Each export finds its kit image by itself, by barcode, name or content.
4. **In the Lab.** The reference arrives and is fitted into up to four candidates (Measured, Smoothed, Charts and photos, With film effects), each scored against the app's exports. Compare, pick, install under a name of your own.
5. **Contributing.** Anyone can send a look as its measurement: zip the reference, attach it to a GitHub issue titled "Look: …", or share it on the Discord. A kept look ships under a Redlamp name.

## Sources

| What | Where |
| --- | --- |
| The story, step by step, and contributing | [docs/bench-and-looks.md](../bench-and-looks.md) |
| The kit, the importer, the candidates, limits, accuracy | [docs/recipes/app-looks.md](../recipes/app-looks.md) |
| Screenshots of the Lab and the phone | `docs/images/bench/` |
| The pixel kit, its examples and the Redlamp architecture series | `~/src/pixelartvisuals` (`skill/`, `examples/`, `projects/redlamp-architecture/`) |
| The pixel promo already made, and the kit in the video project | [2026-10-07-pixelkit-promo.md](2026-10-07-pixelkit-promo.md), `video/src/pixelkit` |
| The intro to redo | `video/src/introducing` |

## Numbers it may use

- The owner's first reference from his phone, Wes 1: Measured 95.4, Charts and photos 92.7, Smoothed 92.2.
- Cine Film 1 (30 September): Measured 93.6, a mean colour difference of 0.58 ΔE from the app's export on a photo.
- The kit sets: Quick 1 image, Standard 5, Full 11.

## Constraints

- **No app or filter names on screen** (DEC-19): show a generic phone filter app, not Prequel's or Lightroom's interface.
- **The brand and the voice** ([docs/brand/README.md](../brand/README.md)): calm, plain, precise; every claim one the docs make. The owner's taste in music is dark and cinematic, not bright pop.
- **`video/` is shared with other sessions:** work in a worktree of its own (AGENTS.md has the commands).
