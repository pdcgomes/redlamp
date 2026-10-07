# INF-11: the cloud processing study (paused)

INF-11 is the study behind DEC-39: which route and providers Redlamp starts with for sending work too heavy for the Mac to a cloud service, generative fill first and then masking and denoise. The routes are a provider the photographer brings their own API key for, a third-party provider Redlamp works with, and a ComfyUI server. The owner started the study on 7 October 2026 and paused it the same day, to resume later. This page says what is done, what is left, and how to pick it up.

## Where it stands

| Part | Tracker | State | Result |
| --- | --- | --- | --- |
| 1. Cloud APIs for mask-based object removal | INF-11 | Written, 7 October 2026 | [INF-11-removal-apis.md](INF-11-removal-apis.md) |
| 2. App Store rules, privacy and keys | INF-11 | Written, 7 October 2026 | [INF-11-app-store-privacy.md](INF-11-app-store-privacy.md) |
| 3. ComfyUI, cloud masking and cloud denoise | INF-11 | Written, 7 October 2026 | [INF-11-comfyui-masks-denoise.md](INF-11-comfyui-masks-denoise.md) |
| 4. The findings: the first route, its providers and a design | INF-11 | Not started | `docs/research/cloud-processing-findings.md` |
| 5. The cloud erasers compared on Redlamp's removal samples | INF-13 | Not started: needs API keys | — |

What the three written parts found, in brief (no account was made and no API called, so nothing is measured yet):

- **Removal.** Eight services remove what a mask covers with no prompt, as Generative Remove's removal-only fill needs (DEC-38): Black Forest Labs' FLUX Erase, Bria Eraser, Ideogram, Stability's Erase, Recraft, Picsart, and fal's Object Removal and Finegrain's eraser on fal. Clipdrop's Cleanup now needs a Jasper Business plan. OpenAI, Gemini and Photoroom need a prompt; Vertex AI's removal mode is discontinued; Adobe's Firefly Fill gives credentials only to enterprise organisations. None takes a reference image or documents 16-bit input or output. The note suggests Bria Eraser, called directly, as the first integration.
- **Rules.** A key the photographer brings needs no in-app purchase in the Mac App Store; a service Redlamp sells does. Every route needs explicit permission that names the provider before a crop is sent (guideline 5.1.2(i), which has named third-party AI since 13 November 2025), a privacy policy, which redlamp.app doesn't have yet, and an accurate App Privacy label. Keys belong in the data protection keychain, on the device only.
- **ComfyUI, masks and denoise.** ComfyUI's own API covers everything Generative Remove needs, and keeps 16-bit precision since mid-2026, but a self-run server has no authentication beyond localhost. Of the hosted services, only Comfy Cloud (from $20 a month) works with a subscription and a key alone; the others need a deployment built first. Removal workflows on Apache-2.0 weights (FLUX.2 [klein] 4B, Qwen-Image, Qwen-Image-Edit-2511, Z-Image-Turbo) run on ComfyUI's core nodes. Cloud masking adds little over Redlamp's masks on the Mac. No cloud service denoises raw data, so AI denoise stays on the Mac (DN-06 to DN-08).

## How to resume

1. **Write the findings** in `docs/research/cloud-processing-findings.md` from parts 1 to 3: the route and provider to start with for generative fill, what masking and denoise could use later, the consent sheet and the handling of keys, a design for providers behind `GenerativeFiller` (`packages/RedlampEngineAPI/Sources/GenerativeFill.swift`), and the tracker rows to build it. Check anything surprising in the notes against their sources first; prices and terms change.
2. **Compare the shortlisted erasers** on Redlamp's removal samples (INF-13): quality beside Generative Remove on the Mac, latency, cost, and whether a seed repeats a fill. This needs the owner's API keys for the providers on the shortlist.
3. **Close the loop:** mark INF-11 Done in the tracker, add the build rows, then run `scripts/roadmap-sync.py` and `scripts/tracker-issues.py --apply`.

