# Redlamp

**A native, open-source RAW photo editor for Mac, iPad, and iPhone that anyone who knows Lightroom will find familiar.**

Redlamp is built from scratch in Swift and Metal for Apple Silicon. It focuses on one thing, *developing* photos, and aims to do it faster and more natively than anything else on the platform.

![Redlamp editing a Nikon Z 6 raw file](docs/images/editor.png)

> **Status: pre-alpha, iteration 1 (macOS).** The core RAW pipeline, the Develop workspace, and the Basic, Tone Curve, Color Mixer, Color Grading, and Effects adjustments work today. Masking, crop, healing, lens corrections, and the iPad and iPhone apps are next. See [Where we are](#where-we-are) and the [Roadmap](#roadmap).
>
> This README is the project's primary status page and is kept up to date as work lands. *Last updated: 29 September 2026.*

---

## Contents

- [Why Redlamp](#why-redlamp)
- [Goals](#goals)
- [Where we are](#where-we-are)
- [Screenshots](#screenshots)
- [Roadmap](#roadmap)
- [Getting started](#getting-started)
- [Using Redlamp](#using-redlamp)
- [Architecture](#architecture)
- [Contributing](#contributing)
- [License and acknowledgements](#license-and-acknowledgements)

---

## Why Redlamp

A **red lamp** is the darkroom safelight: the one light you can work by without fogging the paper. That is the idea behind the project: you can see and shape your photo freely, and the original is never harmed.

Lightroom defined how millions of photographers edit, but it is a cross-platform application that doesn't feel at home on a Mac, iPad, or iPhone, and it is tied to a subscription and a cloud. Redlamp keeps the workflow photographers already know, including the panel layout, slider names and ranges, and keyboard shortcuts, and rebuilds everything underneath as a native, GPU-first, open-source application.

**Redlamp is an editor, not a catalog.** It opens folders of photos and stores edits in small sidecar files next to them. Library management is a separate, later track.

## Goals

1. **Immediately familiar to Lightroom users.** The Develop module's layout, panel order, slider names, ranges and defaults, and single-key shortcuts all carry over. We copy conventions, never Adobe's assets.
2. **Best-in-class masks.** Masks are part of the architecture from day one. Every edit is a layer (adjustments plus a mask), with Lightroom's model of components combined by add, subtract, and intersect, and on-device AI masks built on Apple Vision and SAM-class models.
3. **Modern, native UI and great UX.** The UI follows the macOS and iOS 26 design language. Liquid Glass is used only on floating chrome, and editing surfaces stay neutral grey so nothing distorts your color judgment. It is direct-manipulation first, every action can be undone, and there are no modal dialogs while you edit.
4. **Extreme responsiveness.** Rendering and UI are strictly separated. Slider changes should reach the screen within a frame (under 16 ms), and the UI thread never waits on the engine, the disk, or the GPU.
5. **Serious color science.** The pipeline is scene-referred and linear, with DCP camera profiles, LUTs, lens profiles, and our own looks. Some looks are fitted by measurement to match popular camera and editor renderings.
6. **Mac, iPad, and iPhone from one engine.** A single platform-neutral engine sits under thin, native shells for each platform. Edits move between devices through iCloud Drive, Files, and Photos.
7. **Open source (MPL-2.0).** The license is compatible with the App Store. Algorithms are implemented clean-room from papers and specifications.

## Where we are

### What works today (macOS)

**RAW pipeline (our own, GPU-first)**
- [x] Decodes RAW files through LibRaw (unpacking only). Black levels, white balance, demosaicing, and color are all done by Redlamp on the GPU.
- [x] Bayer demosaic (Malvar–He–Cutler), a first-generation X-Trans demosaic, and linear DNG support (for example iPhone ProRAW).
- [x] Tested on Sony **ARW**, Canon **CR3**, Nikon **NEF**, Fujifilm **RAF** (X-Trans), and Apple **ProRAW DNG**, plus JPEG, HEIC, TIFF, and PNG.
- [x] The demosaiced image is cached as a full mip pyramid, so interactive renders sample the right resolution for the zoom level.
- [x] A single fused Metal kernel applies every per-pixel adjustment. Frames are delivered as IOSurfaces, so pixels are never copied between engine and UI.
- [x] Latest-wins render scheduling: a burst of slider events collapses to the newest one.
- [x] Temperature and tint use a proper camera white-balance model (Robertson's method with the camera's color matrix). As Shot, Auto, and the illuminant presets all work.

**Develop adjustments that render**
- [x] **White balance:** Temp and Tint, the presets, Auto, and the eyedropper.
- [x] **Basic:** Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Vibrance, and Saturation, plus the **Auto** button.
- [x] **Treatment** (Color or B&W) and six built-in **profiles**: Redlamp Color, Neutral, Vivid, Landscape, Portrait, and Monochrome.
- [x] **Tone Curve:** a parametric curve with split points, and a point curve with presets.
- [x] **Color Mixer:** HSL (Hue, Saturation, Luminance, and All) and a per-color mode, working in OKLCh.
- [x] **Color Grading:** 3-way and individual wheels, Blending, and Balance. It also tints B&W images for split-toning.
- [x] **Effects:** post-crop vignette (amount, midpoint, roundness, feather) and zoom-stable film grain.

**Workspace**
- [x] A Lightroom-style layout. On the left: Navigator, Presets, Snapshots, and History. In the center: the photo, with the filmstrip below. On the right: histogram, tool strip, and the Develop panels in Lightroom's order.
- [x] **Sliders:** click to jump, drag to adjust, Shift-drag for fine control, double-click to reset, and click the value to type one in. Option-dragging a tone slider shows clipping, as in Lightroom.
- [x] **Panels:** double-click a panel or group title to reset it, and Option-click a header for Solo Mode.
- [x] **Histogram:** clipping indicators, and you can drag across it to adjust Blacks, Shadows, Exposure, Highlights, or Whites.
- [x] **Presets:** hover to preview, click to apply. Snapshots and full undo/redo history are also available.
- [x] **Viewing:** Fit, Fill, 1:1, and 2:1 zoom, click to zoom, pan, pinch, before/after, and a clipping overlay.
- [x] Lightroom's keyboard shortcuts (see [Keyboard shortcuts](#keyboard-shortcuts)).
- [x] Non-destructive edits, saved automatically to a sidecar file next to each photo (`IMG_1234.ARW.redlamp`).
- [x] Export to JPEG, plus a headless `redlamp` command-line tool for rendering and export.

**Panels laid out but not yet rendering** (shown dimmed, with the phase they arrive in): Texture, Clarity, and Dehaze, and the Detail, Lens Corrections, Transform, and Calibration panels. The Crop, Healing, Red Eye, and Masking tools show what is coming and when.

### Measured performance

Measured on an Apple M1 Ultra with a Release build.

| Operation | Time |
| --- | --- |
| Open a 24–26 MP raw file (decode, GPU upload, demosaic, pyramid) | 70–250 ms |
| Interactive render at Fit (every adjustment, fused) | 0.6–3 ms |
| Interactive render at 1:1 (full 26 MP frame) | ~13 ms |
| Full-resolution export render (24–26 MP) | ~45 ms |

### Known limitations

- Highlights and Shadows are per-pixel approximations for now. Lightroom-quality versions need edge-aware local tone mapping, which arrives with Clarity and Texture in Phase 2.
- X-Trans demosaicing is a first-generation interpolation. A Markesteijn-class demosaic (and AMaZE and RCD for Bayer sensors) comes in Phase 2.
- White balance for linear DNGs (for example ProRAW) is not wired up yet; those files render with their embedded balance.
- Color uses LibRaw's single-illuminant Adobe-derived matrix. Dual-illuminant DCP profiles come in Phase 2.
- The Navigator does not yet outline the zoomed viewport.
- The app is not sandboxed yet (required later for the Mac App Store), and there is no iPad or iPhone app yet.

## Screenshots

**Color grading on a Canon EOS R6 CR3.** Split-toned shadows and highlights with the 3-way wheels.

![Color grading](docs/images/color-grading.png)

**Black & white on a Sony A7 III ARW.** The Selenium preset plus vignette and grain, with every step in History.

![Black and white](docs/images/black-and-white.png)

**Fujifilm X-T3 X-Trans RAF at 1:1.** The full-resolution frame renders in about 13 ms, and the Color Mixer is shown in HSL mode.

![X-Trans at 100%](docs/images/zoom-xtrans.png)

**iPhone 12 Pro ProRAW (linear DNG).** Portrait orientation, with highlight recovery and blues tuned in the Color Mixer.

![ProRAW](docs/images/proraw.png)

<sub>Sample images are CC0 files from [raw.pixls.us](https://raw.pixls.us). The screenshots are generated by `mise run screenshots`.</sub>

## Roadmap

Every phase ships on Mac, iPad, and iPhone. The Lightroom feature inventory in [`docs/lightroom-feature-inventory.md`](docs/lightroom-feature-inventory.md) tags every Lightroom feature with the phase that delivers it.

### Phase 0: Foundations *(largely done)*
- [x] mise and Tuist workspace, module graph with enforced boundaries, and an engine purity gate
- [x] LibRaw vendored as a pinned, static XCFramework (macOS, iOS, and Simulator; arm64 only)
- [x] Engine API contract, headless CLI, and a unit and engine smoke-test suite
- [x] Lightroom feature inventory
- [ ] Performance lab: CI runner plus tethered iPhone and iPad, with per-tier regression gates that block merges
- [ ] Golden-image color regression tests (ΔE2000)
- [ ] Written clean-room policy and a license-audit gate in CI

### Phase 1: First light *(in progress; macOS iteration 1 done)*
- [x] RAW pipeline core, fused develop kernel, cached pyramid, and latest-wins rendering
- [x] Develop workspace on macOS, Basic panel, histogram, before/after, sidecars, undo, and export
- [ ] Layer and mask engine, with linear and radial gradient masks
- [ ] Sandboxed XPC decode helper on macOS and in-process decoding on iOS
- [ ] Render scheduler with priority lanes, tile cancellation, and thermal awareness
- [ ] iPad and iPhone shells (compact layout, touch, Apple Pencil)
- [ ] Coordinated sidecar I/O for iCloud Drive and Files

### Phase 2: Develop parity
- [ ] Texture, Clarity, and Dehaze, plus edge-aware Highlights and Shadows
- [ ] Detail panel: sharpening and noise reduction
- [ ] Better demosaicing (RCD and AMaZE for Bayer, Markesteijn for X-Trans) and highlight reconstruction
- [ ] Full DCP camera profiles (dual and triple illuminant), ICC input profiles, **LUT import** (`.cube`, `.3dl`, HaldCLUT), and a Profile Browser
- [ ] Lens corrections from the lensfun database, Adobe LCP import, and DNG opcodes
- [ ] Crop and straighten, Transform and Upright
- [ ] Brush, color range, and luminance range masks, and Vision AI masks (subject, sky, background, people)
- [ ] Slider-feel calibration against Lightroom, and Lightroom XMP preset import
- [ ] Photos library integration and a Photos editing extension

### Phase 3: Pro masking, healing, and looks
- [ ] SAM-class object and people-part masks, mask refinement, mask presets, and syncing masks across photos
- [ ] Healing, clone, and content-aware remove
- [ ] Manufacturer lens corrections embedded in RAW files (Sony, Fujifilm, Panasonic, OM System)
- [ ] `redlamp-profiler`: look matching by black-box measurement (Fujifilm film simulation–inspired looks, Adobe-compatible looks), with a DCP and LUT writer

### Phase 4: 1.0
- [ ] Lightroom XMP sidecar import, HDR/EDR editing and export, and batch export
- [ ] Accessibility, usability testing on every platform, and App Store releases

### Later
- CloudKit sync with lightweight proxy RAW files
- A library and catalog, tethered shooting, and panorama and HDR merge
- AI denoise and super-resolution, on-device

## Getting started

### Requirements

- An Apple Silicon Mac running **macOS 26** or later
- **Xcode 26** or later
- [**mise**](https://mise.jdx.dev), which installs the pinned Tuist, SwiftFormat, and SwiftLint versions

### Build and run

```bash
git clone https://github.com/pdcgomes/redlamp.git && cd redlamp
mise install              # Tuist, SwiftFormat, SwiftLint at pinned versions
mise run generate         # builds vendored LibRaw, then generates Redlamp.xcworkspace
mise run fixtures         # optional: downloads CC0 sample raw files into tests/fixtures/raw
mise run run -- tests/fixtures/raw    # build and launch, opening a folder
```

You can also run `mise run run` on its own and choose **File → Open Folder…** (⌘O), or drop a folder or files onto the window. Redlamp reopens the last folder on launch.

### Command-line tool

The `redlamp` CLI uses the same engine API as the app. It is useful for scripting, quick checks, and reproducing renders.

```bash
mise run render -- info ~/Pictures/DSC01234.ARW
mise run render -- render ~/Pictures/DSC01234.ARW -o out.jpg --size 2048 \
  --set exposure=0.5 --set shadows=30 --wb auto --profile vivid
```

### Development tasks

| Task | What it does |
| --- | --- |
| `mise run generate` (`g`) | Vendor LibRaw and generate the Xcode workspace |
| `mise run build` (`b`) | Build the macOS app |
| `mise run run` (`r`) | Build and launch; pass a folder after `--` |
| `mise run test` (`t`) | Engine purity gate plus all unit and engine tests |
| `mise run lint` (`l`) | Purity gate, SwiftFormat (lint mode), and SwiftLint |
| `mise run vendor` (`v`) | Build the vendored C/C++ libraries (pinned version and SHA in `config/vendored-libs.json`) |
| `mise run fixtures` | Download CC0 sample raw files |
| `mise run render` | Build and run the `redlamp` CLI |
| `mise run screenshots` | Regenerate the README screenshots (needs Screen Recording permission) |

## Using Redlamp

### Supported files

- **Raw:** through LibRaw 0.22, covering most cameras from Sony (A1, A7 II–IV, A7C, A7R II–V, A7S, A9, a6x00, ZV, RX), Canon, Nikon, Fujifilm (including X-Trans), Panasonic, OM System and Olympus, Pentax, Leica, Hasselblad, and DNG, including Apple ProRAW. Uncompressed, compressed, and lossless compressed formats are all supported. Bodies released after LibRaw 0.22 need a LibRaw update.
- **Bitmap:** JPEG, HEIC, TIFF, and PNG.

### Keyboard shortcuts

These match Lightroom Classic's Develop module.

| Key | Action |
| --- | --- |
| `\` | Before / After |
| `J` | Show clipping |
| `Z` or click the photo | Toggle Fit / 100% |
| `W` | White Balance Selector (eyedropper) |
| `R`, `Q`, `⇧W` | Crop, Healing, Masking (tools coming in later phases) |
| `D` | Back to Edit |
| `Tab` / `⇧Tab` | Hide side panels / all panels |
| `←` `→` or `⌘←` `⌘→` | Previous / next photo |
| `⌘U` | Auto settings |
| `⇧⌘C` / `⇧⌘V` | Copy / paste settings |
| `⇧⌘R` | Reset all settings |
| `⌘N` | New snapshot |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `⌘O` / `⇧⌘E` | Open folder / export |

**Slider gestures:**
- Double-click a label or thumb to reset it.
- Shift-drag for fine control.
- Option-drag Exposure, Highlights, Shadows, Whites, or Blacks to preview clipping.
- Click a value to type a new one, and use the arrow keys to step it (Shift steps by ten).

### Where edits are stored

Edits are saved as JSON next to the photo, in `IMG_1234.ARW.redlamp`. The file holds the edit recipe and any snapshots. Only values that differ from the defaults are stored, and unknown keys are ignored, so sidecars stay small and keep working across versions. Resetting a photo completely deletes its sidecar.

## Architecture

The rendering engine and the UI are completely separate. The UI talks to the engine only through `RedlampEngineAPI`, a small, message-based, value-type API. Rendered frames come back as IOSurfaces, so pixels are never copied across the boundary.

```mermaid
flowchart LR
    subgraph ui [UI - macOS today, iPad and iPhone next]
        Views["SwiftUI panels + design system"] --> Model["EditorModel"]
        Canvas["Metal canvas"]
    end
    subgraph api [RedlampEngineAPI - value types only]
        Req["RenderRequest / EditRecipe"]
        Frame["RenderedFrame: IOSurface + histogram"]
    end
    subgraph engine [Engine - platform-neutral, no UI imports]
        Sched["Latest-wins render loop"] --> Kernels["Fused Metal develop kernel"]
        Pyramid["Demosaiced mip pyramid"] --> Kernels
        Decode["LibRaw / ImageIO decode"] --> Pyramid
    end
    Model --> Req --> Sched
    Kernels --> Frame --> Canvas
```

**The pipeline:**
1. LibRaw unpacks the sensor data.
2. The GPU applies black and white levels and the as-shot white balance.
3. The image is demosaiced and cached as a mip pyramid.
4. The fused develop kernel applies, in order: the white-balance ratio, the camera matrix to linear Rec.2020 (scene-referred), exposure and tone in log space, a filmic tone map, OKLCh color work (vibrance, saturation, mixer, grading, profile look), the tone-curve lookup, vignette, grain, and the output encoding.

**Packages** (`packages/`; `Tuist/ProjectDescriptionHelpers/Module.swift` is the single source of truth for which package may depend on which):

| Package | Role |
| --- | --- |
| `RedlampEngineAPI` | Public contract: `EditRecipe`, parameter schema, render requests and frames, `EditingEngine` |
| `RedlampKernels` | Metal shaders (demosaic, develop, histogram) and their parameter layouts |
| `RedlampColor` | Color spaces, color-temperature math (Robertson), camera color model, OKLab |
| `RedlampServices` | Decoding (LibRaw, ImageIO) and thumbnails |
| `RedlampDocument` | Sidecars, snapshots, presets, library scanning, export writers |
| `RedlampEngine` | Sessions, the GPU pyramid, render loop, analysis (auto WB, auto tone, eyedropper) |
| `RedlampCanvas` | Metal canvas that samples frame IOSurfaces directly; zoom and pan |
| `RedlampUI` | Design system, Develop panels, sidebar, filmstrip, `EditorModel` |

**Apps** (`apps/`): `RedlampMac`, the macOS app and composition root, and `RedlampCLI`, the headless `redlamp` tool.

**Engineering principles:**
- **Swift for everything on the CPU side, Metal for every pixel.** C and C++ appear only in vendored libraries.
- **Swift 6 language mode**, with warnings treated as errors, on arm64 only.
- **CI-enforced boundaries.** `scripts/check-engine-purity.sh` fails the build if an engine package imports a UI framework, or if a UI package imports engine internals.
- **The parameter schema is shared.** Slider names, ranges, defaults, and whether a parameter renders yet are defined once, in `RedlampEngineAPI`, and both the engine and the UI read them.

## Contributing

Redlamp is at an early stage and moving quickly. Issues and discussion are very welcome.

- **Clean-room policy.** No GPL or LGPL code. Algorithms are implemented from published papers and specifications. Please don't port code from darktable, RawTherapee, or other GPL projects, and if you have studied a GPL implementation of something, please don't write Redlamp's version of it.
- **Third-party components:** LibRaw is used under its CDDL-1.0 option. Planned additions are lcms2 (MIT) and the lensfun database (CC-BY-SA, data only).
- **Conventions:**
  - Run `mise run lint` and `mise run test` before sending changes.
  - Keep engine code free of UI imports.
  - New parameters go into the schema in `RedlampEngineAPI/Sources/ParameterSpec.swift`.
- **Fixtures:** `mise run fixtures` downloads CC0 samples. Please don't commit RAW files.

## License and acknowledgements

Redlamp is licensed under the **Mozilla Public License 2.0**; see [LICENSE](LICENSE).

Redlamp builds on the work of others:
- [LibRaw](https://www.libraw.org) for RAW unpacking (CDDL-1.0)
- [raw.pixls.us](https://raw.pixls.us) for CC0 sample files
- Björn Ottosson's [OKLab](https://bottosson.github.io/posts/oklab/) color space
- Robertson's method for correlated color temperature
- The Malvar–He–Cutler demosaicing paper
- Krzysztof Narkowicz's filmic curve fit

Redlamp is not affiliated with Adobe. Lightroom is a trademark of Adobe Inc. and is referenced only to describe familiar workflows.
