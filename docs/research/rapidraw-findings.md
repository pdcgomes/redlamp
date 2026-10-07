# What Redlamp Can Learn from RapidRAW

**Date:** 7 October 2026. **Subject:** RapidRAW v1.6.5 (`main` at `8387fc1`, 6 October 2026), its rawler fork ([RapidRAW-DngLab](https://github.com/CyberTimon/RapidRAW-DngLab) at `934af4b`, the commit RapidRAW pins), the RapidRAW AI Connector (`main` of 31 August 2026), and the RapidRAW Cloud page and privacy policy on getrapidraw.com (read 7 October 2026).
**Decisions and status:** the owner decided on 7 October 2026 ([section 8](#8-decisions-and-tracker-rows)): fills may go to paired Macs and servers on the local network only (DEC-37), and Generative Remove stays removal only for now (DEC-38). Five proposals are rows in the [research intake tracker](research-tracker.md): RM-15, RM-16, RM-17, INF-10 and CAM-27.

RapidRAW is an open-source raw editor by Timon Käch, started in June 2025, with over 10,000 stars on GitHub. It runs on Windows, macOS, Linux and Android, and ships about once a week. What sets it apart is how it offers AI: the same tools run on small models built into the app, on a ComfyUI server the photographer runs, on a paid cloud, or not at all. This study asked how that works, how it compares with Redlamp, and what Redlamp should take from it.

## How this was done

- RapidRAW, its rawler fork and its AI Connector were read from clones in `build/oss/` (gitignored), with their release notes, issues and website. RapidRAW is AGPL-3.0: as DEC-01 allows, its source was read to understand its behaviour only. No code was copied, translated or paraphrased; behaviour is described in prose.
- Licences were read from GitHub's licence API and Hugging Face's model API on 7 October 2026.
- Nothing was run: RapidRAW wasn't built, and no ComfyUI server was set up. Speeds quoted for RapidRAW come from its own issues.
- Redlamp's side was checked against the README, the tracker and the code on 7 October 2026.

## Contents

1. [Executive summary](#1-executive-summary)
2. [RapidRAW at a glance](#2-rapidraw-at-a-glance)
3. [How RapidRAW uses AI](#3-how-rapidraw-uses-ai)
4. [Compared with Redlamp](#4-compared-with-redlamp)
5. [What to adopt](#5-what-to-adopt)
6. [What not to follow](#6-what-not-to-follow)
7. [Licensing](#7-licensing)
8. [Decisions and tracker rows](#8-decisions-and-tracker-rows)

---

## 1. Executive summary

**RapidRAW's lesson for Redlamp is not a model but a choice of where the work runs.** Its built-in models are older than Redlamp's, run on the CPU, and several have training data or licences Redlamp's licence gate refuses. What it can do that Redlamp can't is reach more compute than the computer in front of the photographer: a GPU on the network running whatever ComfyUI workflow the photographer likes, or a paid service. Redlamp's Generative Remove runs on the Mac with no account, but only on Macs with 16 GB of memory or more. RapidRAW Cloud, launched on 6 October 2026, is aimed at the photographers this leaves out.

**Lessons, in priority order:**

| # | Lesson | Verdict | Phase |
| --- | --- | --- | --- |
| 1 | **Measure Generative Remove on an 8 GB Mac.** The 16 GB minimum follows from a 1024-pixel fill's 6.6 GB peak; a 512-pixel fill peaks at 4.2 GB on the M1 Ultra, and no smaller Mac has been measured. If a smaller crop fits, photographers without a 16 GB Mac, the ones RapidRAW Cloud is for, get Generative Remove on the device, free | Adopt | Now |
| 2 | **Fills from a server the photographer runs:** the crop Redlamp already prepares for its model, sent through the same `GenerativeFiller` protocol to another Mac running Redlamp (and in Phase 5 serving iPad and iPhone), or to ComfyUI through ComfyUI's own API, with no middleware and never to a third party | Do better | P3, P5 |
| 3 | **An AI-Free mode:** one switch hides every AI tool and leaves the classical ones; edits that already hold AI results still render | Adopt | P3 |
| 4 | **Export a look as a `.cube` LUT,** for the log spaces import already knows, so recipes and film simulations reach video editors | Adopt | P2–P3 |
| 5 | **Decide on prompted generation** (RapidRAW's Generative Replace) and Generative Expand. RM-10's design kept the text encoder for a prompt add-on | Decide | — |
| 6 | **Apple's RAW 9 decoder** (macOS 27): a comparator for the denoise study and a labelled fallback for bodies LibRaw can't read, not a second pipeline | Adopt, narrowly | P3 |
| 7 | **No Redlamp cloud and no bring-your-own-key APIs.** RapidRAW Cloud sells access to a third-party model whose retention its own privacy policy says it can't verify | Skip | — |

**What Redlamp already does better, and should keep:** edits that never change when the app updates (RapidRAW's v1.6.5 notes ask photographers to finish client shoots before upgrading), fills kept as 16-bit camera RGB with the photo's own noise rather than 8-bit JPEG patches, inference on the GPU and Neural Engine rather than the CPU, mask edges solved per pixel, and models whose licences and training data were read from primary sources.

---

## 2. RapidRAW at a glance

| | RapidRAW | Redlamp |
| --- | --- | --- |
| Licence | AGPL-3.0 | MPL-2.0 |
| Platforms | Windows 10, macOS 13 (Apple Silicon and Intel), Linux, Android | macOS 26 on Apple Silicon; iPad and iPhone in Phase 5 |
| Stack | Rust and Tauri, with a React and TypeScript interface; the image pipeline runs on wgpu, mostly in one WGSL shader of about 2,000 lines | Swift, Metal and AppKit |
| Raw decoding | rawler (dnglab, LGPL-2.1), in the app | LibRaw for unpacking only, in a sandboxed service; demosaic and colour are Redlamp's |
| Lens corrections | lensfun's database, bundled | Makers' embedded data, DNG opcodes and the photographer's own LCP files |
| AI runtime | ONNX Runtime 1.22, on the CPU | Core ML and Vision (GPU and Neural Engine), MLX (GPU) |
| Sidecar | `.rrdata` JSON (`version: 1`), with AI masks and patches as base64 inside it | A `.redlamp` package: `edit.json` and PNG bitmaps, with a format version and a process version |
| Old edits after an update | Can change: v1.6.5 changed how white balance renders them | Never change: each process version renders as it did, checked against recorded references |
| macOS build | Not code-signed: photographers remove the quarantine flag by hand | Signed and notarised |
| Cadence and reach | 67 releases since July 2025; 10,355 stars, 592 forks, 416 open issues and pull requests (7 October 2026) | — |

RapidRAW is broader than Redlamp outside the Develop module: albums, keyword tags, virtual copies, a side-by-side culling view, HDR merge, panoramas, focus stacking, film negative conversion, collages, watermarks, liquify, tethering through libgphoto2 (in a separate build), a headless exporter, and an Android app. Redlamp goes deeper where they overlap: Lightroom's panels, sliders and keyboard shortcuts (97 actions), process versions, film looks measured from cameras or simulated from datasheets, mask edges solved per pixel, focus stacks that develop like a raw, and measured performance (0.6–3 ms per interactive render at Fit).

---

## 3. How RapidRAW uses AI

### 3.1 Four ways to run it

| Tier | What runs | Where | Cost | The photo |
| --- | --- | --- | --- | --- |
| Built-in | Small ONNX models: masks, tagging, denoise, basic inpainting | The computer's CPU | Free | Never leaves the computer |
| Self-hosted | Any ComfyUI workflow, through the RapidRAW AI Connector | The photographer's own GPU server | Free, with a GPU of 8 GB or more | Stays on the network |
| RapidRAW Cloud | Ideogram's object-removal model, through fal | RapidRAW's backend, fal (USA), Ideogram (Canada) | US$14 a month for 200 edits | A crop around the mask is sent |
| AI-Free | Nothing | — | Free | — |

The Generative Edit panel fills a selection either with the built-in LaMa ("basic inpainting", also offered as a Quick Erase brush), or, when a self-hosted or cloud backend is set up, with what the photographer describes in words (Generative Replace). Its patches are listed beside Clone, Heal, Liquify and Retouch patches.

### 3.2 Built-in models

Each model downloads on first use from the author's Hugging Face repository, which states no licence, and is checked by SHA-256. All of them run on ONNX Runtime's default CPU provider: no Core ML or GPU provider is configured. AI denoise of a 24 MP Sony raw took 2 min 20 s in [#997](https://github.com/CyberTimon/RapidRAW/issues/997).

| Feature | Model (download) | Licence and data | Redlamp's equivalent |
| --- | --- | --- | --- |
| Subject, by box or one click | Segment Anything ViT-B (encoder 100 MB, decoder 9 MB). The files are named for Segment Anything 1's ViT-B checkpoint, though the v1.5.2 notes say SAM 2 | Apache-2.0; SA-1B | Vision's Subject and People; Segment Anything 2.1 Objects by hover, click, box or brush; edges solved per pixel |
| Foreground | U-2-Net (176 MB) | Apache-2.0 code; training data not checked | Vision's Subject and Background |
| Sky | A U-2-Net sky model (176 MB) | Source not stated | Segment Anything 2.1 prompted inside a classical estimate, with Depth Anything 3, and every edge pixel solved |
| Depth | Depth Anything V2 Small (99 MB) | Apache-2.0 | The photo's own depth, Depth Anything 3, or the same V2 Small |
| Tagging and search | CLIP (606 MB) over 590 built-in words or the photographer's own list, plus colour tags | Which CLIP isn't stated (its size matches a ViT-B/32) | None yet: the library is a later track |
| AI denoise | NIND UtNet (124 MB) | nind-denoise is GPL-3.0 | Classical noise reduction now; a raw denoiser is planned (DN-07) |
| Basic inpainting | LaMa in half precision (112 MB) | Apache-2.0 code; Big-LaMa is trained on Places2 | Content-aware Remove (classical) and Generative Remove |
| Lens blur | From the depth map | — | Later (OTH-03) |
| Culling suggestions | No model: perceptual hashes find duplicates, Laplacian variance finds blur | — | Ratings, flags and labels; AI-assisted culling proposed (OTH-02) |

A `SAM3` branch from May 2026 adds SAM 3 and its tracker, and the model repository already holds SAM 3's ONNX files (vision 498 MB, text 355 MB); `main` doesn't use them. Redlamp ships SAM 3 for Landscape and People parts under DEC-27.

On macOS 27, RapidRAW can also develop or denoise raws with Apple's RAW 9 decoder through Core Image, which demosaics and denoises in one step on the Neural Engine; cameras it doesn't support fall back to RapidRAW's own processing.

### 3.3 Self-hosted: the AI Connector and ComfyUI

The [RapidRAW AI Connector](https://github.com/CyberTimon/RapidRAW-AI-Connector) is a small Python server (FastAPI, Apache-2.0) between the app and ComfyUI:

1. The app asks the connector to inpaint a photo, named by a hash of its path and modification time, with a mask, a prompt and a seed. If the connector hasn't seen the photo, the app uploads the whole photo once (as decoded, without the edit's adjustments) as an 8-bit JPEG at quality 95, and asks again; later edits of that photo send only the mask and the prompt.
2. The connector writes the photo, the mask, the prompt and the seed into a ComfyUI workflow file at fixed node IDs, queues it, waits for ComfyUI's WebSocket to say it has finished, and fetches the result.
3. It returns the mask's bounding box plus 16 pixels as a PNG, with its offset, and the app composites it into the photo.

The default workflow is SDXL inpainting in 8 steps: RealVisXL V5.0 Lightning (an SDXL fine-tune under OpenRAIL++), ControlNet Union SDXL ProMax in repaint mode (Apache-2.0) and the Inpaint Crop and Stitch nodes (GPL-3.0). Photographers can use their own workflow if it keeps the node IDs the connector expects.

**The friction is the setup.** The app talks to the connector, which talks to ComfyUI, on two different ports, and the workflow has to match. The issues show the results: HTTP 405 from pointing the app at ComfyUI instead of the connector ([#739](https://github.com/CyberTimon/RapidRAW/issues/739)), missing output nodes and schema errors from changed workflows ([#432](https://github.com/CyberTimon/RapidRAW/issues/432), [#424](https://github.com/CyberTimon/RapidRAW/issues/424)), and installation steps that aren't clear for people outside IT ([#789](https://github.com/CyberTimon/RapidRAW/issues/789)). In [#997](https://github.com/CyberTimon/RapidRAW/issues/997) a photographer asks whether ComfyUI will ship with the app, since setting it up "creates massive friction for the end user who is a photographer but not a computer scientist".

### 3.4 RapidRAW Cloud

RapidRAW Cloud launched with v1.6.5 on 6 October 2026: US$14 a month for 200 edits, with accounts at Clerk, billing by Lemon Squeezy and usage counters at Upstash, on the desktop apps only. When the edits run out, one click switches the tool back to the CPU model.

- **What leaves the computer:** a crop around the mask (its bounding box widened by half its size on each side, at most 1.5 MP) as a JPEG at quality 95, with the mask. The raw file and its metadata aren't sent.
- **Where it goes,** by the [privacy policy](https://www.getrapidraw.com/privacy-policy) (effective 20 September 2026): to RapidRAW's backend on Hetzner servers in the EU, which keeps it in memory only; then to fal (USA), instructed not to store it; then to Ideogram's object-removal model (Toronto). The policy says RapidRAW "cannot independently verify how long Ideogram keeps request data, or in which countries it is processed", and that Ideogram's general policy "permits broader use of uploaded content". Requests that fal or Ideogram flag are refused, and Ideogram may keep what they contain.
- **What it's for:** "large removals, textures, buildings", which the CPU's LaMa smears; the cloud page shows an escalator's grooves rebuilt and the Eiffel Tower removed from a skyline.

### 3.5 AI-Free mode

One switch in Settings hides every AI control (AI masks, generative patches, lens blur), and denoise falls back to BM3D. Edits that already hold AI masks or patches still render. It's offered "for purists, contest photographers, or those with ethical or privacy-related objections to AI tools".

### 3.6 How generated pixels are kept

A patch is stored inside the sidecar as base64: its colour as an 8-bit JPEG (quality 95 for generative patches, 100 for Clone and Heal) and its mask, sRGB-encoded for raws, composited onto the photo before it's developed. Redlamp keeps a fill as 16-bit camera RGB in a PNG in the sidecar package, adds the photo's own noise when it renders, blends its rim as Heal does, and renders it the same on any Mac.

---

## 4. Compared with Redlamp

### 4.1 AI, side by side

| | RapidRAW | Redlamp |
| --- | --- | --- |
| Where inference runs | The CPU (ONNX Runtime) | The GPU and Neural Engine (Core ML, Vision), the GPU (MLX) |
| Subject and people | Segment Anything ViT-B by box or click; U-2-Net for the foreground | Vision's Subject, Background and People (each person, and face parts), Segment Anything 2.1 Objects, edges solved per pixel, ViTMatte's stray strands |
| Sky | U-2-Net | Segment Anything 2.1 and Depth Anything 3, every edge pixel solved; IoU 0.945 against OneFormer on 14 CC0 photos (MSK-17) |
| Landscape classes and body parts | None (SAM 3 is on a branch) | SAM 3 |
| Depth | Depth Anything V2 Small | The photo's own depth, Depth Anything 3, V2 Small |
| Removing small things | LaMa (trained on Places2), Clone, Heal | Content-aware Remove, Heal, Clone, and Remove Dust across a shoot |
| Choosing what to remove | A brushed or AI-masked selection | A click on a person or an object, which takes its shadow and reflection too, or Find by name (OWLv2) |
| Removing large things | ComfyUI on a server, or the cloud | FLUX.2 [klein] 4B on the Mac: a 2.41 GB download for Macs with 16 GB or more, 11 s at 512 pixels to 46 s at 1024 on an M1 Ultra, three fills to choose from |
| Prompted generation | Generative Replace, through ComfyUI | None: removal only, by the owner's choice of 5 October 2026 |
| Generated pixels | 8-bit JPEG patches in the sidecar | 16-bit camera RGB, given the photo's noise, labelled Generated on the canvas, in the panel and in History |
| AI denoise | NIND (GPL-3.0) on the CPU; Apple's RAW 9 | Planned, on raw data (DN-07); classical noise reduction now |
| Tagging and search | CLIP | None yet |
| Turning AI off | AI-Free mode | No switch |
| Privacy | The computer, the photographer's network, or a chain of third parties | Every model runs on the Mac; photos are never uploaded |
| Model licences | A model repository with no stated licence; Places2, GPL-3.0 and unstated lineages | Code, weights and training data read from primary sources; a licence gate in CI (INF-01) |

### 4.2 Raws, cameras and colour

RapidRAW doesn't use LibRaw. It decodes with rawler, the Rust library from dnglab (LGPL-2.1), through the author's fork, which is 56 commits ahead of dnglab and 136 behind. rawler's own steps develop the raw (scaling, demosaic, white balance, the colour matrix, crops) before RapidRAW's shader takes over. RapidRAW ships no camera profiles of its own: each camera's colour comes from the matrices in rawler's camera files.

| | RapidRAW | Redlamp |
| --- | --- | --- |
| Decoder | rawler, in the app. Since July 2026, a raw it can't decode opens on its embedded JPEG | LibRaw 0.22.2, for unpacking only, in a sandboxed service. A raw it can't read doesn't open |
| Cameras | About 825 models in rawler's list, each a small TOML file: the CFA pattern, crops, optional black and white levels, and two colour matrices. The fork adds bodies before dnglab does (Sony A7 V, Fujifilm X-T30 III, Nikon ZR). Nikon's High Efficiency NEFs aren't read | LibRaw lists 1,258; 26 are verified by CC0 samples in the decode tests and 742 camera modes have camera bench reports ([cameras](../cameras.md)). The A7 V and Nikon's High Efficiency NEFs wait on LibRaw (CAM-13, CAM-12) |
| Bayer demosaic | PPG (patterned pixel grouping); a quarter-size "superpixel" for thumbnails and quick previews | Menon, Andriani and Calvagno (2007), with a dual pass where neighbours differ only by noise |
| X-Trans demosaic | An interpolation from neighbours of the same colour, in four passes | A first-generation interpolation; Markesteijn is CAM-07 |
| Highlights | Kept above white since a fork commit of 13 September 2026; before it, highlights could clip at white ([#1727](https://github.com/CyberTimon/RapidRAW/issues/1727)). Then a per-pixel correction removes the magenta that clipped green leaves and rolls clipped colours toward white | Clipped photosites rebuilt on the mosaic from unclipped neighbours, in the colour measured around them; fully blown areas stay neutral |
| Colour matrix | Adobe's. rawler's files carry Adobe's matrices for illuminant A and D65 (the Sony A7 III's D65 matrix is the one LibRaw ships); rendering uses only the D65 one, and the other serves the Kelvin readout | LibRaw's Adobe-derived D65 matrix for non-DNG raws; DNGs interpolate their two calibrations by white balance (CAM-04) |
| Working space | Linear sRGB. Negative values are cut to zero as the raw opens, so colours outside sRGB are lost before any edit. AgX tone mapping works in an inset Rec. 2020 | Linear Rec. 2020 from camera RGB; nothing is cut before the output |
| DNG extras | Not applied: opcode lists (phones' lens-shading gain maps, lens warps and vignetting), ForwardMatrix, HueSatMap and LookTable, profile tone curves, baseline exposure and ProRAW's gain table map. rawler copies them only when it writes DNGs | Gain maps, WarpRectilinear and FixVignetteRadial, the HueSatMap, the profile's look as a Base Look, and ProRAW's gain table map |
| Linear DNGs | Not demosaiced, and kept above white; settings apply a gamma or skip the matrix for files with a colour cast | Clamped at white, so no highlight headroom ([raw pipeline](../raw-pipeline.md)) |
| Lens corrections | lensfun's database, bundled | Makers' embedded data, DNG opcodes and the photographer's own LCP files; lensfun waits on counsel (DEC-04) |
| Profiles and looks | No camera profiles, DCPs or input ICC profiles. AgX or a basic tone mapper; a Color Calibration panel (shadows tint, primaries); `.cube`, `.3dl` and image LUTs; six film LUTs from spektrafilm (CC BY-SA 4.0) | Base Looks: Redlamp's own, four measured from cameras' JPEGs, 36 film simulations built from datasheets, and a DNG's own profile; `.cube`, `.3dl` and HaldCLUT import |
| Output | sRGB only, with a CC0 sRGB profile embedded since 3 October 2026 | sRGB or Display P3, at 8, 10 or 16 bits |
| Apple's decoder | RAW 9 on macOS 27 as an alternative developer, with Apple's boost, contrast, local tone mapping and lens correction off | Not used (CAM-27 would evaluate it) |

RapidRAW's raw handling isn't ahead of Redlamp's on accuracy anywhere: its demosaic, highlights, gamut and DNG support are simpler, and its colour is one D65 matrix into sRGB. Its decoder is ahead on coverage in places: bodies LibRaw 0.22.2 doesn't read, such as the A7 V (CAM-13), and JPEG XL mosaic DNGs, which rawler decodes with jxl-oxide (Apache-2.0) and Redlamp refuses for now (CAM-10). Three smaller points:

- **Linear DNGs keep their headroom in RapidRAW** and not in Redlamp, whose raw pipeline lists the clamp as a known limit.
- **Opening an undecodable raw on its embedded JPEG** saves the photographer an error, but only RapidRAW's log says they're editing an 8-bit preview. If Redlamp ever did this, it would have to say so on the photo.
- **dnglab's illuminant-A matrices** show that Adobe's second matrix exists for non-DNG cameras, where Redlamp has one. They're LGPL-2.1 data derived from Adobe's converter, so they can't come from there; a second matrix would come from Redlamp's own measurement.

### 4.3 Positioning

RapidRAW competes on breadth, price and speed of shipping: free, on every desktop platform and Android, with a paid cloud for heavy generative work. Redlamp competes on being native to the Mac and familiar to Lightroom users, on edits that never change, and on private AI with no account. RapidRAW Cloud makes one gap plain: photographers with neither a large GPU nor a 16 GB Mac. Redlamp has no Generative Remove for them today; lessons 1 and 2 address that without a cloud.

---

## 5. What to adopt

### 5.1 Generative Remove on 8 GB Macs (lesson 1)

Generative Remove is offered on Macs with 16 GB or more because a 1024-pixel fill peaks at 6.6 GB, beside the app's own couple of gigabytes. Smaller crops need less: 4.2 GB at 512 pixels and 5.2 GB at 768 on the M1 Ultra, with the 4-bit model (2.22 GB). Fill times on other Macs haven't been measured. Measure fill time, memory pressure and swap on an 8 GB Mac at 512 and 768 pixels; if one fits, offer Generative Remove there with the crop capped at that size. The cap makes large holes coarser (the car's fill is already 508 × 234 pixels over 2032 × 936), which the panel should say. Size S; it needs an 8 GB Mac.

### 5.2 Fills from a server the photographer runs (lesson 2)

The seam is already there. The engine hands its model a crop through `GenerativeFiller` (`RedlampEngineAPI`): at most 1024 pixels square, sRGB-encoded, with a mask, a seed, a named prompt and, optionally, a reference image, and it gets the same form back, which it maps to camera RGB, stores, gives the photo's noise and blends. A remote filler implements the same protocol over the network:

- **Another Mac running Redlamp.** A Mac Studio serves fills to a MacBook Air: the big Mac's app, or `redlamp serve` (the CLI already links the model), advertises itself over Bonjour, and the small Mac pairs with it once. It runs the same model, steps and seeds the app uses on the device. In Phase 5 the same server gives iPad and iPhone Generative Remove, since they don't run the model themselves. This is RapidRAW's self-hosting done Redlamp's way: nothing to install, one model, no Python.
- **ComfyUI.** For photographers with a GPU on the network, the app talks to ComfyUI's own HTTP and WebSocket API (upload the crop and mask, queue a workflow, follow its progress, fetch the result, interrupt it to cancel), with nothing in between. A workflow is a template whose named inputs (image, mask, reference, seed, prompt) are mapped to its nodes and checked when it's imported, so a workflow that doesn't fit is refused with the reason, not at fill time. Templates shipped with Redlamp name only models whose weights allow commercial use, such as FLUX.2 [klein] 4B or Qwen-Image-Edit-2511 (both Apache-2.0); photographers may import their own. Redlamp ships no weights on this path, so a model's licence is the photographer's to accept.
- **What stays the same:** only the crop leaves the Mac, and only for an address the photographer entered or paired. The fill keeps its provenance (the server, the model or workflow, and its hash) and its Generated label, and Content Credentials record it once they land (RM-03).
- **Decided** (DEC-37, 7 October 2026): fills may go to paired Macs and servers on the local network only. The README says photos are never uploaded; when the first remote fill ships it will say they leave the Mac only for a server you run on your network.
- **Still unknown:** ComfyUI's images are 8-bit, so a fill's round trip is too; Redlamp's tone-normalised crop and the noise it adds should hide that, which needs checking. Pairing and TLS need a design.

Size M for the remote filler and the Mac server, and S for each ComfyUI template.

### 5.3 AI-Free mode (lesson 3)

A switch in Settings that hides the AI components in Masking (Subject, Background, People, Sky, Objects, Landscape, Depth Range), Click picks and Find in the Healing tool, Generative fill and the model downloads, and leaves the classical tools: content-aware Remove, Heal, Clone, Remove Dust, brush, gradient and range masks, and noise reduction. Edits that already hold AI masks or fills keep rendering, since those are stored as pixels, but they can't be updated while the switch is on. A second level, "no generated pixels", may suit contest and press rules that allow selective adjustments but not generated content; whether to offer it is decided in INF-10's design. Once Content Credentials land (RM-03), exports record what was used. Size S.

### 5.4 Export a look as a `.cube` LUT (lesson 4)

RapidRAW exports an edit as a `.cube`, from the app and its command-line exporter, so a grade made on a still can be applied to video. Redlamp imports `.cube`, `.3dl` and HaldCLUT looks, including LUTs made for S-Log3, LogC3, V-Log and Apple Log footage, but doesn't export them. Export a recipe, or an edit's global colour and tone, as a 33- or 65-point `.cube` for a chosen input (display-referred, or one of the log spaces import knows), by rendering a lattice through the develop kernel with spatial adjustments off. The dialog lists what a LUT can't carry: masks, Clarity, Texture, noise reduction, sharpening, vignette and grain. It takes Redlamp's recipes and film simulations to Final Cut Pro and DaVinci Resolve. Size S–M.

### 5.5 Prompted generation and Generative Expand (lesson 5)

RapidRAW's Generative Replace fills a selection with what the photographer describes. Redlamp chose removal only on 5 October 2026, and the [generative fill design](../plans/2026-10-05-generative-fill-design.md) keeps Qwen3's text encoder "for tests and a prompt add-on later". The choices:

1. Keep removal only, in line with SKIP-11's "truthful editing" (recommended for now).
2. A Mac-only prompt add-on: the text encoder (Apache-2.0) as a further download, about 8 GB in bfloat16 and less quantised (untested).
3. Prompts only through a server the photographer runs (5.2), where the text encoder runs on the server.

The owner kept removal only for now (DEC-38, 7 October 2026).

Generative Expand, which fills the white corners a straightened or transformed photo leaves, is the same filler on a different mask. RapidRAW's users ask for it ([#1182](https://github.com/CyberTimon/RapidRAW/issues/1182)), Lightroom's Desktop and mobile apps have it, and the [Lightroom comparison](../lightroom-comparison.md) lists it as Undecided. Whatever is chosen, fills stay labelled and recorded.

### 5.6 Apple's RAW 9 decoder (lesson 6)

The [CAM-12 note](notes/CAM-12-nikon-high-efficiency.md) judged `CIRAWFilter` a fallback at most: it returns Apple's demosaiced, white-balanced image, so Redlamp's highlight reconstruction, demosaic, noise model and camera colour wouldn't apply, and its result would change with Apple's decoder versions. RAW 9 doesn't change that. Two narrow uses remain: as a comparator in the blind denoise study (DN-09), since every Mac on macOS 27 has it, and as a labelled fallback decoder for bodies LibRaw can't read yet (CAM-12, CAM-13). Evaluating it needs macOS 27; this Mac runs macOS 26.6. Size S.

### 5.7 Smaller points

- **Lens blur** (OTH-03): RapidRAW's turns depth into a signed blur radius that fades on either side of the range in focus, after refining the depth with a guided filter against the photo. That is the approach the tracker planned, and a sign photographers want it.
- **Tagging and search,** for the later library track: Vision's built-in image classification needs no download and no licence review, and SigLIP 2 (Apache-2.0) could serve searches in words.
- **Culling** (OTH-02): RapidRAW's suggestions are classical (perceptual hashes, Laplacian variance); Redlamp's focus-stack detection already compares sharpness across frames.
- **Importing `.rrdata` edits:** the format is plain JSON, but RapidRAW's tone and colour work differently from Redlamp's, so any mapping would be approximate, for a small audience. Not now.
- **A shared fill protocol:** the AI Connector's Apache-2.0 licence suggests RapidRAW's author is open to permissive pieces, and a documented fill protocol both apps spoke would let one server serve both. Optional, and only if the owner wants to ask.

---

## 6. What not to follow

- **A Redlamp cloud, or bring-your-own-key model APIs** (fal, Replicate, Ideogram and others). They need accounts, billing and quotas, and send photos through providers whose retention can't be checked, as RapidRAW's own policy says of Ideogram. Both contradict "no cloud and no credits". Record a skip.
- **A middleware between the app and ComfyUI.** It doubles what can be misconfigured; 5.2 talks to ComfyUI directly.
- **Generated pixels as 8-bit JPEG, or bitmaps as base64 inside the sidecar's JSON.**
- **Rendering changes that alter old edits.**
- **RapidRAW's models.** None improves on what Redlamp ships, and LaMa (Places2), the NIND denoiser (GPL-3.0) and the unidentified CLIP and sky models wouldn't pass the licence gate.
- **Inference on the CPU only.**

---

## 7. Licensing

Read from GitHub's licence API and Hugging Face's model API on 7 October 2026.

| Piece | Licence | Verdict for Redlamp |
| --- | --- | --- |
| RapidRAW | AGPL-3.0 | Read for understanding only (DEC-01); never copied, translated or paraphrased |
| RapidRAW AI Connector | Apache-2.0 | Could be adapted with attribution, but isn't needed: Redlamp would talk to ComfyUI directly |
| ComfyUI | GPL-3.0 | A separate program the photographer runs; Redlamp uses its HTTP API and never bundles or links it |
| Inpaint Crop and Stitch nodes | GPL-3.0 | A template may name nodes the photographer installs; Redlamp ships none |
| RealVisXL V5.0 Lightning | OpenRAIL++ | Never in a template Redlamp ships (its use restrictions flow down); photographers may choose it |
| ControlNet Union SDXL | Apache-2.0 | Usable in a template, but it needs an SDXL base, which is OpenRAIL++ |
| RapidRAW's model repository | None stated | Nothing to take |
| LaMa | Apache-2.0 code; Big-LaMa trained on Places2 | Not allowed (DEC-24) |
| nind-denoise | GPL-3.0 | Not allowed |
| spektrafilm's film LUTs | CC BY-SA 4.0 (its code is GPL-3.0) | Not used; Redlamp's film looks are built from datasheets |
| rawler (dnglab) | LGPL-2.1 | For cross-checks only ([CAM-12 note](notes/CAM-12-nikon-high-efficiency.md)) |
| rawler's camera files | LGPL-2.1, with colour matrices derived from Adobe's | Not used; as with rawspeed's camera data ([darktable study §9](darktable-findings.md#9-licensing-of-reusable-pieces)), facts are measured again from CC0 samples |
| Ideogram, through fal | Commercial APIs | Not used ([section 6](#6-what-not-to-follow)) |

---

## 8. Decisions and tracker rows

**Decided by the owner on 7 October 2026:**

1. **A fill's crop may go to a server the photographer runs, on the local network only** (DEC-37): paired Macs running Redlamp, and ComfyUI servers. The README's privacy sentence changes when the first remote fill ships.
2. **Prompted generation waits** (DEC-38): Generative Remove stays removal only for now. Generative Expand wasn't decided, and stays Undecided in the Lightroom comparison.
3. **AI-Free mode's levels,** no AI tools or also "no generated pixels", are decided in INF-10's design.
4. **Not taken up for now:** LUT export (5.4), and a recorded skip of a Redlamp-run cloud and bring-your-own-key model APIs (section 6).

**Tracker rows,** all Proposed:

| ID | Item | Recommended | Phase | Size | Depends on |
| --- | --- | --- | --- | --- | --- |
| RM-15 | Generative Remove on 8 GB Macs: fill time, memory and swap at 512 and 768 pixels, then the manifest's minimum memory where a crop fits | Adopt | P3 | S | RM-10 |
| RM-16 | Fills from another Mac on the local network: `GenerativeFiller` to a Mac running Redlamp, found over Bonjour and paired once; iPad and iPhone in Phase 5 | Do better | P3, P5 | M | DEC-37, RM-10 |
| RM-17 | ComfyUI as a fill server on the local network: its own API, templates with named inputs checked on import, shipped templates for commercially licensed models only | Adopt | P3–P4 | M | DEC-37, RM-10 |
| INF-10 | AI-Free mode | Adopt | P3 | S | — |
| CAM-27 | Apple's RAW 9 on macOS 27: a DN-09 comparator and a labelled fallback decoder for CAM-12 and CAM-13 bodies | Adopt | P3 | S | — |