## The briefs

Each part was handed to a research agent as written below, with the repository's local path removed. All three ran on 7 October 2026; to check a part again, or to cover something new, give an agent its brief with today's date.

### Part 1: cloud APIs for mask-based object removal

```text
You are a research agent for Redlamp, a native macOS raw photo editor (Swift and Metal, MPL-2.0, repository at the root of this checkout). Today is Wednesday 7 October 2026.

## Context

Redlamp's Generative Remove fills a 'Remove spot' (an area the photographer marked) that is too large for classical content-aware fill. Today it runs FLUX.2 [klein] 4B on the Mac through MLX: the engine hands the model a square crop around the spot of at most 1024 x 1024 pixels (sides multiples of 16), sRGB-encoded, with a mask (1 = repaint), a seed, a named prompt (one of 'remove', 'empty', 'background'; Redlamp offers no free-text prompts: the owner chose removal only), and optionally a reference image. The result comes back in the same form; Redlamp maps it to the photo's camera RGB, stores it in the edit's sidecar as a 16-bit PNG, adds the photo's own noise, blends the rim, and labels it 'Generated'. The relevant protocol is `GenerativeFiller` in packages/RedlampEngineAPI/Sources/GenerativeFill.swift, and the design is docs/plans/2026-10-05-generative-fill-design.md (read both).

On 7 October 2026 the owner decided (tracker row DEC-39 in docs/research/research-tracker.md) that photographers may send such work to a cloud provider, as Adobe uses its own cloud: through a provider they bring their own API key for (BYOK), a third-party provider Redlamp works with, or a ComfyUI server. Tracker row INF-11 is the study that picks the first route and provider, generative fill first. Your part: **the cloud APIs that can do mask-based object removal (inpainting) on a photo crop.**

## Your task

Survey these providers, reading their own documentation, pricing pages and terms (primary sources), and any others you find that fit: fal.ai (and the removal-capable models it hosts, e.g. FLUX.1 Fill [pro], FLUX Kontext, Bria Eraser, LaMa-type erasers, Ideogram edit, Qwen-Image-Edit), Replicate (same question), Black Forest Labs' own API (FLUX.1 Fill [pro] and any FLUX.2 [pro]/[flex] editing), Ideogram's API (Edit with a mask), Stability AI's Stable Image API (Erase, Inpaint), Bria AI (Eraser; note whether its training data is licensed and whether it offers indemnity), Clipdrop (Cleanup), OpenAI (gpt-image models' edits with a mask), Google (Gemini API image editing, and Vertex AI Imagen editing, especially any inpainting-removal mode), Adobe Firefly Services (Generative Fill API) and Photoroom or Picsart if they offer object removal by API. Also check Hugging Face Inference Providers as a route to some of these.

For each provider and model, find and record, citing the URL you read it from:
1. Whether it removes what a mask covers **without a text prompt**, or needs a prompt (and what prompt it documents for removal).
2. Inputs: formats (PNG, JPEG, 16-bit?), maximum size or megapixels, how the mask is given, whether a seed is accepted, output size and format.
3. Call style: synchronous HTTP, or queued with polling or webhooks; published latency if any; SDK needed or plain HTTPS.
4. Price per call or per megapixel, and any free tier.
5. How an individual photographer gets a key: self-serve sign-up and card, waitlist, enterprise only.
6. Data terms: retention of inputs and outputs, whether inputs are used for training, zero-data-retention options, where data is processed (US, EU), content moderation that may refuse requests.
7. Output rights: who owns outputs, commercial use, any watermark (visible, or invisible such as Google's SynthID) or C2PA metadata added to outputs.
8. Anything that makes it a poor fit for a privacy-conscious photo editor.

Then give your assessment: which two or three are the best candidates for a first BYOK integration for Generative Remove (mask-only removal, no prompt, photographic quality, simple key setup for an individual, clean terms), and why; and which would suit a 'third-party provider Redlamp works with' route (an aggregator such as fal or Replicate giving one key for many models). Separate evidence from opinion.

## Rules

- First read docs/research/notes/_conventions.md and follow its conventions; also skim docs/research/open-model-findings.md for the house style (plain, precise, complete sentences, no superlatives; verdicts backed by primary sources, each with its link; mark anything you couldn't verify as UNVERIFIED).
- Network: use `curl -sL` with a browser-like User-Agent (the shell has a proxy already). If a site blocks you, try its docs subpages, its GitHub repositories, raw.githubusercontent.com, or the Wayback Machine (`https://web.archive.org/web/2026/<url>`). The npm and yarn registries are unreachable; PyPI works.
- Do **not** sign up for anything, use or ask for API keys, make paid or authenticated API calls, or print secrets (for example the token in ~/.cache/huggingface/token).
- Write your findings to exactly one new file, `docs/research/notes/INF-11-removal-apis.md` (create it; a comparison table first, then a short section per provider, then your assessment, then a list of every source with the date you read it). Do not edit any other file, do not run builds, and do not commit or push.

