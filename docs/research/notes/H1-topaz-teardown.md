# H1. Topaz Labs teardown: how Topaz upscaling and sharpening work (as of 2026-09-30)

Appendix to [H-topaz-upscale-sharpen.md](H-topaz-upscale-sharpen.md), which summarizes it and adds
the bake-off and the recommendation.

Author: research agent, 2026-09-30. Follows `docs/research/notes/_conventions.md`: every factual
claim cites a primary URL; all URLs were accessed **2026-09-30** unless stated; "Evidence:" and
"Assessment:" are kept separate; anything not confirmed is marked **UNVERIFIED**.

Access notes (so the gaps are explicit):

- topazlabs.com, docs.topazlabs.com, community.topazlabs.com (Discourse JSON API), blog.adobe.com
  and news.adobe.com fetched directly with curl.
- helpx.adobe.com returned **403** to curl; Lightroom help pages were read from Wayback snapshots
  (URLs given inline).
- dpreview.com returned **403** / Cloudflare challenge (also through the r.jina.ai proxy). The
  Wayback CDX API timed out. **No DPReview material was read.**
- fstoppers.com search is rendered client-side; no article list could be extracted. **No Fstoppers
  material was read.**
- Google Patents' `xhr/query` JSON endpoint did work via curl (details in §2.7).

Source-quality tiers used below: **[V]** Topaz/Adobe primary (product page, docs, press release,
staff forum post); **[C]** community forum post by a non-staff user (logs, reverse engineering);
**[P]** press. Community evidence is quoted verbatim but is not vendor-confirmed.

---

## TL;DR

