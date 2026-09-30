# darktable study: conventions

Rules every note in this folder followed. The synthesized result is
[darktable-findings.md](../../darktable-findings.md).

## Goal

Learn from darktable, the most complete open-source raw developer, how it handles cameras, lenses,
color science, modules, masks, presets, styles, profiles, sidecars, performance and UX, so Redlamp can
package the same capabilities in a native macOS/iOS app with Lightroom familiarity and better
usability. For every area, say what Redlamp should **adopt** (the idea or approach), **do better**
(same capability, better design or UX), or **skip**, mapped to the Redlamp roadmap phases.

## Sources (local shallow clones under `build/oss/`, not committed)

| Project | Path | License | Version |
| --- | --- | --- | --- |
| darktable | `build/oss/darktable` | GPL-3.0 | 5.8.0 release notes; master of 2026-09-29 (426d8ad) |
| darktable user manual | `build/oss/dtdocs` | GPL-3.0 | master |
| rawspeed | `build/oss/rawspeed` | LGPL-2.1 | master of 2026-07-28 (c835b05) |
| lensfun | `build/oss/lensfun` | library LGPL-3.0; database CC BY-SA 3.0 (verify) | master of 2026-09-24 (bbd4332) |

Online: https://docs.darktable.org, https://www.darktable.org/blog, https://discuss.pixls.us, and the
papers darktable's modules cite.

## Code and data rules (Redlamp is MPL-2.0 and ships on the App Store)

- **Reading darktable's source is allowed for understanding.** The project owner decided this on
  2026-09-30, overriding the stricter clean-room wording in the README (flag this in the findings).
- **Never copy code, and never paste code excerpts longer than a signature or a one-line formula into
  these notes.** Describe algorithms in prose and math, and cite the file path and the paper.
- **darktable's data files are GPL** (`noiseprofiles.json`, `wb_presets.json`, styles, presets,
  cameras data, LUTs). Redlamp can't ship them. Note their structure and size, not their contents.
- rawspeed is LGPL-2.1: note whether linking it would even be workable for an App Store binary.
- Separate **Evidence** (what the source, manual or a paper shows, with file path or URL) from
  **Assessment** (our opinion). Mark anything unverified.

## Redlamp context

Read `README.md` and `docs/lightroom-feature-inventory.md` in the repo. Short version: Swift + Metal,
Apple Silicon only, scene-referred linear Rec.2020 pipeline, LibRaw for unpacking only (everything
else is our own GPU code), one fused develop kernel, mip-pyramid cache, value-type engine API, JSON
sidecars, Lightroom-familiar UI, < 16 ms slider latency, Phase 1 (now) through Phase 4 (1.0).
The AI research is in `docs/research/ai-findings.md`; don't repeat it, cross-reference it.

## Note format

1. Summary: the 5–10 most important things to learn, each with adopt / do better / skip and a phase.
2. Detailed findings per sub-topic (how darktable does it, why, what works, what users struggle with).
3. A table mapping darktable features to Lightroom equivalents and Redlamp's plan.
4. Licensing notes for anything reusable (data, libraries).
5. Open questions.