## Return

Reply with a summary of at most 400 words: the comparison in brief, your recommended first BYOK candidates and aggregator, the main risks, what you couldn't verify, and the path of the file you wrote.
```

### Part 2: App Store rules, privacy and keys

```text
You are a research agent for Redlamp, a native macOS raw photo editor (Swift and Metal, MPL-2.0, repository at the root of this checkout). Today is Wednesday 7 October 2026. Redlamp ships today as a signed and notarised app from GitHub releases and Homebrew; a Mac App Store release is planned for its 1.0 (Phase 4), with iPad and iPhone apps after that. It has no accounts and no servers of its own except a small relay on redlamp.app that files in-app bug reports as GitHub issues.

## Context

On 7 October 2026 the owner decided (tracker row DEC-39 in docs/research/research-tracker.md) that photographers may send work too heavy for their Mac (generative fill first, later masking and denoise) to a cloud provider, as Adobe uses its own cloud, through one of three routes: (1) a provider the photographer brings their own API key for (BYOK; for example fal, Replicate, Black Forest Labs, OpenAI, Google), entered in Redlamp's Settings; (2) a third-party provider Redlamp works with, which might mean Redlamp selling a subscription or credits and paying the provider (as the open-source editor RapidRAW does: US$14 a month through Lemon Squeezy, with Clerk accounts, its backend relaying crops to fal and on to Ideogram; see docs/research/rapidraw-findings.md section 3.4); (3) a ComfyUI server the photographer runs or hosts. Generative fill would send only a crop of the photo around the area removed (at most 1024 px square), no metadata. Tracker row INF-11 is the study that picks the first route; you cover **the rules, privacy and key handling** that decide between the routes.

## Your task

