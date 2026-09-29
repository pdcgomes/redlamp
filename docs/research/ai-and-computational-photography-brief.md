# Research Brief: AI and Computational Photography in Redlamp

**For:** a research agent (or engineer) starting this investigation cold.
**From:** the Redlamp team. **Date:** 29 September 2026.
**Deliverable:** `docs/research/ai-findings.md`, plus prototypes where noted, in about two to three weeks of focused research. Details are under [Deliverables](#deliverables).

---

## 1. Context you need first

Redlamp is a native, open-source (MPL-2.0) RAW photo editor for macOS, iPadOS and iOS 26+, on Apple Silicon only, and it is designed to feel immediately familiar to Lightroom users. Read the repository [README](../../README.md) and the [Lightroom feature inventory](../lightroom-feature-inventory.md) before starting.

What matters for this research:

- **Engine.** Swift and Metal. The pipeline is scene-referred and linear (working space linear Rec.2020). LibRaw unpacks raw data only; black levels, demosaicing, color and every adjustment are Redlamp's own GPU code. The demosaiced image is cached as a mip pyramid.
- **The engine and the UI are strictly separated.** The UI talks to the engine only through `RedlampEngineAPI`, a value-type API. Any AI feature must fit behind that API, running as an engine-side stage or as a service. Inference is planned to run in a sandboxed XPC helper on macOS and in-process on iOS.
- **Edits are non-destructive and reproducible.** An edit is a recipe stored in a sidecar file. A render must be reproducible, including on a different device, so any model output that affects pixels needs a strategy for model versioning and result caching. For example, AI mask bitmaps are cached in the sidecar.
- **Performance budgets.**
  - Slider changes should reach the screen in under 16 ms.
  - Opening a 24–26 MP raw file takes 70–250 ms today.
  - The iPhone floor is an 8 GB device (A17 Pro).
  - Heavy AI operations may run for seconds, but they must be tiled, cancellable and run in the background, and they must never block the UI.
- **Licensing constraints. These are hard rules.**
  - Our code is MPL-2.0 and ships on the App Store.
  - No GPL or LGPL code, and no non-commercial or research-only licenses, for code, weights *or training data*.
  - Clean-room policy: implement from papers, not from GPL source.
  - Any model we ship needs a clear commercial-use license for both its weights and the data it was trained on, or we train it ourselves on data we have rights to.
- **Privacy.** Everything runs on the device. There is no cloud processing and there are no credits. This is a deliberate differentiator from Adobe's Firefly-backed features.

## 2. What we want to learn

1. **Where AI improves the product** enough to be worth the complexity, and where classical algorithms are as good or better.
2. **For each area, what the best available options are:** off-the-shelf models, open weights we can fine-tune, or models we train ourselves. This includes their license status, quality, speed on Apple Silicon (Neural Engine and GPU) and memory footprint.
3. **The shared infrastructure** we need for all of it: the model runtime, conversion, quantization, delivery, versioning, evaluation and training.
4. **A recommended sequence**, meaning what to build first and why, with effort estimates.

## 3. Workstreams

Each workstream lists the questions to answer. Prioritize depth on **A (denoise)** and **G (focus stacking)**; those are product priorities. The others need a solid landscape survey.

### A. Denoise *(top priority, best in class)*

We want the best denoise available on the platform: a classical, noise-profiled denoiser that is non-destructive and interactive, *and* an AI denoiser that matches or beats Adobe's Denoise, DxO DeepPRIME XD and Topaz.

**Questions**
- **Classical state of the art.** Which methods are the right choices for an interactive denoiser on the GPU?
  - Candidates include BM3D and BM3D-CFA, non-local means variants, wavelet and multi-scale shrinkage, guided and bilateral hybrids, and collaborative filtering.
  - Should denoising happen on raw data (before demosaicing) or after, in linear RGB?
  - How should the separate luma and chroma controls in Lightroom's Detail panel (Luminance, Detail, Contrast; Color, Detail, Smoothness) map onto the chosen method?
- **Noise modeling.** How do we calibrate per-camera, per-ISO noise profiles, for example with a Poisson–Gaussian model, heteroscedastic noise and row or column noise?
  - Can we estimate a profile from the image itself, without calibration shots?
  - What would a calibration capture protocol look like? Dark frames and flat fields, for instance.
- **AI denoise.**
  - Survey raw-domain and joint demosaic-plus-denoise networks, and RGB networks. Candidates include NAFNet, Restormer, SCUNet, KBNet, SwinIR-style models, the approaches used by leading commercial products, burst methods, and anything newer.
  - For each, report the architecture, license (code and weights), the datasets it was trained on and their licenses, published results (SIDD, DND, ELD, SID), and whether it runs on Core ML and the Neural Engine.
- **Training data.** Can we train our own model on data we have rights to?
  - One route is synthetic training: clean, low-ISO raw files plus calibrated noise models.
  - Which datasets are commercially usable? Many popular ones (SIDD, SID and others) have research-only or unclear terms. Verify each one.
- **Product integration.**
  - Should AI denoise be non-destructive (re-run or cached, as a stage in the pipeline) or baked into a new DNG, as Adobe does? What are the trade-offs for reproducibility, storage and interactivity?
  - How should tiled inference work: tile size, overlap and blending, and a per-tier budget for memory and time?
  - What preview strategy lets users judge the result quickly? For example, a 1:1 crop loupe processed instantly.
  - How does denoising interact with sharpening, demosaicing and our highlight reconstruction?
- **Evaluation.**
  - Propose an evaluation harness: PSNR, SSIM and LPIPS on public benchmarks (where licensing allows us to evaluate on them), plus blind A/B tests on our own captures from Sony, Canon, Nikon and Fujifilm X-Trans at high ISO.
  - Compare against Lightroom Denoise, DxO and Topaz.

### B. Super resolution and upscaling

- Survey the options: Real-ESRGAN, SwinIR, HAT, diffusion-based upscalers, and raw-domain or burst super resolution. Adobe's "Super Resolution" and "Raw Details" features are the benchmark.
- Cover 2x and 4x, **hallucination risk** (a photographer's tool must not invent detail convincingly), license, speed and memory.
- Is a raw-aware approach, done as part of demosaicing, meaningfully better than upscaling in RGB after the fact?

### C. Masking and segmentation

This is best-in-class masking, which is a core product pillar.

- **Apple Vision.** Exactly what does it provide on macOS/iOS 26+ for subject, person, people parts, animals and saliency, and at what quality, resolution and speed? Where does it fall short of Lightroom's masks (Sky, Background, Objects, People with parts, Landscape)?
- **SAM-class models** for "hover to select any object": SAM 2 or 2.1, EfficientSAM, MobileSAM and any newer variants. Cover license, the path to Core ML and the Neural Engine (converting the encoder and decoder, prompt latency), and whether the image embedding can be cached in the sidecar.
- **Sky, background and landscape categories:** open segmentation models with commercial licenses.
- **Depth:** Depth Anything V2 (check the license of each model size), Apple's Depth Pro (check the license), and others. This feeds the Depth Range mask and lens blur.
- **Edge refinement and matting** for hair and fur, for example guided-filter refinement versus learned matting.

### D. Object removal, healing and distraction removal

- **Inpainting:** LaMa, MAT, diffusion inpainting and newer options. What quality is possible on the device, and at what speed and model size?
- **Distraction detection:** people, reflections, dust spots and power lines. What can be done classically (dust spots, for example) and what needs a model?
- Classical healing (Poisson blending, PatchMatch) is planned regardless. Where does AI clearly win?
- **Generative content policy:** Content Credentials (C2PA) labeling, and user trust.

### E. Auto adjustments and personalization

- Learned auto tone and auto white balance. Note that the popular datasets are not commercially licensed; MIT-Adobe FiveK, for example, is research-only.
- **Personalization on the device:** learning a user's style from their own edits, privately and locally.
- Scene-aware "Adaptive" profiles, similar to Adobe Adaptive Color.

### F. Other opportunities (landscape only)

- Survey these briefly and give a recommendation on whether each is worth pursuing:
  - lens blur, meaning synthetic depth of field with bokeh shapes;
  - sky replacement;
  - AI-assisted culling;
  - face and eye detection for masks and healing;
  - smart crop and straighten;
  - AI ML-based demosaicing.
- Add anything else you think matters.

### G. Focus stacking *(top priority, flagship differentiator)*

Lightroom has no focus stacking. Helicon Focus and Zerene Stacker are excellent but clunky: they mean exporting, a separate app, round trips back, and friction everywhere. We want focus stacking to be **part of the normal editing workflow** and accessible to casual users: select a burst, click once, and get an editable result, with pro-level control available.

**Questions**
- **Competitive analysis.** Helicon Focus (Methods A, B and C), Zerene Stacker (PMax, DMap and its retouching workflow), Photoshop Auto-Blend, Affinity Photo's Focus Merge, in-camera stacking (OM System, Nikon and others), and any AI-first newcomers.
  - What does each do well, where does each fail (halos, low-contrast areas, hairs and bristles, occlusions, transparent subjects), and what does its workflow cost the user?
- **Classical pipeline.** Evaluate each stage and recommend a set of strategies:
  - **Stack detection:** group frames automatically using EXIF and maker-note focus-bracketing tags (Sony, Nikon, Canon, Fujifilm and OM System record bracket sequences), timestamps, and identical exposure and focal length.
  - **Alignment:** focus breathing (scale), camera shake and handheld sequences. Compare feature-based homography with dense optical flow for residual motion, and consider lens-profile-aware alignment.
  - **Focus measures:** Laplacian energy, local variance, wavelet or gradient energy, and multi-scale measures.
  - **Fusion strategies:**
    - depth-map (per-pixel argmax plus regularization, using graph cuts or guided filtering);
    - pyramid (Laplacian or wavelet max-selection);
    - weighted average;
    - hybrids.
    - What does each do best, and how can we offer them as user-facing "strategies" with sensible defaults?
  - **Artifact handling:** halos around high-contrast edges, occlusion, moving subjects, and exposure flicker between frames.
  - **Retouching:** a brush that paints from a chosen source frame, as in Zerene's retouching.
- **AI assistance.** Where does learning help?
  - Survey deep multi-focus image fusion methods (for example IFCNN, U2Fusion, SwinFusion and their successors), and report on licenses and real-world quality on macro and landscape stacks, not just benchmarks.
  - Other candidates: learned focus measures, halo suppression, occlusion and motion masks, and monocular depth to guide the depth map.
  - Could AI let us produce good stacks from **fewer or sloppier frames**, such as handheld phone bursts? That would matter to casual users.
- **Where it sits in Redlamp.** The recommended design needs to cover each of these:
  - **Stage in the pipeline:** stack in linear scene-referred space after demosaicing and before user edits, or in the raw domain?
  - **The result:** a new, fully editable "virtual raw" whose non-destructive stack recipe (source files plus parameters) can be re-rendered. Or bake it into a linear DNG? Make a recommendation.
  - **Performance:** a target such as fifty 45 MP frames in under 60 s on an M-series Mac. Is that realistic? Also cover memory strategy (tiling and streaming frames rather than holding all of them in memory), progressive preview (low resolution first) and iPad feasibility.
  - **UX:**
    - the filmstrip automatically says "Focus stack detected: 32 frames";
    - one click produces "Merge to Focus Stack";
    - choosing a strategy;
    - a depth-map preview;
    - a retouch brush;
    - the result appears in the filmstrip as a stack.

## 4. Shared infrastructure questions

- **Runtime:** Core ML versus MPSGraph versus custom Metal kernels.
  - Which operations work well on the Neural Engine, and which fall back to the GPU or CPU?
  - What do quantization (int8, palettization, pruning) cost in quality?
- **Model delivery:** bundle the models with the app, or download them on demand (Background Assets or App Store on-demand resources)? Propose size budgets for each device tier, and plan for model updates without changing old edits (model versioning in the recipe, plus cached outputs).
- **Tiled inference framework:** a shared engine component for tiles, overlap, blending, cancellation and progress. It should integrate with the render scheduler's priority lanes (P3 is AI inference) and adapt to temperature and power (it should back off when the device is hot or in Low Power Mode).
- **Training pipeline**, if we train our own models: compute needs, data acquisition (our own captures, licensed datasets, synthetic data) and the cost to reach and keep best-in-class quality.
- **Evaluation:** an evaluation suite shared by all AI features, with objective metrics, golden images, and a protocol for blind human comparison.
- **Legal:** a license matrix for every candidate (code, weights, training data), including the obligations for attribution and patents.

## 5. Deliverables

1. **`docs/research/ai-findings.md`** containing:
   - An executive summary with a recommendation for each workstream: build, adopt, fine-tune, or defer.
   - A shortlist table per workstream: candidate, license (code, weights, data), quality evidence, Apple Silicon speed and memory, and fit with the architecture.
   - A recommended architecture for AI in the engine: runtime, model registry, tiled inference, caching and versioning, and delivery.
   - For focus stacking: the recommended classical strategies, the AI assistance options, the pipeline placement, and a UX outline.
   - A proposed sequence and effort estimates, and how they map onto Redlamp's phases (Phase 2 classical denoise; Phase 3 AI denoise, SAM masks, healing and focus stacking v1; Phase 4 AI-assisted stacking and upscaling), including any changes you recommend to that plan.
   - Risks and open questions.
2. **Prototypes**, optional but valuable:
   - A Core ML conversion plus a Neural Engine timing run of the top denoise candidate and of a SAM-class model on an M-series Mac.
   - A classical focus-stacking proof of concept (alignment plus depth-map and pyramid fusion) on a public, CC0 or self-shot macro stack, with a comparison against at least one commercial tool.
3. **Test data list:** public stacks, high-ISO raw files and segmentation test images we can use, with their licenses.

## 6. Ground rules

- Verify licenses from primary sources: the LICENSE files, the terms on model cards and the dataset terms. Flag anything ambiguous; don't assume.
- Separate evidence from opinion. Cite papers, repositories and benchmark tables.
- Prefer on-device, commercially licensed and reproducible options. Where the best quality needs something we can't ship, say so, and estimate what it would take to train our own.
- Keep it decision-oriented. The goal is to let us commit to a direction for each workstream.