- **Lineup (Sept 2026).** Topaz sells subscription-only desktop apps: **Topaz Photo** (successor
  to Photo AI, which combined the old standalone denoise, sharpen and upscale tools: "What
  started as standalone denoising and sharpening tools are now … in an all-in-one application",
  https://www.topazlabs.com/topaz-photo), **Topaz Gigapixel** and **Topaz Video**. Cloud apps are **Bloom**, **Astra**, **Topaz Image Web** and
  **Topaz for Mobile**, all bundled as **Topaz Studio**. Perpetual licences ended on
  2025-09-17. Sharpen AI and DeNoise AI are discontinued and folded into Topaz Photo. **Adobe
  completed its acquisition of Topaz Labs on 2026-09-23**. Topaz remains a standalone brand.
- **Two tiers of models.** Topaz's own docs split models into **"Core" = "non-generative"**
  (local-only; Standard, High Fidelity, Low Resolution, Text & Shapes, Art & CG, and all classic
  Sharpen/Denoise models) and **"Generative"** (Wonder 1/2/3/3.5, Standard Max, Recover 1–3,
  Redefine, Super Focus, Denoise Max, Recover Faces 3, Dust & Scratch). Generative models need
  **≥8 GB VRAM on Windows, or Apple Silicon with ≥16 GB RAM and macOS 14+**, and are
  cloud-rendered otherwise.
- **Disclosed tech.**
  - Training data: "trained on millions of images", and staff say all training content was
    "cleared and licensed".
  - Topaz's Starlight page says older enhancement models "utilize GAN technology" and the new
    ones use diffusion.
  - Recover v3 is called "Our Best Diffusion Upscaling", and Standard MAX a "Lightweight
    diffusion image model".
  - Runtimes: the classic stack is ONNX Runtime (DirectML/CUDA/TensorRT), OpenVINO and Core ML
    (staff posts, logs, a job ad). Large models run in **NeuroServer**, a bundled Python 3.12 +
    PyTorch server that uses MPS plus Core ML `.mlpackage` VAEs on Mac.
  - **NeuroStream** is a VRAM-streaming layer that Topaz says cuts VRAM "by up to 95%" and runs
    "models with billions of parameters".
  - Install footprint: 51 GB of models on Windows and 88–100 GB of disk on Mac.
- **Strongest architectural clue.** A 2026-09-21 Gigapixel log posted by a user shows that
  **Wonder = package `bloom_precision`**. The traceback runs through
  `TopazDiffusionDenoiserRamStreaming`, `VideoDiffusionInfer.vae_encode` and
  `ImageAutoencoderKLWrapper`, with a "DiT" tile config. `VideoDiffusionInfer.vae_encode` is the
  exact class and method name in ByteDance's Apache-2.0 **SeedVR/SeedVR2** repo. A separate
  community teardown found "SeedVR2" strings inside Topaz's Starlight Precise binaries.
  - Assessment: Topaz's flagship generative image and video models are latent **diffusion
    transformers of the SeedVR2 lineage** (one-step, adversarially post-trained), run as
    one-frame "videos" for stills.
- **Adobe wording.**
  - 2025-10-28: Photoshop Generative Upscale "now equipped with Topaz Labs' AI models … up to 56
    megapixels with Topaz Gigapixel, and 9 megapixels with Topaz Bloom".
  - 2026-06-15: "AI Sharpen brings Topaz Labs' Noise-Aware Sharpen model directly into Lightroom,
    no exporting required, to recover fine details on flower petals, fur, and foliage and more
    with pixel-level precision."
  - Lightroom help: AI Sharpen is "powered by Topaz" and "analyzes the photo using generative
    AI". It costs 10–20 generative credits, which implies cloud processing.
- **Noise-Aware Sharpen is simple, and Topaz disclosed it**: "Noise is detected and removed.
  Image is sharpened. Noise is added back exactly as it was." It is a residual-decomposition
  recipe Redlamp can reproduce classically or with a small network (§4).
- **Artifacts.** Topaz's own docs concede that earlier models had a "plasticky appearance" and
  that "AI models create smooth skin and hair with repetitive structure". Recover Faces "will
  sometimes change expressions slightly". Redefine results "will differ between local systems and
  cloud servers". Users report "waxy"/"plastic" faces, scrambled text and "invented" high-contrast
  detail in Wonder 2/3 and Super Focus.

---

## 1. Product lineup as of 2026

### 1.1 Corporate, licensing and pricing timeline

| Date | Event | Source |
|---|---|---|
| 2018–2023 | Standalone DeNoise AI, Sharpen AI, Gigapixel AI; later consolidated into Photo AI | Legacy docs: "Sharpen AI has replaced Topaz InFocus"; "DeNoise AI has replaced Topaz DeNoise and AI Clear" (https://docs.topazlabs.com/other-apps/legacy) [V] |
| 2024-10-18 | Gigapixel 8.0: Redefine model, cloud rendering (paid credits), Face Recovery Gen 2 | Staff release post https://community.topazlabs.com/t/79692 [V] |
| 2025-09-17 | **Topaz Studio** launch; "perpetual licenses will no longer be available"; Wonder and Standard MAX introduced | CEO Eric Yang, https://community.topazlabs.com/t/95562 [V] |
| 2025-09-17 | Topaz Photo v1.0.0 replaces Photo AI; "We will no longer sell perpetual licensed products" | https://community.topazlabs.com/t/95494 [V] |
| 2025-09 | Photo AI "Discontinued in September 2025"; "Photo AI v4.0.4 is the final version" | https://docs.topazlabs.com/topaz-photo/tpai-vs-tp [V] |
| 2025-09-19 | Staff: "Denoise AI and Sharpen AI are discontinued and are not UIs that will be updated" | https://community.topazlabs.com/t/95494/133 [V] |
| 2025-10-28 | Topaz Gigapixel + Bloom become Photoshop Generative Upscale partner models | Adobe blog (§2.9) [V] |
| 2025-12-16 | Topaz Astra added to Adobe Firefly Boards | Adobe blog (§2.9) [V] |
| 2026-01-22 | Topaz Photo 1.2.0: Wonder 2 (cloud-only at launch), Recover v3 | https://community.topazlabs.com/t/100375 [V] |
| 2026-03-10 | NeuroStream announced with NVIDIA; Wonder 2 (Local) | https://www.topazlabs.com/news/topaz-labs-introduces-topaz-neurostream-breakthrough-tech-for-running-large-ai-models-locally [V] |
| 2026-04-28 | "Next-Gen" release: Wonder 3, Denoise Max, Super Focus 3, High Fidelity 3 | https://www.topazlabs.com/news/the-next-gen-release---april-2026 [V] |
| 2026-05-07 | Gigapixel 1.2.0 gets NeuroServer, Wonder 2/3, HF3 | https://community.topazlabs.com/t/102626 [V] |
| 2026-05-13/14 | Topaz Photo 1.6.0: **Recover Faces 3**, **Sharpen – Noise-Aware**; NeuroStream 2 | https://community.topazlabs.com/t/102790 ; https://www.topazlabs.com/updates/speed [V] |
| 2026-06-15 | Lightroom AI Sharpen uses Topaz Noise-Aware Sharpen | Adobe blog (§2.9) [V] |
| 2026-06-25 | Adobe announces definitive agreement to acquire Topaz Labs | https://news.adobe.com/news/2026/06/adobe-to-acquire-topaz-labs [V] |
| 2026-08-25 | Topaz Photo 1.7.0: Wonder 3.5; local 192 MP cap removed; Content Credentials metadata for California AI Transparency Act | https://community.topazlabs.com/t/104557 [V] |
| 2026-09-23 | **Adobe completes acquisition**; "The Topaz Labs brand will remain" | https://blog.adobe.com/en/publish/2026/09/23/adobe-completes-acquisition-of-topaz-labs [V] |

Pricing on the product pages (accessed 2026-09-30) [V]:

- **Topaz Photo** (https://www.topazlabs.com/topaz-photo):
  - Personal: $17/mo billed annually ($199/yr), $25/mo on the annual plan billed monthly, $39
    month-to-month.
  - Pro: $50/mo billed annually ($599/yr), or $63/mo.
  - "Limited commercial use … for orgs under $1M USD annual revenue" on Personal.
  - Model list for Personal: "Wonder 2 and 3, Standard Max, Dust & Scratch, Super Focus,
    Remove, Denoise, Sharpen, Upscale, Adjust Lighting, Balance Color, Recover Faces, Preserve
    Text, Healing Brush. Cloud access to: Wonder 1." Pro adds "Local access to: Wonder 1".
- **Topaz Gigapixel** (https://www.topazlabs.com/topaz-gigapixel): Personal $12/mo billed
  annually ($149/yr), $19 or $29 monthly; Pro $42/mo annual ($499/yr) or $54.
- **Topaz Studio** (all apps): $399/yr, or $45/mo annual-billed-monthly, or $69/mo. It includes
  "300 monthly video cloud credits", "2—image cloud concurrency" and a "32MP cloud export
  limit" (the export limit applies to Bloom and Image Web only).
- **Cloud image rendering** in desktop apps is advertised as "Unlimited cloud rendering" /
  "free and unlimited" (https://docs.topazlabs.com/topaz-photo/cloud-rendering). It is
  non-batch per the CEO post ("unlimited image cloud processing for non-batch workflows",
  https://community.topazlabs.com/t/95562).
- Online DRM: "Authentication is required monthly … allowing up to 1 month of offline use"
  (https://docs.topazlabs.com/topaz-photo/tpai-vs-tp).

### 1.2 Topaz Photo: enhancement list

Evidence (https://www.topazlabs.com/topaz-photo and the docs index at https://docs.topazlabs.com/):

- The product page says both "Choose from 11 AI-powered tools" and "12 groundbreaking AI tools.
  Trained on millions of images", which is internally inconsistent.
- Tools listed: Wonder (Upscale), Standard MAX (Upscale), Healing Brush, Dust and Scratch, Super
  Focus, Remove, Adjust Lighting, Balance Color, Denoise (processed) and Denoise (RAW), Sharpen,
  Recover Faces, Preserve Text, Upscale.
- Plugins: Photoshop, Lightroom Classic, Capture One, Apple Photos, Affinity (manual install).
- Photo AI vs Topaz Photo: the docs list the models new in Topaz Photo as "Adjust Lighting v3,
  Denoise Max, Dust and Scratch v2, Grain, Healing Tool, Recover Faces v3, Remove v2, Sharpen (3
  new models): Sharpen Noise-Aware, Sharpen Portrait, Sharpen Wildlife, Super Focus v3, Upscale
  (3 new models): High Fidelity v3, Recover v3, Standard Max, Wonder (4 new models): v1, v2, v3
  and v3.5" (https://docs.topazlabs.com/topaz-photo/tpai-vs-tp).
- Answer to "was Sharpen AI folded in?": **yes**. Sharpen AI is discontinued (above), and its
  model families (Standard/Strong/Lens Blur/Motion Blur) live on as Topaz Photo Sharpen models
  (§1.4).

### 1.3 Gigapixel: exact model menu

Evidence (docs [V]):
https://docs.topazlabs.com/topaz-gigapixel/enhancements/ai-models/core-models,
.../generative-models, .../legacy-models, .../settings, .../upscale.
Marketing claims "nine enhancement models" (https://www.topazlabs.com/topaz-gigapixel).

**Core models.** The docs say: "Our core AI models are considered non-generative AI models …
These AI models are available to process locally on your computer. Cloud rendering is not
available."

| Model | Docs wording (verbatim excerpts) |
|---|---|
| **Standard** (v2 current) | "general-purpose upscaling model … maintaining true-to-input detail and structure". In Topaz Photo: Standard v1 "reliable, natural-looking upscale"; Standard v2 "Best for images where a more generative enhancement is desired. Produces stronger detail creation than v1" (https://docs.topazlabs.com/topaz-photo/enhancements/upscale-and-resize) |
| **High Fidelity** (v1, v2, v3) | HF3 "reducing the plasticky appearance and excess artifacts seen in earlier models"; "performs best on medium to high … including modern photos, RAW images". HF2 "avoiding aggressive reconstruction or over-sharpening"; "To keep the look of grain or noise in the image use High Fidelity v3" (Photo docs say v2 retains grain; the docs contradict each other) |
| **Low Resolution** (v2) | "optimized for images that start with limited detail, heavy compression, or small dimensions … without modifying the source characteristics" |
| **Text & Shapes** | "images dominated by typography, logos, UI elements … prioritizes edge clarity and shape accuracy". (The *product page* text for Text & Shapes is a copy-paste of the Dust & Scratch blurb, "remove dust, scratches and, surface damage", which is a marketing error.) |
| **Art & CG** | "illustrations, digital art, renders … without introducing photographic texture" |

- Core-model settings: "Denoise slightly suppresses noise", "Sharpen attempts to reduce motion
  or lens blur", "Fix Compression reduces compression artifacts", each "1 to 100". Also: "The
  degree of denoising, sharpening, and fixing compression that is applied depends on the scale
  factor" (settings page).
- Other enhancements: Face Recovery, Gamma Correction, Grain.

**Generative models** ("You can find all the generative models at the bottom of the model list"):

| Model | Docs wording / controls | Limits |
|---|---|---|
| **Wonder 1 / 2 / 3** (3.5 in Photo 1.7.0; a Gigapixel 1.3.6 user log names "Wonder 3.5 / 3 / 2 / 1") | W1: "repair and improve small to medium-sized low-resolution images in a single step". W2: "no creativity sliders or tuning parameters" (https://community.topazlabs.com/t/100375). W3: "selectable Low, Medium, and High enhancement levels" | Cloud: "maximum allowed input and output of 128MP" (https://docs.topazlabs.com/topaz-gigapixel/cloud-rendering); Photo Wonder 3.5 cloud 100 MP; local limit removed in 1.7.0 |
| **Standard Max** | "a generative model … comparable to generative upscaling models, without the heavy hardware requirements"; "Faster than most image diffusion-based upscaling models" | "maximum allowed input of 24MP and output of 384 MP" (cloud); needs only "6 GB of VRAM" |
| **Recover** (1, 2, 3) | R3: "Choose a strength mode (Low/Med/High)"; "Recover is designed to be used with images that are 1MP or less"; R2 "Pre-downscaling" in three levels for "false resolution" | R3/R2 cloud "maximum input of 24MP and output of 384MP"; R1 16 MP input |
| **Redefine** (realistic / creative) | Realistic: "None or Subtle"; Subtle enables Image description. Creative: "Low, Medium, High, or Max", "Texture - adjust the level of detail that will be generated", "Image description"; "the only local, prompt-driven generative image model"; "rendering results will differ between local systems and cloud servers"; "Auto-guidance for Redefine creative will help produce better results when the Image description is left blank" | "maximum input and output of 256MP" (cloud); "Cloud rendering is recommended … larger than 1MP" |

- Face Recovery 2 (Realistic / Creative) and Face Recovery 3 (§1.6).
- **Legacy models**, off by default: **Lines** and **Very Compressed**.
- At the Gigapixel 8.0 launch, Redefine had "Creativity" levels 1–6 and "Texture", and the post
  said: "Known issue: local processing for creativity 3-6 is currently lower quality than
  expected - please use cloud processing instead"
  (https://community.topazlabs.com/t/79692 [V]). Texture "will control the frequency of
  generated detail". Prompts should be descriptive: "describe the new image that you want …
  as opposed to telling the model what you want it to do".
- **Scale limits.**
  - "SCALE FACTOR will upscale your image by a multiplier of up to 6x"; custom factors to 2
    decimals; downscale 0.9–0.2×.
  - "32,000px on the longest side is the maximum dimension … (~1 Gigapixel)"
    (https://docs.topazlabs.com/topaz-gigapixel/enhancements/upscale).
  - The site nav says "Image upscaling up to 16x pixels" (which equals 4× linear). PetaPixel
    2024 said "upscale and enhance any image to 16 times its original size"
    (https://petapixel.com/2024/10/28/upscaling-app-gigapixel-8-leans-heavily-into-using-ai-to-repair-pixelated-photos/
    [P]).
  - Bloom advertises "Creative 8x upscale" (https://www.topazlabs.com/bloom).
- **Recommended multi-pass workflow** (generative-models page): resize the source to within
  model limits, run a generative model at 1–4×, export, then re-import and use a **core**
  model for the remaining scale.

### 1.4 Sharpening menu

Evidence: https://docs.topazlabs.com/topaz-photo/enhancements/sharpen [V].

- Intro: "Unlike traditional sharpening that darkens or brightens pixel edges, it reverses the
  root causes of blurriness, such as camera shake, motion blur, and missed focus."
- Models:
  - **Standard**: "slight amounts of lens and motion blur".
  - **Strong**: "very blurry and out-of-focus images". It has no Minor Denoise slider.
  - **Lens Blur**: "when the camera lens fails to focus correctly".
  - **Motion Blur**: "movement of either the camera or the subject".
  - **Natural**: "keep texture looking natural".
  - **Refocus**: "bring out finer lines or texture".
  - **Wildlife Sharpen**: "Use on high-resolution images (5MP or higher) with low–medium blur";
    "Not for heavy blur recovery".
  - **Portrait Sharpen**: "trained on high-quality portrait images"; "only on high-resolution
    (5MP or larger) portrait images that are already denoised and deblurred. RAW images are the
    best".
  - **Sharpen Noise-Aware**: "separates image detail from noise before applying sharpening".
- Settings: **Strength** and **Minor Denoise**.
- **Super Focus** is a separate enhancement
  (https://docs.topazlabs.com/topaz-photo/enhancements/super-focus [V]):
  - "a generative AI tool"; "trained to work on missed focus cases".
  - v1, v2 and v3. "Focus Boost" (v1/v2 only, large files) "uses downscaling".
  - Tile preview on large images. "Super Focus v3 is not currently supported for RAW files".
  - "Do not use Super Focus on Backgrounds … it will create artifacts".
  - Hardware: 8 GB VRAM (v3 strictly), Mac "16GB RAM minimum, 24GB RAM recommended", no Intel
    Mac locally.
- Topaz's Noise-Aware release copy (https://www.topazlabs.com/updates/speed [V]): "Noise-Aware
  Sharpening is our first model to understand and isolate noise before enhancing … **Noise is
  detected and removed. Image is sharpened. Noise is added back exactly as it was.**"
  Availability: "Topaz Image Web (cloud only), Topaz Photo, and API". The staff release post
  adds: "It reads the noise structure in the image and sharpens only the underlying detail …
  The result is a sharper image with noise and grain intact"
  (https://community.topazlabs.com/t/102790 [V]).

### 1.5 Denoise

Evidence: https://docs.topazlabs.com/topaz-photo/enhancements/raw-denoise and
.../denoise-raw-and-non-raw [V].

- **RAW Denoise** (models RAW Normal, RAW Strong):
  - "instead of estimating the missing color information for each pixel based on the values of
    neighboring pixels, the AI model uses context from the entire image. It also considers and
    compensates for noise that hinders traditional demosaicing methods and fixes hot pixels."
  - Runs only on Bayer raws: "RAW Denoise is not needed for X trans sensors".
  - Output is DNG (the workflow advice is to "export, then use PS/PSE with the exported DNG
    file").
- **Denoise (non-RAW)**: Normal, Strong, Extreme, plus **Denoise MAX**, "our first generative
  denoising model, designed to reconstruct detail rather than just remove noise". It "also
  handles slight chromatic aberration". Settings: Strength, Minor Deblur, Original Detail.

### 1.6 Face recovery

Evidence [V]:
https://docs.topazlabs.com/topaz-photo/enhancements/recover-faces ,
https://docs.topazlabs.com/topaz-gigapixel/enhancements/face-recovery ,
https://community.topazlabs.com/t/102790 .

- **Detection**: "analysis scans the entire image, searching for the eyes, nose, and mouth". It
  classifies faces as "High Confidence" or "Low Confidence". "If the AI model does not detect
  the face it is not possible to force it". "Animal faces are not detected".
- **Recover Faces 2**: "Realistic" and "Creative" modes; the model "will sometimes change
  expressions slightly or may smooth skin, hair". It has "a maximum output size of 512x512
  pixels. Faces larger than that are forced to the smaller size", and "dot artifacts that
  appeared at high strength levels".
- **Recover Faces 3** (May 2026): "a generative recover faces model that processes each face
  separately"; "4 similarly sized faces will take 4x the time". It "runs on NeuroServer", locally
  on NVIDIA/AMD 8 GB or Apple Silicon 16 GB with macOS 14+. In Gigapixel: "Face Recovery 3
  requires local processing and is unavailable with Cloud render". This contradicts the Photo
  docs ("Cloud render is available … up to … 100MP") and the Speed Update page ("local and cloud
  rendering"). Recover Faces 1 is being sunset.
- Controls: Strength; Hair and Neck toggles ("Parts to enhance").
- "When Not to Use: Portraits … creates a 'plastic' feeling because it is too smooth."

### 1.7 Autopilot (Photo) and Auto Mode (Gigapixel)

Evidence [V]: https://docs.topazlabs.com/topaz-photo/functions/autopilot-and-configuration ,
https://docs.topazlabs.com/topaz-gigapixel/functions/auto-mode , https://www.topazlabs.com/updates/precision .

- Autopilot "analyzes your image for: File type; Metadata - such as ISO, camera information, and
  lens information; Noise severity and type; Subject detection and blur level; Human faces and
  face quality; Image size and resolution".
- It then "selects the enhancements and settings … based on the Preferences > Autopilot menu".
  Examples: "Enable when detected blur is [≥ level]"; face selection "All / Low quality
  (recommended) / Subject Only / None"; "Enhance Small Images … upscales small images to 12
  megapixels or a maximum of 6x".
- Default selection masks: All / Subject / Background / Portrait / Landscape
  (https://docs.topazlabs.com/topaz-photo/selection).
- "Personalization … uses data from your previously edited photos". In Gigapixel: "AI will adapt
  over time based on the difference between what it suggested and the changes you made".
- Precision Update (March 2026): "True Resolution Detection … Automatically detects false
  resolution—upscaled or resampled images that have lost real detail".
- The CEO describes Wonder as "The world's first 'distilled agentic' model that uniquely
  understands which corrections to apply" (https://community.topazlabs.com/t/95562 [V]).

### 1.8 Local vs cloud, and hardware

Evidence [V]: https://docs.topazlabs.com/topaz-photo/system-requirements ,
https://docs.topazlabs.com/topaz-gigapixel/system-requirements ,
https://docs.topazlabs.com/topaz-gigapixel/enhancements/ai-models/generative-models .

| Item | Topaz Photo | Topaz Gigapixel |
|---|---|---|
| Mac minimum | macOS 13, Apple M-series, 16 GB RAM, **88 GB disk** | macOS 13, M-series, 16 GB, 30 GB disk |
| Mac recommended | macOS 26, M Pro/Max/Ultra, 24 GB+, 100 GB disk | macOS 15, M Pro/Max/Ultra, 24 GB+, 45 GB |
| Generative models on Mac | "require macOS 14 or higher"; 16 GB min | "macOS 14 or newer"; "16 GB of RAM or more"; ARM Windows "24GB+" |
| Large outputs | "For very large upscales, 128GB of RAM is the minimum required. Outputs of 256MP or more" | same wording |
| Windows GPU | 6 GB VRAM min; generative "require 8GB of VRAM" | same; Standard Max 6 GB |
| Windows disk | "51GB of space in '/ProgramData'" (models) + 2 GB + 5 GB temp | "about 48GB … '/ProgramData'" |
| Intel Mac | "Local previews and exports are only supported for Core Models" | same |
| Snapdragon | "NPU Qualcomm Hexagon"; "ARM/Snapdragon machines do not support local rendering for Generative models" | same |

- Cloud: "Cloud Rendering is available for use with generative models" (Gigapixel). "Cloud
  render is not available when using Gigapixel as a plugin". Results are kept "7 days"
  (https://docs.topazlabs.com/topaz-gigapixel/cloud-rendering). Photo lists "Super Focus v1 and
  v2, Dust and Scratch, Standard Max, Recover v3, and Wonder v1 and v2" as cloud-capable
  (tpai-vs-tp page; the list is dated, since later releases add Wonder 3/3.5, Denoise Max and
  Recover Faces 3).
- Marketing positions local rendering as private: "Private local rendering. Your files never
  leave your computer" (https://www.topazlabs.com/topaz-photo).
- Local and cloud variants of the same named model are **not identical**:
  - "The two models have a slightly different character: the local model renders a bit sharper
    and less grainy than the cloud version" (Wonder 2, https://community.topazlabs.com/t/102626
    [V]).
  - "rendering results will differ between local systems and cloud servers" (Redefine docs).

---

## 2. What Topaz has disclosed technically

### 2.1 Training data

- "All using AI trained on millions of images" (https://www.topazlabs.com/topaz-photo [V]).
  "Trained on millions of images" (https://www.topazlabs.com/topaz-gigapixel [V]).
- Staff (kyle.topazlabs), 2024-01-12: "All of the content used to train the AI models has been
  cleared and licensed for use in the training." Again on 2025-01-28: "Yes, this applies to our
  AI models for the image apps as well. Our research team used in house source material and
  licensed other material as needed to train all of our models."
  (https://community.topazlabs.com/t/60293 [V])
- Portrait Sharpen "was trained on high-quality portrait images" (sharpen docs [V]).
- Job ad (Staff Security Engineer): "massive on-premise GPU training clusters in our
  colocation facility"; "Our models are our most valuable IP … secure from theft or reverse
  engineering" (https://jobs.lever.co/topazlabs/b3c491fe-5ffd-4f21-8df6-22f6823e060c [V]).
- Assessment: the "cleared and licensed" statements predate the 2026 diffusion models. If those
  models are initialised from third-party checkpoints (§2.6), the claim would cover Topaz's
  fine-tuning data, not necessarily the base model's pretraining data. That is **UNVERIFIED**
  either way.

### 2.2 GAN vs diffusion, in Topaz's own words

- Starlight page (https://www.topazlabs.com/starlight [V]): "While existing video enhancement
  models utilize GAN technology, the switch to diffusion is one key to Project Starlight's major
  quality boost. Unlike existing GAN models, Project Starlight's models have a great
  understanding of semantics". It also calls Starlight "the first-ever diffusion AI model for
  video enhancement".
- Recover v3: "Recover v3 — Our Best Diffusion Upscaling" (https://community.topazlabs.com/t/100375
  [V]). Docs: Recover 3 "Isn't ideal for images dominated by text or logos, which diffusion
  models still struggle to reproduce accurately"
  (https://docs.topazlabs.com/topaz-photo/enhancements/upscale-and-resize [V]).
- Standard MAX: "Lightweight diffusion image model" (CEO, https://community.topazlabs.com/t/95562
  [V]). "100x faster than first-generation diffusion models" (topaz-photo page [V]). "built on
  new architecture" (Photo upscale docs [V]).
- "Topaz Labs' large diffusion-based image models …: Wonder 2 …, Denoise Max …, Super Focus 3
  …, Face Recovery 3" (https://www.topazlabs.com/news/the-mac-is-faster-update---june-2026
  [V]). This is **direct vendor confirmation that Wonder 2, Denoise Max, Super Focus 3 and Face
  Recovery 3 are diffusion models.**
- CEO, 2026-05-07: "We released our first models in 2018, and the model architecture has
  remained basically unchanged until now. What started as a single experiment called Project
  Starlight has now grown to an entirely new series of models"
  (https://www.topazlabs.com/news/the-expansion-release [V]).
- Head of AI Xiaoyu (Kevin) Wang: "In NeuroStream 1, we enabled models with billions of
  parameters to run locally on consumer and lower-end hardware"
  (https://www.topazlabs.com/news/the-speed-update-neurostream-2-face-recovery-3-noise-aware-sharpen-more
  [V]).
- Job ad: "Topaz Labs is a full-stack AI company that develops, trains, and deploys generative AI
  models for image and video enhancement"
  (https://jobs.lever.co/topazlabs/64c09f71-41a7-493c-966d-cbac83113533 [V]).

### 2.3 Model sizes and download clues

- Windows install: models take "51GB of space in '/ProgramData'" (Photo) and "about 48GB"
  (Gigapixel). Mac Photo min disk is 88 GB (system-requirements pages [V]).
- Starlight (video) NeuroServer model sizes, as reported by a beta tester for Topaz Video 1.6:
  SL Mini 3 GB, SL Sharp 3.1 GB, SL Fast 6.4 GB, SL HQ 3 GB, **SL Precise 2.5 7.3 GB**
  (https://community.topazlabs.com/t/102826 [C]).
- For comparison, ByteDance's SeedVR2-3B checkpoint `seedvr2_ema_3b.pth` is 13.57 GB (fp32
  → ≈3.4 B params; ≈6.8 GB in fp16) plus a 1.0 GB `ema_vae.pth`. SeedVR2-7B is 32.96 GB
  (https://huggingface.co/api/models/ByteDance-Seed/SeedVR2-3B/tree/main ; licence
  `apache-2.0` in cardData [V-third-party]). Assessment: 7.3 GB is consistent with a ~3 B DiT in
  16-bit plus a VAE. That is a size coincidence, not proof.
- Image-model file sizes for Wonder / Recover / Redefine were **not found** (**UNVERIFIED**).
  One user claims Redefine is "30gb bloat to run SDXL quality stable diffusion"
  (https://community.topazlabs.com/t/91709/48 [C], unverified opinion).
- Core ML compile cache can explode: a user reports a "coreMLCache which was about 215 GB",
  traced to "Wildlife Beta" (https://community.topazlabs.com/t/99716 [C]).
- Model files are encrypted/obfuscated: "Our model files are protected and may trigger alerts
  from certain security applications" (https://docs.topazlabs.com/topaz-gigapixel/quick-start
  [V]). Python modules in NeuroServer have randomised names (e.g. `dcqujnlsy4ni.py`, §2.6).

### 2.4 Inference backends ("AI processor")

- Head of AI Engine (suraj, staff), 2021: "we use ONNXRuntime so porting to using CUDA, TensorRT
  or oneDNN is just compiling libraries" (https://community.topazlabs.com/t/28647/3 [V]).
- Model file variants (Video Enhance AI 2020 user tutorial): "-ov.tz (openvino)", "-ml.tz
  (coreml)", "fp32 -ox.tz (onnx)", "fp16 -ox.tz (onnx16)". Fixed input tiles "256x352, 288x288,
  384x480 …" with 1×/2×/4× variants (https://community.topazlabs.com/t/18446 [C]). TensorRT
  engines ship as "rt###-8517.tz" files (https://community.topazlabs.com/t/68739/35 [C]).
- Photo AI 2.4.2 Windows log: "[AIE] Selecting backend for device -1 from:
  openvino,onnx16,onnx,openvino16". Photo AI 3.3.1 Mac log: "from: openvino,coreml,openvino16"
  (https://community.topazlabs.com/t/77671 ; https://community.topazlabs.com/t/81042 [C]).
  Models are fetched from `models.topazlabs.com/v1/`. The same Photo AI log shows "Loaded lensfun
  database" (lensfun: LGPL library, CC BY-SA DB, per F-other.md).
- Mac: the support fix for crashes is to "delete the coreML Folder" in `~/Library/Application
  Support` (staff Ange, https://community.topazlabs.com/t/85814 [V]). Topaz Photo 1.3 added a
  "Clear CoreMLCache option to Mac > Help menu" (release notes quoted in
  https://community.topazlabs.com/t/101032 [C]). Video AI 3.4: "Iris 1x and 2x use mlpackage
  instead of mlmodel … notable speed up" (https://community.topazlabs.com/t/50373/24 [C quoting
  staff]).
- Topaz Video preferences: "Apple Silicon processors will not have this option available, and
  will always use a combination of the device's CPU, GPU, and Neural Engine"
  (https://docs.topazlabs.com/topaz-video/reference-guide/preferences [V]). Photo/Gigapixel:
  "Preferences > General > AI Processor > to be on Auto … Auto … will use your RAM and VRAM
  memory together" (troubleshooting pages [V]).
- Windows 2026: a crash in "onnxruntime.dll v1.23.2.0 (DirectML execution provider path)" in
  Topaz Video 1.5 (https://community.topazlabs.com/t/102638/44 [C]).
- Job ad (AI Inference/HPC): "Experience with onnx, coreml, and tensorRT runtime SDKs"; "work
  with various hardware partners (NVIDIA, AMD, Intel, Apple) to optimize inference"; Qt desktop
  apps (https://jobs.lever.co/topazlabs/64c09f71-41a7-493c-966d-cbac83113533 [V]).
- **NeuroServer** (the large-model runtime), from a user-posted Gigapixel 1.3.6 log on macOS 27
  (https://community.topazlabs.com/t/105125 [C]):
  - Path `/Applications/Topaz Gigapixel.app/Contents/MacOS/neuroserver/neuroserver/lib/python3.12/site-packages/torch/...`,
    i.e. **bundled CPython 3.12 + PyTorch**.
  - The error "coreml_vae: every worker failed to load dec mlpackage within 60.0s; caller should
    fall back to the MPS path", i.e. the **VAE decoder runs as a Core ML `.mlpackage`, with
    PyTorch-MPS as fallback**.
  - A local "topserving" worker protocol.

### 2.5 NeuroStream / NeuroServer (VRAM streaming)

Evidence [V]:

- "NeuroStream is a proprietary, industry-first technology that reduces VRAM requirements by up
  to 95% … The only tradeoff is a minor reduction in processing speed"
  (https://docs.topazlabs.com/topaz-gigapixel/enhancements/ai-models).
- NeuroServer is "a lightweight local server" that the app "will automatically spin up … in the
  background, load the model, and process your images"
  (https://community.topazlabs.com/t/102626).
- NeuroStream 2: "2X-to-4X faster processing time for images". Example: "Denoise image model run
  on 20MP image with NeuroStream 1 vs. NeuroStream 2": 7m10s → 1m16s
  (https://www.topazlabs.com/updates/speed).
- "Mac is Faster" (June 2026): "1.7x to 2x faster" on Mac for Wonder 2, Denoise Max, Super
  Focus 3, Face Recovery 3 (https://www.topazlabs.com/news/the-mac-is-faster-update---june-2026).
- AMD: "AMD GPU support is powered by Topaz NeuroStream"
  (https://www.topazlabs.com/news/the-precision-update---march-2026).
- Adobe's acquisition press release singles it out: "Topaz Labs brings deep expertise in
  optimizing large, complex AI models to run directly on device"
  (https://news.adobe.com/news/2026/06/adobe-to-acquire-topaz-labs).

Community evidence [C]:

- Class name `TopazDiffusionDenoiserRamStreaming` (§2.6).
- Tile configs are auto-chosen by VRAM: "Tile config: VAE 1024/128, DiT 512/64 (chosen for 16.0
  GB total VRAM)" vs "VAE 1024/128, DiT 256/32 (chosen for 12.0 GB total VRAM)"
  (https://community.topazlabs.com/t/102790/106).
- The Starlight Precise tuner author reports "VAE tiling", "chunk 121" temporal chunks, and
  cuDNN 9 with "Topaz's CUDA 12.8 runtime" (https://community.topazlabs.com/t/104652 ,
  https://community.topazlabs.com/t/104817).

Assessment: NeuroStream is most plausibly **layer/block weight streaming from system RAM to
GPU** (the "RamStreaming" name), combined with **spatial tiling of both the DiT (latent tiles
with overlap, e.g. 512/64) and the VAE (1024/128 px tiles)**. It resembles the community
"block-swap + VAE tiling" tricks used for SeedVR2 in ComfyUI. The "up to 95%" figure is a vendor
claim; no independent measurement was found (**UNVERIFIED**).

### 2.6 Community reverse-engineering: Wonder and Starlight are SeedVR-lineage latent DiTs

Evidence [C] (verbatim log excerpts, Gigapixel 1.3.6, macOS 27, Wonder model,
https://community.topazlabs.com/t/105125, posted 2026-09-21):

```text
[>]   Input: 1 frame, 2307x3172px → Padded: 4624x6352px → Output: 4614x6344px
[>]   Batch size: 1, Seed: 42, Channels: RGB
━━━━━━━━ Phase 1: VAE encoding ━━━━━━━━
File "models/bloom_precision/dcqujnlsy4ni.py", line 1415, in models.bloom_precision.dcqujnlsy4ni.TopazDiffusionDenoiserRamStreaming.__call__
File "models/bloom_precision/njrwkszezfen.py", line 1573, in models.bloom_precision.njrwkszezfen.StreamingBloomPrecisionUpscaler._process_frames_core
File "models/bloom_precision/src/core/zaf6mzkzb3zz.py", line 244, in models.bloom_precision.src.core.zaf6mzkzb3zz.VideoDiffusionInfer.vae_encode
File "models/bloom_precision/src/models/image_vae_2d/b73hddpndy8n.py", line 566, in ...ImageAutoencoderKLWrapper.encode
ERROR:local_model_service:Error running video restoration: coreml_vae: ...
```

- The user says other generative models (Recover 3, Standard Max) work; only the Wonder models
  fail. Staff acknowledged "the OS 27 Golden Gate compatibility issue affecting local rendering
  with Wonder, and Redefine Creative" (same thread, staff alexandre.topazlabs) [V].
- A user noted in February 2026: "Wonder v2 is actually not 'Wonder' at all - it's 'Bloom
  Precision' according to the Topaz servers" (https://community.topazlabs.com/t/100363/145 [C]).
- NeuroServer package list found by the Starlight tuner author: "FaceRecoveryNatural,
  denoisemax, bloom_precision, relight, astra_precision_3, slm, slmini_local, wonder3, video_f2f".
  He also wrote that "Some SLP code contains comments showing that portions were adapted or
  vendored from Astra or Bloom code" (https://community.topazlabs.com/t/104817/27 [C]).
- Starlight Precise binaries: "The Python extension .pyd files in Topaz's SLP package contain
  explicit SeedVR2 and ComfyUI-SeedVR2 names … e.g. 'SeedVR2 Video Upscaler - Latent Domain
  Temporal Chunking'" (https://community.topazlabs.com/t/104652 [C]). The same author found
  "softness … Valid values are exactly 1, 2, and 3. They select three different VAE decoder
  weights", and core arguments "seed, latent_noise_scale, shared_noise, and prompts"
  (https://community.topazlabs.com/t/104817/27 [C]).
- Primary check of the open-source side [V-third-party]:
  - ByteDance-Seed/SeedVR (Apache-2.0, repo created 2025-06-10;
    https://api.github.com/repos/ByteDance-Seed/SeedVR) defines `class VideoDiffusionInfer()`
    with `def vae_encode(...)` in `projects/video_diffusion_sr/infer.py`
    (https://raw.githubusercontent.com/ByteDance-Seed/SeedVR/main/projects/video_diffusion_sr/infer.py).
  - The SeedVR2 inference script uses `DivisibleCrop((16, 16))`, `sample_steps=1`,
    `cfg_scale=1.0` and a `wavelet_reconstruction` colour fix
    (https://raw.githubusercontent.com/ByteDance-Seed/SeedVR/main/projects/inference_seedvr2_3b.py).
  - Papers: SeedVR (arXiv 2501.01320, "Seeding Infinity in Diffusion Transformer Towards Generic
    Video Restoration") and SeedVR2 (arXiv 2506.05301, "One-Step Video Restoration via Diffusion
    Adversarial Post-Training").

Assessment:

- The identical class and method name (`VideoDiffusionInfer.vae_encode`) is a strong code-lineage
  signal, not a coincidence of generic naming.
- Other traits match SeedVR2 conventions:
  - Padding to a multiple of 16 (4624 = 16·289, 6352 = 16·397) matches SeedVR2's 16-divisible
    geometry (8× VAE × 2× patch).
  - The input is pre-upscaled to output size before VAE encoding, which is also SeedVR's
    approach.
  - "frames" terminology is used for a still image.
  - The docs call Wonder "a Single-step model".
- Topaz appears to have swapped SeedVR's 3D causal video VAE for a 2D image VAE (`image_vae_2d`)
  for stills.
- It is **UNVERIFIED** whether Topaz uses SeedVR2 *weights* (fine-tuned) or only code and
  architecture, and whether Wonder's DiT is 3 B, 7 B or custom.

### 2.7 Patents

- Google Patents JSON endpoint (`https://patents.google.com/xhr/query?url=...`) returned **0
  results** on 2026-09-30 for `assignee=Topaz Labs`, `assignee=Topaz Labs LLC`,
  `assignee=Topaz Labs, LLC`, `assignee=Topaz Labs Inc` and `inventor=Suraj Raghuraman`. The
  free-text query `"Topaz Labs"` returned 3 unrelated hits (a Scientific Games patent; a Korean
  video-enhancement patent KR102954500B1 by 주식회사 서경산업 that merely mentions Topaz; a
  Chinese dyeing-inspection patent). The browser URL `https://patents.google.com/?assignee=Topaz+Labs`
  returns only a JS shell to curl.
- USPTO (PatentsView / Patent Public Search) was **not queried** (API key / JS UI). **UNVERIFIED.**
- Assessment: Topaz appears to rely on trade secrets (encrypted models, obfuscated code) rather
  than patents. Unpublished applications (18-month lag) cannot be ruled out.

### 2.8 Jobs, people, talks

- Lever board (https://api.lever.co/v0/postings/topazlabs?mode=json, 6 postings) [V]: AI
  Inference/HPC engineer (ONNX/Core ML/TensorRT, raw pipeline experience preferred), Security
  (training clusters, protecting weights), DevOps ("ML model training infrastructure and
  distribution"), full-stack (C++/Qt/QML), PM, social. Careers page lists "Deep Learning
  Researcher, Dallas, TX" (https://www.topazlabs.com/careers).
- Named AI leads [V]: Dr. Suraj Raghuraman, "Head of AI Engine"
  (https://www.topazlabs.com/news/the-precision-update---march-2026); Xiaoyu (Kevin) Wang,
  "Partner and Head of AI" (Speed Update news).
- Research partners [V]: NVIDIA (NeuroStream), AMD ("Starlight, the first diffusion-based video
  enhancement feature optimized for AMD Radeon GPUs", Precision Update).
- No conference papers, talks or technical blog posts describing architectures were found.
  Topaz advertises "Visit Topaz Labs at SIGGRAPH" (news index) but no talk content was found.
  **UNVERIFIED** / likely nonexistent.

### 2.9 The Adobe partnership and acquisition: exact wording

1. **Photoshop Generative Upscale, 2025-10-28 (Adobe MAX)**, Adobe blog "11/12 new ways to
   accelerate your creative process with Creative Cloud"
   (https://blog.adobe.com/en/publish/2025/10/28/12-new-ways-accelerate-your-creative-process-creative-cloud)
   [V]: "With **Generative Upscale** in Adobe Photoshop — now equipped with Topaz Labs' AI models —
   you can upscale and enhance small, cropped, and other low-resolution images with realistic
   detail, up to 56 megapixels with Topaz Gigapixel, and 9 megapixels with Topaz Bloom."
2. **Firefly Boards, 2025-12-16**
   (https://blog.adobe.com/en/publish/2025/12/16/adobe-firefly-improves-ai-video-creation-tools-new-models-unlimited-generations)
   [V]: "We're adding new video upscaling capabilities to Firefly Boards with the addition of
   industry-leading partner model Topaz Astra"; "lets you push your footage to 1080p or 4K".
3. **Lightroom AI Sharpen, 2026-06-15**
   (https://blog.adobe.com/en/publish/2026/06/15/from-culling-to-compositing-new-creative-cloud-innovations-across-every-stage-of-your-workflow)
   [V]: "**AI Sharpen brings Topaz Labs' Noise-Aware Sharpen model directly into Lightroom, no
   exporting required, to recover fine details on flower petals, fur, and foliage and more with
   pixel-level precision.**"
4. **Lightroom help** (Wayback 2026-09-29 snapshot of
   https://helpx.adobe.com/lightroom/desktop/edit-photos/enhance-images-with-generative-ai.html,
   at https://web.archive.org/web/20260929202411/https://helpx.adobe.com/lightroom/desktop/edit-photos/enhance-images-with-generative-ai.html)
   [V]:
   - "With AI Sharpen, powered by Topaz, you can easily recover details in blurry images and
     enhance sharpness. It analyzes the photo using generative AI to restore clarity while
     preserving the image's natural appearance."
   - Options: "Default: Applies a balanced level of sharpening. Strong: Applies higher
     sharpening intensity"; "Select Apply Topaz denoise to reduce noise while recovering detail
     in low-light photos."
   - "AI Sharpen consumes credits … Topaz Sharpen (files up to 25 megapixels) = 10 credits;
     Topaz Sharpen (25-56 megapixels) = 20 credits".
   - Same page: "Generative Upscale, powered by Topaz" with "output scale (2x or 4x)"; "Topaz
     Gigapixel (files up to 25 megapixels) = 10 credits; Topaz Gigapixel (25-56 megapixels) = 20
     credits".
   - The Lightroom "What's new" page (Wayback
     https://web.archive.org/web/20260906201822/https://helpx.adobe.com/lightroom/desktop/introduction/whats-new.html)
     lists Generative Upscale "powered by Topaz Labs" in **April 2026 (version 9.3)** and "Reduce
     blur with AI Sharpen" in **June 2026 (version 9.4)**.
   - Assessment: credit metering strongly suggests the Topaz models run in **Adobe/Topaz cloud**
     for Lightroom, not on-device. On-device vs cloud is not stated explicitly (**UNVERIFIED**).
5. **Acquisition announced, 2026-06-25**, Adobe press release
   (https://news.adobe.com/news/2026/06/adobe-to-acquire-topaz-labs) [V]:
   - "Topaz Labs brings deep expertise in optimizing large, complex AI models to run directly on
     device".
   - "Topaz Labs will also bring its proprietary Neurostream technology that enables large,
     complex AI models to run locally on consumer devices".
   - "expected to close in the second half of 2026".
   - Eric Yang: "We've always believed that technology should serve human creativity rather
     than replace it".
6. **Acquisition completed, 2026-09-23**
   (https://blog.adobe.com/en/publish/2026/09/23/adobe-completes-acquisition-of-topaz-labs) [V]:
   - "Topaz Labs' award-winning technology is available in Adobe Firefly and Photoshop … Its
     proprietary Neurostream technology lets professionals process complex AI models on their
     own devices or Topaz Lab's cloud-based option."
   - "Adobe will also optimize the performance of Topaz Labs models".
   - "The Topaz Labs brand will remain … Topaz Labs' CEO Eric Yang will join Adobe's Digital
     Video and Audio team".
7. Topaz's own side:
   - The Topaz news index (https://www.topazlabs.com/news, accessed 2026-09-30) had **no
     acquisition post** (**UNVERIFIED**: no Topaz-authored acquisition statement found).
   - Topaz's "Expansion" release (2026-05-07) announced "Topaz Labs for Premiere, a new UXP
     panel … send media … to the Topaz cloud processing system"
     (https://www.topazlabs.com/news/the-expansion-release).
   - The panel covers "Gigapixel, Wonder 3, and Bloom models" for images
     (https://www.topazlabs.com/updates/expansion).
   - Press coverage: PetaPixel on the deal
     (https://petapixel.com/2026/06/25/adobe-acquires-ai-upscaling-specialists-topaz-labs/ ,
     https://petapixel.com/2026/09/23/adobe-completes-acquisition-of-topaz-labs-and-says-topaz-will-remain-its-own-brand/
     [P]) and on MAX 2025 ("Generative Upscale can swap over to using Topaz Labs' AI upscale
     technology",
     https://petapixel.com/2025/10/28/adobes-end-of-year-updates-are-all-ai-and-sometimes-not-even-its-own-ai/
     [P]).

Assessment for Redlamp:

- Adobe's in-house Super Resolution (2×, raw-trained, regression-flavoured; see
  B-super-resolution.md §1) now coexists with Topaz-powered **generative** upscale (2×/4×) and a
  Topaz-powered generative sharpen in Lightroom, all credit-metered.
- Adobe explicitly bought Topaz for **on-device large-model runtime know-how**. Expect those
  models to move on-device in Lightroom/Photoshop over time. That erodes Redlamp's "on-device"
  differentiator for generative features, but not its "no credits / no cloud / reproducible"
  one.

---

## 3. Independent reviews and artifact reports

Coverage is thin: DPReview and Fstoppers could not be read (see access notes).

### 3.1 Vendor admissions (primary, arguably the most reliable artifact evidence)

- HF3 "reducing the plasticky appearance and excess artifacts seen in earlier models";
  Wonder 3 "reducing the plasticky appearance and artifacts seen in earlier versions"; Wonder 2
  "resolving plasticky or airbrushed artifacts"
  (https://docs.topazlabs.com/topaz-gigapixel/enhancements/ai-models/core-models and
  .../generative-models [V]).
- "Usually, AI models create smooth skin and hair with repetitive structure"; "Where Wonder 1
  may have over-processed images and made them look artificial, it felt like Wonder 2 was not
  doing enough" (https://community.topazlabs.com/t/102626 [V]). Wonder v1 "Produces more
  aggressive, stylized results and may over-process some images"; Wonder 3.5 "reducing
  repetitive patterns" (https://docs.topazlabs.com/topaz-photo/enhancements/wonder [V]).
- Wildlife Sharpen motivation: "Existing sharpen models … smooths away these details, producing
  an artificial, plastic result" (sharpen docs [V]).
- Face recovery "may smooth skin, hair, or small facial details" and "will sometimes change
  expressions slightly". On high-res faces it "creates a 'plastic' feeling". Recover Faces 2 had
  "dot artifacts … at high strength levels" (§1.6 [V]).
- Recover 3: "higher creativity levels can introduce background artifacts"; text and logos are
  a weak spot for "diffusion models" (§2.2 [V]).
- Super Focus: "Do not use Super Focus on Backgrounds … it will create artifacts … Do not use
  Super focus on already sharp elements … unnatural and over-processed results" [V].
- Redefine at Gigapixel 8 launch: "Creativity levels of 3 or higher will begin to produce
  divergent, and often entertaining results"; "Face Recovery won't work as well with high
  creativity outputs due to divergence from the original image"
  (https://community.topazlabs.com/t/79692 [V]).
- Staff reply to a Wonder 2 complaint: "Your observations about text contrast and the model
  'inventing' high‑contrast details rather than refining what's there are especially insightful"
  (https://community.topazlabs.com/t/100587/5 [V]).

### 3.2 Press

- PetaPixel, Gigapixel 8 news (2024-10-28, [P]): describes Redefine as generative and
  prompt-driven ("have Gigapixel 8 'make it winter,' adding snow"). Face Recovery Gen2 "Creative
  uses more generative AI, while Realistic relies more heavily on an image's existing pixels".
  This is a news write-up, not a lab test.
- PetaPixel "6 Best Image Upscalers Tested" (2026-07-08,
  https://petapixel.com/2026/07/08/6-best-image-upscalers-tested-photo-upscaling-without-the-plastic-look/
  [P]) is **sponsored by a competitor (Aiarty)**, so treat it as weak. On Topaz: "The more
  advanced generative models, such as Wonder and Standard Max, produce highly detailed and
  natural-looking outputs … certain creative models offer different interpretations of
  detail … when absolute consistency is not the primary goal." It frames the category problem as
  "Some sharpen aggressively. Others invent textures that were never there."
- PetaPixel opinion (2026-05-09,
  https://petapixel.com/2026/05/09/photographers-are-collateral-damage-in-the-ongoing-pixel-war/
  [P]): Adobe Super Resolution "is more limited in its ability to scale as it cannot synthesize
  creative detail". This is the fidelity-vs-generative distinction in a reviewer's words.
- DPReview, Fstoppers: **not read (403 / JS-only)**. **UNVERIFIED.**

### 3.3 User reports on Topaz's forum [C] (anecdotal, but specific)

- "Wonder V3 is too artificial and make plastic Faces…. Wonder V2 is looking much more natural!"
  (beta tester, https://community.topazlabs.com/t/102274/41).
- Wonder 2 "really scrambles" signage text ("'AI artefacts'"), where Wonder 1 did not
  (https://community.topazlabs.com/t/100587).
- Super Focus: "The out of focus moon looks like a clock now"; "severe colour distortion, and
  plastic looking faces … The more out of focus it is, the worse the effect"
  (https://community.topazlabs.com/t/95048).
- Photo AI 2.0.1 autopilot: faces "looked very waxy, like museum statues"
  (https://community.topazlabs.com/t/52325). Autopilot Face Recovery at 100% "makes faces too
  plastic" (https://community.topazlabs.com/t/39745).
- Redefine "seems to exaggerate fur length and texture, making animals look as if they were
  well suited for an arctic environment… even lions" (https://community.topazlabs.com/t/91353/44).

Assessment: the pattern is consistent across sources.

- **Fidelity/core** models draw "too smooth / plastic / waxy" complaints. That is the classic
  regression-to-the-mean failure of L1/L2-trained restorers, worst on faces.
- **Generative** models draw "invented", "scrambled text", "divergent" and "different local vs
  cloud" complaints. That is the classic hallucination failure.
- Topaz's product answer is a menu (Low/Med/High, creativity, "Realistic/Creative", core vs
  generative) plus masking. It does not offer a measured fidelity guarantee.

---

## 4. Assessment: inferred architecture (INFERENCE, clearly labelled)

Everything in this section is **Assessment**. Each row cites the evidence it rests on.
Confidence: H = several independent clues, including primary; M = consistent circumstantial
clues; L = plausible guess.

| Topaz mode | Key evidence (section) | Likely open-research analogue | Conf. |
|---|---|---|---|
| Gigapixel **core** upscalers (Standard, HF, Low Res, Text & Shapes, Art & CG, Legacy Lines/Very Compressed) | "non-generative", local-only (§1.3); ONNX/OpenVINO/Core ML/TensorRT `.tz` files with fixed tile shapes (§2.4); "model architecture has remained basically unchanged" since 2018 (§2.2); Topaz says pre-Starlight models "utilize GAN technology" (§2.2); sliders Denoise/Sharpen/Fix Compression 1–100 and strength "depends on the scale factor" (§1.3) | Fully convolutional CNN SR (ESRGAN/RRDB or SRResNet/EDSR class, perhaps SwinIR-lite later), trained on **synthetic degradation pipelines** (BSRGAN/Real-ESRGAN style: blur, resize, noise, JPEG) with L1 + perceptual + **low-weight GAN** loss. Per-content variants are separate fine-tunes on different degradation/content distributions. Sliders are **degradation-parameter conditioning** (as in SRMD / conditional Real-ESRGAN) or blends between variants | M–H (CNN + synthetic degradations); M (GAN loss) |
| **Standard MAX** | "Lightweight diffusion image model"; "100x faster than first-generation diffusion"; "new architecture"; 6 GB VRAM; not NeuroServer-listed (§1.3, §2.2) | **One-step distilled latent diffusion SR** (OSEDiff / SinSR / AddSR / DMD-style distillation) with a small UNet or DiT and a compact VAE. Possibly Topaz's own base model | M |
| **Wonder 1/2/3/3.5** (package `bloom_precision`) | Traceback: `TopazDiffusionDenoiserRamStreaming`, `VideoDiffusionInfer.vae_encode`, `ImageAutoencoderKLWrapper`, "DiT" tiles, Seed 42, pad to 16, pre-upscale then encode (§2.6); "Single-step model" (§1.3); "billions of parameters" (§2.2); vendor: Wonder 2 is a "large diffusion-based image model" (§2.2); CEO: "distilled agentic" (§1.7); Low/Med/High levels (W3) | **SeedVR2-lineage latent DiT restorer**: LR image upscaled in pixel space, encoded by a 2D VAE, then a one- (or few-) step DiT with **adversarial post-training** (APT) and a fixed seed, then VAE decode. "Distilled agentic" plausibly means the model was **distilled from a multi-tool teacher pipeline** (denoise + sharpen + upscale + face) into one network. W3 "levels" are likely the noise level / timestep of the single step or a latent-noise scale (cf. SLP `latent_noise_scale`) | **H** (latent DiT diffusion, SeedVR code lineage); M (one-step APT); L (what "agentic" means) |
| **Bloom** (web, 8×, prompt, "Creativity", 4 variations) | Shares the `bloom_precision` name; prompts, creativity, "Every render is unique" (§1.3) | Same DiT family with text conditioning (SeedVR2's `pos_emb.pt`/`neg_emb.pt` show the base supports text embeddings; SLP core accepts "prompts", §2.6) and stochastic noise for variations | M |
| **Recover 1/2/3** | "Our Best Diffusion Upscaling"; "diffusion models still struggle" with text; Low/Med/High creativity; ≤1 MP optimal; pre-downscaling for false resolution; a user reports Recover 3 kept working on macOS 27 when all Wonder versions failed, so it is at least a different code path (§1.3, §2.2, §2.6) | Latent-diffusion SR in the **StableSR / DiffBIR / SUPIR** family (pretrained T2I UNet + ControlNet/encoder conditioning on the LR image), multi-step, with creativity = start timestep / guidance / noise augmentation. Pre-downscaling acknowledges the train/test resolution prior (trained on small, truly-LR inputs) | M |
| **Redefine** realistic/creative | Text "Image description"; creativity 1–6 (now Low→Max), "Texture … frequency of generated detail", "Auto-guidance" when prompt blank; local vs cloud results differ; strong divergence at high creativity (§1.3, §3.1) | **Text-conditioned latent diffusion img2img/tile-ControlNet** on an SD/SDXL/FLUX-class base. Creativity ≈ denoising strength. Texture ≈ noise-augmentation level or a detail LoRA / high-frequency guidance. "Auto-guidance" ≈ automatic captioning by a VLM (as SUPIR uses LLaVA). Differences between local and cloud results imply different checkpoints or precisions | M (text-conditioned LDM); L (which base model) |
| **Super Focus v1/v2/v3** | "generative", "trained to work on missed focus"; Focus Boost downscales; v3 needs 8 GB, no RAW; vendor lists Super Focus 3 among "large diffusion-based image models" (§1.4, §2.2) | v1/v2: generative deblur (possibly GAN or early diffusion) run at reduced resolution. v3: **diffusion restorer trained on synthetic defocus (disk/Gaussian/aberration PSFs)**, probably sharing the NeuroServer DiT stack | M (v3 diffusion); L (v1/v2) |
| **Sharpen** core models (Standard, Strong, Lens Blur, Motion Blur, Natural, Refocus, Wildlife, Portrait) | "reverses the root causes of blurriness"; run locally; subject-specific training for Portrait/Wildlife; Strength + Minor Denoise (§1.4) | **Blind deblurring CNNs** (DeblurGAN-v2 / MPRNet / NAFNet / Restormer class) trained on synthetic blur: defocus/lens PSFs for Lens Blur and Refocus, linear/trajectory kernels for Motion Blur. Standard vs Strong differ by degradation range. Portrait/Wildlife are domain fine-tunes. Strength is an output blend or conditioning | M |
| **Sharpen Noise-Aware** (= Adobe Lightroom AI Sharpen) | Vendor: "Noise is detected and removed. Image is sharpened. Noise is added back exactly as it was." (§1.4) | **Residual decomposition**: \(\hat{x}=D(y)\), \(n=y-\hat{x}\), output \(S(\hat{x})+n\). \(D\) = learned denoiser (noise-level-aware, e.g. FFDNet/NAFNet-style with an estimated noise map), \(S\) = deblur network. It may be trained end-to-end with a target that keeps the input noise realisation. Adobe calls it "generative AI", so \(S\) may be a generative model; the Topaz side does not list it as NeuroServer/diffusion | **H** (pipeline structure, vendor-stated); L (whether \(S\) is generative) |
| **RAW Denoise** (Normal/Strong) | Joint demosaic + denoise from Bayer, "context from the entire image", hot-pixel fix, not X-Trans (§1.5); Autopilot reads ISO/camera (§1.7) | Packed-Bayer joint demosaic-denoise CNN (like Adobe's Denoise, A-denoise.md), likely conditioned on ISO/noise-model parameters. Hot pixels handled by an outlier mask. Strong = model trained on heavier noise | M |
| **Denoise** Normal/Strong/Extreme; **Denoise Max** | Core vs "our first generative denoising model"; NeuroServer package `denoisemax`; vendor lists Denoise Max as diffusion-based (§1.5, §2.2, §2.6) | CNN denoisers for sRGB/processed images; Denoise Max = diffusion restorer (same DiT stack), "reconstruct detail rather than just remove noise" | M–H |
| **Recover Faces 1/2** | Hard **512×512** output limit; Realistic vs Creative; "change expressions slightly"; landmark-based detection (§1.6) | **GFPGAN / CodeFormer class**: 512² aligned face crop, generative facial prior (StyleGAN2 or VQ codebook), Realistic/Creative ≈ CodeFormer fidelity weight \(w\), pasted back with a parsing mask (Hair/Neck toggles ≈ face-parsing classes). Detection ≈ RetinaFace-style 5-landmark detector with confidence | **H** (512 crop + GAN/codebook prior class) |
| **Recover Faces 3** | "generative … processes each face separately", no size limit, NeuroServer, package likely `FaceRecoveryNatural`; vendor: diffusion-based (§1.6, §2.2, §2.6) | **Face-specific diffusion restoration** (DifFace / DiffBIR-face / PGDiff class) on crops, possibly the same DiT with a face LoRA, then blended | M |
| **Preserve Text** | Mask-first, Low Resolution vs Noisy/Compressed models, "Strength … degree of generation" (https://docs.topazlabs.com/topaz-photo/enhancements/preserve-text) | Text-region SR/restoration model (TextZoom/TATT-class or a text-conditioned generative model) applied to masked regions | L |
| **Autopilot / Auto Mode / True Resolution Detection** | Inputs: metadata, noise type/severity, subject + blur level, faces, size; thresholds in prefs; personalization from user deltas (§1.7) | A **set of small classifiers/regressors** (noise estimator, blur estimator, face detector, saliency/subject segmenter, false-resolution detector) feeding a **rule table** that maps scores to models and strengths, plus a per-user regression offset. Not an end-to-end network. Wonder's "distilled agentic" framing suggests Topaz is replacing this chain with a single distilled model | M |
| **NeuroStream** | "reduces VRAM … up to 95%", "RamStreaming" class, VRAM-dependent tile configs, "billions of parameters" (§2.5) | Block-wise **weight offload/streaming** (like DeepSpeed-inference / ComfyUI block-swap) + DiT latent tiling with overlap + VAE tiling; on Mac, VAE compiled to Core ML with PyTorch-MPS for the DiT | M–H |

Reasoning notes:

1. **Why CNN/GAN for core models.**
   - They run through ONNX Runtime/OpenVINO/Core ML with fixed tile shapes and 1×/2×/4×
     variants. That is the signature of exported fully-convolutional nets, not large
     transformers.
   - Topaz itself contrasts earlier "GAN technology" with Starlight's diffusion.
   - Community "waxy/plastic" complaints about core models match regression-heavy training.
2. **Why SeedVR2 for Wonder.**
   - The class name `VideoDiffusionInfer` with method `vae_encode` is SeedVR's.
   - The DiT/VAE tiling, 16-px padding, fixed seed, "single-step" claim and billions-of-params
     claim all fit SeedVR2's one-step APT recipe.
   - The Starlight Precise binaries reportedly contain explicit SeedVR2 strings.
   - Topaz is under no obligation to disclose this: SeedVR/SeedVR2 code and weights are
     Apache-2.0, which permits closed commercial use with attribution in the NOTICE.
   - Whether Topaz ships such attribution was **not checked** (**UNVERIFIED**).
3. **Why SD-class LDM for Redefine/Recover.**
   - Text prompts, "creativity" (denoising strength), "texture" and "auto-guidance" are the
     standard knobs of SD-based restoration (StableSR/SUPIR).
   - Local-vs-cloud divergence suggests different checkpoints or quantisation.
   - No module names were found for these, so the base model is unknown.
4. **Why GFPGAN/CodeFormer for Recover Faces 2.** A hard 512×512 face output and a
   fidelity/creative toggle are the defining traits of that family. RF3 lifting the size limit
   and becoming "diffusion-based" matches the 2024–2026 field shift.
5. **Why Noise-Aware = residual decomposition.** Topaz stated the three steps outright. The
   remaining uncertainty is only whether \(D\) and \(S\) are separate networks.

### 4.1 Implications for Redlamp (short)

- **Fidelity tier is cheap and shippable.** Topaz's core tier (CNN SR/deblur/denoise, local;
  per-model file sizes **UNVERIFIED**) is what Redlamp's Phase 3–4 plans already target (B-super-resolution.md,
  A-denoise.md). The generative tier needs ≥16 GB unified memory on Mac and multi-GB weights.
  That is incompatible with the 8 GB iPhone floor and the reproducibility requirement.
- **Copy the Noise-Aware idea, not the model.** Denoise with our workstream-A network, sharpen
  or deconvolve the clean estimate, then add back \(y-\hat{x}\) (optionally attenuated). In a
  linear raw pipeline this is natural, since noise is still near-Poisson-Gaussian and the residual
  is well defined. It is a 1–2 week classical or small-network feature. It also answers
  Lightroom's AI Sharpen without cloud credits.
- **Reproducibility.** Topaz's own docs admit that the same model name gives different results
  locally vs in the cloud, and that sessions use fixed seeds (Seed: 42). Redlamp's recipe
  sidecars should pin model version + seed + tile geometry for any learned op.
- **Licensing note (conventions §License).** SeedVR/SeedVR2 code and weights are Apache-2.0
  (GitHub API + HF cardData), but their training-data terms were not checked. Per our rules this
  is **UNCLEAR** for weights, and **Fine-tune only** at best, even though Topaz appears to build
  on it.
- **Provenance.** Topaz Photo 1.7.0 now embeds Content Credentials for CAITA compliance
  (https://community.topazlabs.com/t/104557). That supports F-other.md's C2PA recommendation.

---

## 5. Could not verify / open items

- DPReview and Fstoppers reviews (403 / JS-only); no independent lab-style quality test of
  Topaz fidelity vs generative modes was found.
- Topaz's own statement on the Adobe acquisition (none on topazlabs.com/news at access time).
- Whether Lightroom AI Sharpen / Generative Upscale run on-device or in the cloud (credits imply
  cloud, which is not stated), and whether Lightroom's "Strong" option maps to a different Topaz
  model.
- Whether Wonder/Starlight use **SeedVR2 weights** vs only code/architecture; DiT parameter
  counts for any image model; file sizes of Wonder/Recover/Redefine/Standard Max/Denoise Max.
- Base model of Redefine and Recover (SD 1.5/SDXL/FLUX/own); whether Redefine uses a VLM for
  "Auto-guidance".
- Whether Noise-Aware Sharpen's sharpening stage is generative (Adobe says "generative AI";
  Topaz does not say so).
- NeuroStream's mechanism and the "up to 95%" VRAM reduction (vendor claim only).
- Face Recovery 3 cloud availability (Gigapixel docs vs Photo docs conflict).
- USPTO search (not run); Google Patents found no Topaz Labs assignee.
- Any Apache-2.0 NOTICE/attribution for SeedVR code inside Topaz apps.
- Exact current Gigapixel "nine models" enumeration (docs list 5 core + 4 generative families +
  Face Recovery + 2 legacy; marketing counts differ).
- Topaz for Mobile (iPhone) on-device vs cloud processing (docs page nearly empty).

## Sources (all accessed 2026-09-30)

Topaz product and docs: https://www.topazlabs.com/topaz-photo · https://www.topazlabs.com/topaz-gigapixel ·
https://www.topazlabs.com/bloom · https://www.topazlabs.com/starlight · https://www.topazlabs.com/careers ·
https://www.topazlabs.com/news (and linked items: the-expansion-release, the-mac-is-faster-update---june-2026,
the-next-gen-release---april-2026, the-precision-update---march-2026,
the-speed-update-neurostream-2-face-recovery-3-noise-aware-sharpen-more,
topaz-labs-introduces-topaz-neurostream-…, topaz-labs-receives-2025-emmy-award-for-video-technology) ·
https://www.topazlabs.com/updates/speed · /updates/precision · /updates/next-gen · /updates/expansion ·
https://docs.topazlabs.com/ (pages cited inline) · https://api.lever.co/v0/postings/topazlabs?mode=json

Topaz community (Discourse, `/t/<id>.json` and `/posts/by_number/<id>/<n>.json`): topics 18446, 28647, 50373,
52325, 60293, 68739, 77671, 79692, 81042, 85814, 91353, 91709, 95048, 95494, 95562, 99716, 100363, 100375,
100587, 101032, 102274, 102626, 102638, 102790, 102815, 102826, 104557, 104652, 104817, 105125.

Adobe: https://blog.adobe.com/en/publish/2025/10/28/12-new-ways-accelerate-your-creative-process-creative-cloud ·
https://blog.adobe.com/en/publish/2025/12/16/adobe-firefly-improves-ai-video-creation-tools-new-models-unlimited-generations ·
https://blog.adobe.com/en/publish/2026/06/15/from-culling-to-compositing-new-creative-cloud-innovations-across-every-stage-of-your-workflow ·
https://news.adobe.com/news/2026/06/adobe-to-acquire-topaz-labs ·
https://blog.adobe.com/en/publish/2026/09/23/adobe-completes-acquisition-of-topaz-labs ·
https://web.archive.org/web/20260929202411/https://helpx.adobe.com/lightroom/desktop/edit-photos/enhance-images-with-generative-ai.html ·
https://web.archive.org/web/20260906201822/https://helpx.adobe.com/lightroom/desktop/introduction/whats-new.html

Press: PetaPixel articles cited inline (2024-10-28, 2025-10-28, 2026-05-09, 2026-06-15, 2026-06-25,
2026-07-08 [sponsored], 2026-09-23).

Open research used for comparison: https://github.com/ByteDance-Seed/SeedVR (Apache-2.0) ·
https://huggingface.co/ByteDance-Seed/SeedVR2-3B · https://huggingface.co/ByteDance-Seed/SeedVR2-7B ·
arXiv 2501.01320 (SeedVR) · arXiv 2506.05301 (SeedVR2).

Patents: https://patents.google.com/xhr/query (assignee/inventor queries listed in §2.7).
