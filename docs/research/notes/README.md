# Research notes

The per-workstream evidence behind [ai-findings.md](../ai-findings.md), written on 29 September 2026
(note H and its appendices on 30 September 2026).
Each note has the full citations, license quotes, verification log and open questions for its area;
the findings document summarizes them, and its Appendices B and C consolidate their license matrices
and test-data lists.

| Note | Scope |
| --- | --- |
| [_conventions.md](_conventions.md) | Evidence rules, license verdict definitions, Redlamp context |
| [A-denoise.md](A-denoise.md) | Classical and AI denoise, noise modeling and calibration, training data, integration, evaluation |
| [B-super-resolution.md](B-super-resolution.md) | Super resolution, Apple's VideoToolbox scaler, hallucination risk |
| [C-masking.md](C-masking.md) | Apple Vision, SAM-class models, sky and landscape, depth, matting, mask storage |
| [D-removal.md](D-removal.md) | Inpainting, distraction detection, classical healing, patents, Content Credentials |
| [E-auto.md](E-auto.md) | Auto tone and white balance, personalization, adaptive profiles |
| [F-other.md](F-other.md) | Lens blur, culling, face and eye detection, crop and straighten, ML demosaic, other items |
| [G-focus-stacking.md](G-focus-stacking.md) | Competitive analysis, stack detection, alignment, fusion, AI assistance, placement, performance, UX |
| [INFRA.md](INFRA.md) | Runtime, Neural Engine constraints, compression, determinism, delivery, tiled inference, training, evaluation, legal |
| [H-topaz-upscale-sharpen.md](H-topaz-upscale-sharpen.md) | Supplement (30 September 2026): how Topaz's upscaling and sharpening work, open models that get similar results, a measured bake-off, and what Redlamp should build |
| [H1-topaz-teardown.md](H1-topaz-teardown.md) | Appendix to H: Topaz product lineup, disclosures, the Adobe partnership and acquisition, inferred architecture |
| [H2-open-model-survey.md](H2-open-model-survey.md) | Appendix to H: licences (including whether internal evaluation is allowed) for upscaling, deblur, all-in-one and face models, and evaluation tooling |

Later notes, each behind tracker rows or another findings document:

| Note | Scope |
| --- | --- |
| [MSK-17-sky-bakeoff.md](MSK-17-sky-bakeoff.md) | The sky mask bake-off (1 October 2026) |
| [CAM-14-seed-run.md](CAM-14-seed-run.md) | The camera bench over raw.pixls.us and what it found (4 October 2026) |
| [TON-29-colour-uniformity.md](TON-29-colour-uniformity.md) | Colour uniformity for skin: Capture One's tools, a prototype, and how Redlamp could build it (4 October 2026) |
| [TC-architecture-and-workflow.md](TC-architecture-and-workflow.md), [TC-capture-one-teardown.md](TC-capture-one-teardown.md), [TC-lightroom-and-other-tools.md](TC-lightroom-and-other-tools.md), [TC-routes-and-licences.md](TC-routes-and-licences.md) | Evidence for the [tethered capture findings](../tethering-findings.md) (5 October 2026) |
| [CAM-12-nikon-high-efficiency.md](CAM-12-nikon-high-efficiency.md) | Nikon's High Efficiency NEFs: the format, how Redlamp handles them, and the routes to opening them (5 October 2026) |
| [MSK-25-photoset.md](MSK-25-photoset.md) | The mask evaluation photoset: 115 CC0 photos for Sky, Subject, People and face parts, what they cover and what they lack (6 October 2026) |
| [DN-11-lightroom-raw-denoise.md](DN-11-lightroom-raw-denoise.md) | Lightroom's raw Denoise and what is published about it, the research on demosaicing and joint demosaicing and denoising, and a measured comparison of Redlamp, a pre-demosaic prototype and open models (7 October 2026) |
| [MSK-25-mask-review.md](MSK-25-mask-review.md) | Where Sky, Subject and People masks stand, from what Redlamp draws: the halo of an edit at an edge, the render-time edge, hair's glow, and the fixes ranked (6 October 2026) |
| [INF-11-README.md](INF-11-README.md) | The cloud processing study (INF-11, paused): what's written, what's left, how to resume, and each part's brief (7 October 2026) |
| [INF-11-removal-apis.md](INF-11-removal-apis.md) | Cloud APIs for mask-based object removal: what each takes and returns, prices, terms, and the first to integrate (7 October 2026) |
| [INF-11-app-store-privacy.md](INF-11-app-store-privacy.md) | App Store rules, privacy law, keys and provenance for sending work to a cloud provider, route by route (7 October 2026) |
| [INF-11-comfyui-masks-denoise.md](INF-11-comfyui-masks-denoise.md) | ComfyUI as a route (its API, hosted services, removal workflows on commercially licensed weights), cloud masking and cloud denoise for raw photos (7 October 2026) |
| [UX-17-masks-panel-audit.md](UX-17-masks-panel-audit.md) | The Masks panel, fourteen tasks step by step against Lightroom Classic's published workflow: where Redlamp's way is longer or hidden, and the redesign's findings ranked (7 October 2026) |
| [UX-develop-panels.md](UX-develop-panels.md) | Switching Develop panels off and choosing which show: what Lightroom Classic, Photos, darktable and others do, the owner's decision, and the questions for the UX-30 and UX-41 builds (10 October 2026) |

Some notes mention scratch scripts under `/tmp/`. Those were one-off measurement harnesses and are not
kept; the reproducible prototypes are in [research/prototypes](../../../research/prototypes/README.md).
