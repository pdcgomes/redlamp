# Redlamp and Lightroom compared

A high-level list of the features photographers know from Lightroom, and where Redlamp stands on each: what works today, what's being built, what's planned, and what Redlamp leaves out. It is published at [redlamp.app/compare](https://redlamp.app/compare). It isn't a control-by-control mirror of Lightroom; the [Lightroom feature inventory](lightroom-feature-inventory.md) is the detailed reference, and the [research tracker](research/research-tracker.md) holds the work behind each row.

**Lightroom checked against:** Lightroom Classic 15.6 and the Lightroom Desktop and mobile releases of September 2026, from [The Lightroom Queen's release notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/) (checked 4 October 2026); not yet against Adobe's own pages.
<!-- lightroom-checked: 2026-10-04; through: 2026-09 -->

## How to read it

- **Lightroom:** Yes, Partly or No, with a short qualifier where it matters, such as "(cloud, credits)" for a feature that needs Adobe's cloud and its generative credits.
- **Redlamp:**
  - **Done:** works in the app today.
  - **In progress:** being built.
  - **Planned:** on the roadmap; Phase says which phase.
  - **Later:** after 1.0.
  - **Undecided:** Lightroom has it, and Redlamp hasn't decided whether to build it.
  - **Out of scope:** left out, with the reason.
- **vs Lightroom** (Done rows only). Blank means the feature works but its results haven't been checked against Lightroom's side by side; with "No" in the Lightroom column, it means the feature is only in Redlamp.
  - **Compared:** checked against Lightroom's results; Notes link the evidence.
  - **Behind:** a known gap; Notes say what.
  - **Beyond:** does more than Lightroom's version; Notes say what.
  - **Different:** works differently by design; Notes say how.
- **Tracker:** the tracker rows behind the feature. Each has a GitHub issue, and the website links to it.

`scripts/lightroom-releases.py` lists what Lightroom has added since the check above. `scripts/roadmap-sync.py` keeps the Redlamp and Phase columns in step with the tracker and the README roadmap (`--apply` updates them); write the other columns, and rows for new features, by hand. `.cursor/rules/roadmap-and-comparison.mdc` describes the rules.

## Files and cameras

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Raw files from most cameras | Yes | Done | Behind | | CAM-01, CAM-05, CAM-12, CAM-13 | Through LibRaw 0.22; 25 cameras are verified by the decode tests, Hasselblad and Phase One medium format among them ([every camera](https://redlamp.app/cameras)). Nikon's High Efficiency NEFs and the Sony A7 V don't open yet, and raws other than DNG use one colour matrix per camera, where DNGs blend two by white balance |
| Fujifilm X-Trans raw files | Yes | Done | Behind | | CAM-07 | A first-generation demosaic; a Markesteijn-class one is planned. Fujifilm exposure differs from the camera's by up to ±0.9 EV, depending on the body |
| Apple ProRAW and other phone DNGs | Yes | Done | | | CAM-03, CAM-04, TON-09 | Gain maps and embedded camera profiles are applied, and ProRAW can render with the iPhone's own look |
| JPEG XL DNGs | Yes | In progress | | P2 | CAM-10 | Linear ones (iPhone ProRAW) open; JPEG XL mosaic DNGs don't yet |
| Testing your own camera | No | In progress | | P2 | CAM-14, CAM-15, CAM-16, CAM-17 | The camera bench checks your raws against the camera's own JPEG on your Mac, and sends only the measurements, which add to the cameras page |
| JPEG, HEIC, TIFF and PNG | Yes | Done | | | TON-23 | Shown as the file at default settings, as Lightroom does |
| PSD, AVIF and JPEG XL files | Yes | Planned | | P2 | | |
| WebP files | Yes (Classic) | Undecided | | | | |
| Per-camera raw defaults | Yes | Planned | | P2 | EDT-06 | By camera, lens, ISO and file type |
| Tethered capture | Yes (Classic) | Later | | | | |
| Video | Yes (basic trims) | Out of scope | | | | Redlamp develops still photos |

## Light and colour

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| White balance: presets, Temp and Tint, eyedropper and Auto | Yes | Done | | | | A camera white-balance model built on each camera's colour matrix |
| Exposure, Contrast, Highlights, Shadows, Whites and Blacks | Yes | Done | | | TON-02, TON-05 | Highlights and Shadows keep the texture inside each region for new edits |
| Auto settings | Yes | Done | | | | A heuristic Auto, as a starting point |
| Texture, Clarity and Dehaze | Yes | Done | | | TON-06, TON-27 | Clarity and Dehaze follow the photo's edges for new edits, so a skyline gets no bright and dark bands |
| Vibrance and Saturation | Yes | Done | | | TON-07 | Boosts stop at the edge of the output's colours instead of clipping |
| Tone curve: parametric and point curves | Yes | Done | | | | With split points and the point curve's presets |
| Tone curve: separate red, green and blue curves | Yes | Planned | | P2 | | |
| Targeted Adjustment Tool | Yes | Planned | | P2 | | Drag on the photo to move a curve or a colour band |
| Color Mixer: hue, saturation and luminance per colour | Yes | Done | | | | Works in OKLCh |
| Black and white | Yes | Done | | | | |
| B&W mix: brightness per colour band | Yes | Planned | | P2 | | Today the Color Mixer's Luminance shapes a black-and-white photo |
| Point Color | Yes | Planned | | P2 | TON-29 | Lightroom's now has a Variance slider too, which evens out similar colours; Redlamp's adds Capture One's separate hue, saturation and lightness uniformity, for skin |
| Color Grading | Yes | Done | | | | Shadows, midtones, highlights and global wheels, with Blending and Balance |
| Profiles | Yes | Done | Different | | EDT-04 | Profiles are Base Looks inside Recipes: six built-in looks and the film looks, each with an Amount slider (0–200) |
| Camera-matching looks | Yes | Done | Different | | TON-14 | Four looks measured from Fujifilm cameras' own JPEGs (one provisional), under Redlamp's own names |
| More camera-matching looks (Eterna, Classic Negative, Acros and others) | Yes | In progress | | P3 | TON-14, TON-20 | Need more photos with the camera's JPEG beside the raw |
| DNG camera profiles | Yes | Done | | | CAM-04, TON-09 | Dual-illuminant colour and the embedded HueSatMap; a profile's look is offered as a Base Look |
| Custom `.dcp` camera profiles | Yes | Later | | | | Deferred on 2 October 2026 |
| ICC input profiles | No | Planned | | P2 | TON-10 | |
| Calibration panel | Yes | Done | | | | Shadows Tint and the red, green and blue primaries |
| Process versions | Yes | Done | | | P1-01 | An edit keeps rendering the way it was made; moving it to a newer process is your choice |
| HDR editing and export | Yes | Planned | | P4 | | |
| Adaptive (AI) profile and personalised auto settings | Yes | Later | | | AUT-03, AUT-04 | |

## Detail

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Sharpening | Yes | Done | | | SHP-01 | Lightroom's four controls; the photo's noise and grain aren't sharpened |
| Noise reduction | Yes | Done | | | DN-01, DN-02 | Lightroom's six controls, scaled to each photo's measured noise; calibrated profiles for the first ten bodies wait on calibration shots |
| AI Denoise | Yes | Planned | | P3 | DN-06, DN-07, DN-08 | On the Mac, working on the raw data, without writing a new file |
| Super Resolution | Yes | Planned | | P4 | SR-01, SR-02 | 2x and 4x, faithful to the photo rather than inventing detail |
| Raw Details | Yes | Later | | | | |

## Lens and geometry

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Lens corrections the raw file carries | Yes | Done | | | LNS-01, LNS-02 | DNG opcodes, Sony's and Fujifilm's built-in corrections |
| Lens corrections from Panasonic and OM System raws | Yes | In progress | | P3 | LNS-02 | |
| Adobe LCP lens profiles | Yes | Done | Different | | LNS-04, LNS-11 | Profiles you put in Redlamp's Lens Profiles folder; Redlamp doesn't ship Adobe's |
| A built-in lens profile database | Yes | Planned | | P2 | LNS-03 | The lensfun database, once a licence question is answered |
| Manual distortion and vignetting | Yes | Done | | | | |
| Remove Chromatic Aberration and Defringe | Yes | Done | | | LNS-09 | From the lens profile, or measured from the photo's own edges |
| Upright: Auto, Level, Vertical, Full and Guided | Yes | Done | | | LNS-07, LNS-08 | Corrects only where the photo's straight edges agree |
| Transform sliders | Yes | Done | | | LNS-05 | |
| Crop and straighten | Yes | Done | | | LNS-06 | Aspect presets, Lightroom's overlays, the Straighten tool and Constrain to Image |
| Lens Blur | Yes | Later | | | OTH-03 | |

## Effects

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Post-crop vignette | Yes | Done | | | | With Highlights, to keep bright areas bright |
| Grain | Yes | Done | | | TON-19 | Sized to the frame and strongest in the shadows, as film's is |
| Halation and bloom | No | Done | | | TON-17, TON-18 | The glow film gives bright lights |
| Light leaks, dust and scratches, and frames | No | Done | | | TON-25 | |

## Masking

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Linear and radial gradients | Yes | Done | | | | |
| Brush, with Auto Mask and pen pressure | Yes | Done | | | MSK-16 | |
| Color and luminance range | Yes | Done | | | MSK-05 | |
| Subject, Sky and Background | Yes | Done | | | MSK-08, MSK-17 | Computed on the Mac; photos are never uploaded. Sky also uses Depth Anything 3, an open model trained partly on data Redlamp couldn't use itself. Edges are solved when a mask is made, not refined again as you edit |
| People and their parts | Yes | Done | | | MSK-08, MSK-13 | Face parts from Apple Vision; body skin, clothes and hair from SAM 3, a download under Meta's SAM License |
| Objects | Yes | Done | | | MSK-10 | Hover to preview, click to select (Segment Anything 2.1, an 80 MB download, an open model trained partly on data Redlamp couldn't use itself) |
| Landscape | Yes | Done | Behind | | MSK-17 | Water, vegetation, mountains, architecture and ground, from SAM 3 (a 988 MB download under Meta's SAM License); Lightroom's also finds snow |
| Depth Range | Yes | Done | | | MSK-14 | From the photo's own depth map, or estimated by Depth Anything, an open model trained partly on data Redlamp couldn't use itself |
| Refine AI mask edges | Yes | Done | Different | | MSK-07 | Refine Edges, and a Refine Edge brush that solves an edge again where you paint; Lightroom has Feather and Edge sliders |
| Mask presets (Blue Sky, Whiten Teeth and others) | Yes | Done | | | | Save your own from any mask |
| Add, Subtract, Intersect, invert and duplicate | Yes | Done | | | | |
| Local adjustments in masks | Yes | Done | Behind | | MSK-03 | Local Whites and Blacks are approximated with tonal-region gains |
| Curves inside masks | Yes | Planned | | P3 | | |
| Point Color inside masks | Yes | Planned | | P2 | TON-29 | With an Even Skin Tone preset on Face Skin and Body Skin |
| Update AI masks across photos | Yes | Done | | | EDT-17 | Pasted and synced settings recompute their AI masks for each photo |
| Reuse a mask inside another, and keep only its textured areas | Partly | Done | Beyond | | MSK-04, MSK-06 | Lightroom can start a new mask from an existing one; Redlamp also adds, subtracts or intersects one inside another, and a mask's Detail keeps only its textured or flat areas |

## Healing and removal

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Heal and Clone | Yes | Done | | | RM-01 | Spots and brushed strokes, each finding its own source |
| Content-aware Remove | Yes | Done | | | RM-07 | A classical fill on the Mac; large areas wait for generative fill |
| Remove people and objects with a click | Yes | Done | | | RM-08 | |
| Find and remove things named in words | No | Done | | | RM-08 | Trash, signs, cables and more, found anywhere in the photo; something as large as a car leaves a smeared patch until generative fill arrives |
| Generative Remove | Yes (cloud, credits) | In progress | | P3 | RM-10 | An opt-in download that runs on the Mac, labelled as generated fill |
| Dust removal and Visualize Spots | Yes | Done | | | RM-02 | Also across a shoot: specks in the same place on the sensor are healed in every photo |
| Reflection removal | Yes | Later | | | | |
| Red Eye and Pet Eye | Yes | Planned | | P3 | OTH-01 | |

## Generative and cloud AI

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Generative Expand: fill beyond the frame | Yes (Desktop and mobile, not Classic) | Undecided | | | | |
| Generative Upscale (Topaz) | Yes (Desktop; cloud, credits) | Undecided | | | DEC-14 | Redlamp's planned Super Resolution is faithful rather than generative |
| AI sharpening for blur and missed focus (Topaz) | Yes (Desktop; cloud, credits) | Undecided | | | SHP-03 | Proposed for Redlamp as a head on its own raw denoiser, on the Mac |
| Edit by describing the result (Prompt to Edit, Firefly) | Yes (Desktop early access; cloud, credits) | Undecided | | | | |

## Presets and looks

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Presets | Yes | Done | Different | | EDT-07 | Presets, profiles and LUTs are all Recipes, with an Amount slider; Lightroom's words still work in search |
| Lightroom presets (`.xmp`) | Yes | Done | | | EDT-11 | Imported with a report of what came across exactly, approximately or not at all. Sliders aren't yet calibrated against Lightroom's renders, so a preset can look different |
| LUTs (`.cube`, `.3dl`, HaldCLUT) | Partly | Done | Beyond | | TON-11, TON-28 | Imported directly, including LUTs made for camera log footage; Lightroom takes LUTs only wrapped as profiles |
| Film stock simulations (Portra, Tri-X and others) | Partly (film-inspired presets) | Done | Beyond | | TON-22, TON-26 | 36 looks from 30 stocks, built from the manufacturers' datasheets; Lightroom's film-inspired presets don't replicate particular films |
| Film looks fitted from film shot beside digital | No | Planned | | P3 | TON-21 | With charts and lab scans, per stock |
| Camera recipe cards | No | Done | | | | Fujifilm-style recipes, typed in as the card lists them |
| Premium and recommended presets | Yes (cloud) | Out of scope | | | | Redlamp has no cloud service |

## Working on many photos

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Folders | Yes (Classic) | Done | Different | | UX-08 | A working set of folders, not a catalog; nothing on disk is moved |
| Copy and paste settings | Yes | Done | | | EDT-08, EDT-19 | Lightroom's checklist, remembered; also from a filmstrip photo's context menu |
| Sync and Auto Sync | Yes | Done | | | EDT-17, EDT-18, EDT-20 | Undo with Auto Sync on gives each photo its own edit back, as in Lightroom |
| Ratings, flags and colour labels | Yes | Done | | | | Saved with the photo's edit, shown on the filmstrip |
| Batch export | Yes | Planned | | P4 | EDT-16 | |
| Batch rename | Yes | Undecided | | | | |
| Open photos edited in Lightroom | Yes | Planned | | P4 | EDT-12 | Converts Lightroom's XMP sidecars once, and never writes them |

## History and versions

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| History and unlimited undo | Yes | Done | | | | The last 20 editing sessions are kept with the photo |
| Snapshots | Yes | Done | | | | |
| Virtual copies and versions | Yes | Planned | | P2 | EDT-09 | |
| Before and after | Yes | Done | | | | Three layouts |
| Reference view | Yes | Planned | | P4 | | |

## Viewing

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Zoom, Navigator and clipping | Yes | Done | Behind | | | Fit, Fill, 1:1 and 2:1; Lightroom zooms to 11:1 |
| Histogram you can drag to adjust | Yes | Done | | | | |
| Lightroom Classic's keyboard shortcuts | Yes | Done | | | | 83 actions on 87 key bindings |
| Command palette | No | Done | | | UX-07 | Every action and slider from the keyboard (⌘K) |
| Sensor clipping and a colour-assessment view | No | Done | | | UX-05 | |
| Soft proofing | Yes (Classic) | Planned | | P4 | | |
| Secondary display | Yes | Planned | | P4 | | |

## Merging photos

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Focus stacking | No | Done | | | FS-01, FS-02, FS-04 | Stacks are found for you; merge, view the depth map and retouch, and the result develops like a raw |
| Focus stacking: lens corrections, halo handling and DNG output | No | In progress | | P3 | FS-02, FS-03 | |
| AI-assisted focus stacking | No | Planned | | P4 | FS-14 | Fewer frames, handheld sequences, better edges |
| HDR merge | Yes | Later | | | OTH-04 | |
| Panorama | Yes | Later | | | OTH-04 | |

## Export

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| JPEG, HEIC, AVIF, PNG and TIFF | Yes | Done | | | EDT-13, EDT-15 | 8, 10 or 16 bits, in sRGB or Display P3 |
| Size, metadata and export presets | Yes | Done | | | EDT-15 | With Export with Previous |
| Adobe RGB, ProPhoto and custom ICC output | Yes | Planned | | P4 | | |
| DNG, PSD and JPEG XL output | Yes | Planned | | P4 | | |
| Watermarks | Yes | Planned | | P4 | | |
| Output sharpening | Yes | Planned | | P4 | | |
| Edit in Photoshop or another app | Yes | Planned | | P4 | | |
| Content Credentials | Yes | Planned | | P3 | RM-03 | |
| The edit embedded in exported files | Yes | Done | | | EDT-14 | |
| Command-line rendering and export | No | Done | | | | The `redlamp` tool |

## Library and organising

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Catalog, collections and smart collections | Yes | Later | | | | Redlamp is an editor; a library is a separate, later track |
| Keywords and metadata editing | Yes | Later | | | | |
| People (face recognition) and Map | Yes | Later | | | | |
| AI search | Yes | Later | | | | |
| Culling in a grid, and AI-assisted culling | Yes | Later | | | OTH-02 | Lightroom's Assisted Culling judges sharpness, faces and eyes; rating, flagging and labelling work in Redlamp's filmstrip today |
| Stacking similar photos, and finding duplicates | Yes | Later | | | | |

## Print, book, slideshow and web

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Print | Yes (Classic) | Out of scope | | | | Redlamp develops photos; it doesn't lay out prints |
| Book, Slideshow and Web | Yes (Classic) | Out of scope | | | | |
| Publish services, and sharing to Adobe's web and Firefly | Yes (cloud) | Out of scope | | | | Redlamp has no cloud service |

## Platforms and sync

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Mac | Yes | Done | Different | | | macOS 26 on Apple Silicon, free and open source, with no subscription. Not sandboxed yet; photos decode in a sandboxed service |
| Windows | Yes | Out of scope | | | | Redlamp is built for Apple's platforms |
| iPad and iPhone | Yes | Planned | | P5 | | The same engine, after 1.0 |
| Edits shared between Macs | Yes (cloud) | Done | Behind | | | Through iCloud Drive: sidecars sync safely and conflicting copies merge. A photo that's open doesn't reload yet when another Mac changes its edit |
| Edits moving between your Mac, iPad and iPhone | Yes (cloud) | Planned | | P5 | | Through iCloud Drive and Files, rather than Adobe's cloud |
| Cloud sync with smart previews | Yes (cloud) | Later | | | | |
| Photos library and a Photos editing extension | Partly (mobile) | Planned | | P2 | | |
