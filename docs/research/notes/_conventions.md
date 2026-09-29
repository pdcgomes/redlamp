# Research notes: shared conventions

Rules every workstream note in this folder followed. The synthesized result is
[ai-findings.md](../ai-findings.md); the source brief is
[ai-and-computational-photography-brief.md](../ai-and-computational-photography-brief.md).

## Evidence rules

1. Every factual claim cites a primary source: paper (arXiv ID or DOI), repository URL,
   model card, dataset terms page, vendor documentation, or benchmark table.
2. Licenses are verified from primary sources only: fetch the LICENSE file
   (`curl -sL https://raw.githubusercontent.com/<org>/<repo>/<branch>/LICENSE`),
   the Hugging Face model card / API (`curl -s https://huggingface.co/api/models/<id>`,
   look at `cardData.license` and the README), and the dataset's own terms page.
   Record: URL, date checked (2026-09-29), SPDX ID or verbatim key sentence.
3. If a license is missing, contradictory (code vs README vs model card), or depends on
   training data with unclear terms, mark it **UNCLEAR** and say why. Do not assume.
4. Separate evidence from opinion. Use "Evidence:" and "Assessment:" labels where it
   matters.
5. Numbers (PSNR, latency, params, FLOPs) come with the source and the conditions
   (dataset, resolution, hardware).
6. If you could not verify something (paywall, dead link, no network), say so explicitly.

## License verdicts

- **Shippable**: code, weights and training data all permit commercial use in a
  closed-distribution App Store binary under MPL-2.0 (no GPL/LGPL, no NC, no
  research-only).
- **Fine-tune only**: code/architecture usable, but weights are tainted (NC data or NC
  weights); we would retrain from scratch on data we have rights to.
- **Research-only**: cannot ship in any form; may be used for internal benchmarking only
  if the terms allow evaluation.
- **Avoid**: GPL/LGPL/AGPL code, or terms that forbid even evaluation.

## License matrix row format (markdown table)

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |

## Redlamp context (short)

- Native Swift + Metal RAW editor, macOS/iPadOS/iOS 26+, Apple Silicon only, MPL-2.0,
  App Store distribution.
- Scene-referred linear pipeline (linear Rec.2020). LibRaw unpacks only; black level,
  demosaic (Malvar-He-Cutler today; RCD/AMaZE/Markesteijn planned), color and all edits
  are Redlamp GPU code. Demosaiced image cached as a mip pyramid.
- Engine/UI separated by `RedlampEngineAPI` (value types). AI runs engine-side; on macOS
  in a sandboxed XPC helper, in-process on iOS.
- Non-destructive recipes in JSON sidecars; renders must be reproducible across devices,
  so model outputs affecting pixels need model versioning + result caching.
- Budgets: slider -> screen < 16 ms; open 24-26 MP raw in 70-250 ms; iPhone floor is
  8 GB A17 Pro; heavy AI may take seconds but must be tiled, cancellable, background.
- Render scheduler will have priority lanes; P3 is AI inference; thermal/Low Power aware.
- Privacy: everything on-device, no cloud, no credits.
- Clean-room: implement from papers, never from GPL source.
- Roadmap: Phase 2 classical denoise + Vision masks; Phase 3 AI denoise, SAM masks,
  healing, focus stacking v1; Phase 4 AI-assisted stacking, super resolution.
- Test machine for prototypes: Apple M1 Ultra.