From primary sources (Apple's own pages, laws and regulators' guidance, the providers' published terms), find and record, quoting the exact text that matters with its URL:

1. **Apple App Review Guidelines, as they stand now (2026):** 3.1.1 (in-app purchase), 3.1.3 and its sub-rules (for example multiplatform services, free stand-alone apps that are companions to paid web tools), and anything about apps that let users enter their own API keys for third-party services. What changed after the US Epic v. Apple injunction (2025) and the EU Digital Markets Act for apps that sell a subscription or credits outside in-app purchase, and how that applies to a Mac App Store app in October 2026. Whether a BYOK design needs in-app purchase at all.
2. **Guideline 5.1.1 and 5.1.2,** including any clause about sharing personal data with third-party AI (Apple added wording about third-party AI to 5.1.2(i); find the exact text and when it was added), and what Redlamp must disclose or ask before sending a photo crop to a provider, both for BYOK (photographer to provider directly) and for a Redlamp-run service. What the App Store privacy label ('App Privacy') would have to declare in each case.
3. **Precedents:** Mac App Store apps that let users bring their own AI provider key (for example AI chat clients or writing tools); confirm two or three from their App Store pages or developers' docs.
4. **Keeping keys on the Mac:** Apple's Keychain guidance for storing a user-supplied secret (generic password items, accessibility classes, whether to synchronise through iCloud Keychain, sandbox and keychain access groups), with Apple documentation links. Note anything relevant for a sandboxed App Store build.
5. **Privacy law, briefly:** under the GDPR (and the UK GDPR), who is controller and who is processor when (a) the photographer sends data directly to a provider with their own key from an app that has no servers, and (b) the app's developer runs a service that relays the data to a provider. What (b) would oblige Redlamp to have: a privacy policy, data processing agreements, a list of sub-processors, international transfer mechanisms. Cite the regulation's articles or EDPB guidance. Also check whether redlamp.app currently publishes a privacy policy (`curl -sL https://redlamp.app/privacy` and similar paths, and the site's footer).
6. **Provenance of generated pixels:** whether OpenAI, Google (SynthID), Adobe, Black Forest Labs, Stability AI, Ideogram or fal-hosted models add C2PA Content Credentials or invisible watermarks to their outputs, and what that means when a fill is composited into a photographer's raw edit and exported; and the C2PA specification's digital source type for a composite with AI-generated parts (Redlamp plans C2PA export as tracker row RM-03).

Then give your assessment: what each route requires of Redlamp in the Mac App Store and outside it (direct download), which route is lightest to ship first under these rules, and the consent and disclosure Redlamp should show before the first cloud request. Separate evidence from opinion.

## Rules

- First read docs/research/notes/_conventions.md and follow its conventions; also skim docs/research/open-model-findings.md for the house style (plain, precise, complete sentences, no superlatives; claims backed by primary sources with links; mark anything you couldn't verify as UNVERIFIED). This is an engineering survey, not legal advice; say so once.
- Network: use `curl -sL` with a browser-like User-Agent (the shell has a proxy already). If a site blocks you, try alternative pages, the Wayback Machine (`https://web.archive.org/web/2026/<url>`), or official PDFs. The npm and yarn registries are unreachable; PyPI works.
- Do **not** sign up for anything, use or ask for API keys, make authenticated calls, or print secrets (for example the token in ~/.cache/huggingface/token).
- Write your findings to exactly one new file, `docs/research/notes/INF-11-app-store-privacy.md` (create it; one section per numbered item above, then your assessment, then a list of every source with the date you read it). Do not edit any other file, do not run builds, and do not commit or push.

## Return

Reply with a summary of at most 400 words: the key rules for each route, the lightest route to ship first and why, the consent Redlamp should ask for, what you couldn't verify, and the path of the file you wrote.
```

### Part 3: ComfyUI, cloud masking and cloud denoise

```text
You are a research agent for Redlamp, a native macOS raw photo editor (Swift and Metal, MPL-2.0, repository at the root of this checkout). Today is Wednesday 7 October 2026.

## Context

On 7 October 2026 the owner decided (tracker row DEC-39 in docs/research/research-tracker.md) that photographers may send work too heavy for their Mac (generative fill, denoise, masking and the like) to a cloud provider, as Adobe uses its own cloud: through a provider they bring their own API key for (BYOK), a third-party provider Redlamp works with, or a ComfyUI server. Tracker row INF-11 is the study that picks the first route; tracker row RM-17 is 'ComfyUI as a fill server wherever the photographer runs it, on their network or hosted in the cloud'. Redlamp's Generative Remove today runs FLUX.2 [klein] 4B on the Mac through MLX on a crop of at most 1024 px with a mask (see docs/plans/2026-10-05-generative-fill-design.md and packages/RedlampEngineAPI/Sources/GenerativeFill.swift). Redlamp already has strong on-device masks (Apple Vision, Segment Anything 2.1 and SAM 3 through Core ML, Depth Anything 3, per-pixel matting) and a classical noise reduction; an on-device AI raw denoiser is planned but not trained (tracker rows DN-06 to DN-08, and DN-11's note docs/research/notes/DN-11-lightroom-raw-denoise.md). Background on RapidRAW, an open-source editor that already drives ComfyUI and a paid cloud, is in docs/research/rapidraw-findings.md sections 3.3 and 3.4 (read them).

## Your task, in three parts

**1. ComfyUI as a route.** (a) Self-run ComfyUI: document its HTTP and WebSocket API from primary sources (the ComfyUI repository's server code and docs, docs.comfy.org): queueing a workflow (`/prompt`, the API-format workflow JSON), progress over `/ws`, results (`/history`, `/view`), uploads (`/upload/image`, masks), cancelling (`/interrupt`, `/queue`), and what authentication or TLS it has (or doesn't) when exposed beyond localhost. (b) Hosted ComfyUI that a third-party Mac app could call with a key: Comfy Org's own cloud or API offerings, RunComfy, ComfyDeploy, ViewComfy, Replicate's ComfyUI workflow models, fal's ComfyUI support, RunPod's serverless ComfyUI worker, Modal, and others you find. For each: whether it accepts ComfyUI API-format workflows, how calls are authenticated, cold starts and published latency, pricing, data retention, and how hard setup is for a photographer who isn't technical. (c) Object-removal workflows a photographer could run, using only models whose weights allow commercial use (check each licence from its model card: for example FLUX.2 [klein] 4B is Apache-2.0, FLUX.1 Fill [dev] is non-commercial, Qwen-Image-Edit is Apache-2.0, LaMa is trained on Places2 which Redlamp's rule DEC-24 excludes); and the custom nodes such workflows need, with their licences.

**2. Cloud masking.** Which providers host promptable segmentation (SAM 2/2.1, SAM 3, Grounded SAM, Florence-2, other text-prompted segmenters) as an API: fal, Replicate, Hugging Face Inference Providers, Roboflow, others; inputs (image size limits), outputs (mask format, resolution), price, latency, terms, and the model licences (SAM 3's licence travels with it). Assess briefly whether cloud masking adds anything over Redlamp's on-device masks (for example, Macs with little memory, or larger models).

**3. Cloud denoise for raw photos.** Whether any provider offers denoising by API for raw files (DNG or camera raw) rather than RGB images: check Topaz Labs (any public API), DxO, Adobe (Firefly Services or Lightroom APIs), Let's Enhance or Claid, Replicate and fal models (NAFNet, Restormer, SCUNet and similar), and anything else you find. For each: input formats, maximum sizes, what an upload of a 24-60 MP photo costs in size (a 16-bit TIFF is about 6 bytes a pixel; a raw file 25-80 MB), price, latency, terms. Assess whether cloud denoise fits Redlamp, which develops raws on the Mac in a scene-linear pipeline and stores results non-destructively.

## Rules

- First read docs/research/notes/_conventions.md and follow its conventions; also skim docs/research/open-model-findings.md for the house style (plain, precise, complete sentences, no superlatives; claims backed by primary sources with links; mark anything you couldn't verify as UNVERIFIED).
- Network: use `curl -sL` with a browser-like User-Agent (the shell has a proxy already). If a site blocks you, try its docs subpages, its GitHub repositories, raw.githubusercontent.com, or the Wayback Machine (`https://web.archive.org/web/2026/<url>`). You may use `gh api` for GitHub. The npm and yarn registries are unreachable; PyPI works.
- Do **not** sign up for anything, use or ask for API keys, make paid or authenticated API calls, install or run ComfyUI, or print secrets (for example the token in ~/.cache/huggingface/token).
- Write your findings to exactly one new file, `docs/research/notes/INF-11-comfyui-masks-denoise.md` (create it; one section per part, each with a comparison table, then your assessment for each part, then a list of every source with the date you read it). Do not edit any other file, do not run builds, and do not commit or push.

## Return

Reply with a summary of at most 400 words: for each part the key findings and your assessment, what you couldn't verify, and the path of the file you wrote.
```
