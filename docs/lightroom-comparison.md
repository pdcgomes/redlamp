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
| Raw files from most cameras | Yes | Done | Behind | | CAM-01, CAM-05, CAM-12, CAM-13, CAM-30 | Through LibRaw 0.22, built from Redlamp's fork; 31 cameras are verified by the decode tests, Hasselblad and Phase One medium format among them ([every camera](https://redlamp.app/cameras)). Nikon's High Efficiency NEFs open from the six bodies that write them, and raws other than DNG use one colour matrix per camera, where DNGs blend two by white balance |
| Fujifilm X-Trans raw files | Yes | Done | Behind | | CAM-07 | Markesteijn's demosaic, which resolves a sharp edge as finely as Redlamp's Bayer demosaic ([DN-11](research/notes/DN-11-lightroom-raw-denoise.md)). Fujifilm exposure differs from the camera's by up to ±0.9 EV, depending on the body |
| Apple ProRAW and other phone DNGs | Yes | Done | | | CAM-03, CAM-04, TON-09 | Gain maps and embedded camera profiles are applied, and ProRAW can render with the iPhone's own look |
| JPEG XL DNGs | Yes | In progress | | P2 | CAM-10 | Linear ones (iPhone ProRAW) open; JPEG XL mosaic DNGs don't yet |
| Testing your own camera | No | Done | | | CAM-14, CAM-15, CAM-16, CAM-17 | The camera bench checks your raws against the camera's own JPEG on your Mac, and sends only the measurements, which add to the cameras page |
| JPEG, HEIC, TIFF and PNG | Yes | Done | | | TON-23 | Shown as the file at default settings, as Lightroom does |
| PSD, AVIF and JPEG XL files | Yes | Planned | | P2 | | |
| WebP files | Yes (Classic) | Undecided | | | | |
| Per-camera raw defaults | Yes | Planned | | P2 | EDT-06 | By camera, lens, ISO and file type |
| Tethered capture | Yes (Classic) | Later | | | TET-01, TET-02, TET-04, TET-06, TET-07, TET-08, TET-09, TET-11, TET-13, TET-14 | Researched in October 2026: capture sessions and a hot folder for any camera first, then camera control and Live View for Canon, Nikon, Sony and Fujifilm, and wireless ([findings](https://github.com/pdcgomes/redlamp/blob/main/docs/research/tethering-findings.md)) |
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
| Targeted Adjustment Tool | Yes | Planned | | P2 | UX-35 | Drag on the photo to move a curve or a colour band |
| Color Mixer: hue, saturation and luminance per colour | Yes | Done | | | | Works in OKLCh |
| Black and white | Yes | Done | | | | |
| B&W mix: brightness per colour band | Yes | Planned | | P2 | | Today the Color Mixer's Luminance shapes a black-and-white photo |
| Point Color | Yes | Done | | | TON-29 | Lightroom's now has a Variance slider too, which evens out similar colours; Redlamp's adds Capture One's separate hue, saturation and lightness uniformity, for skin |
| Color Grading | Yes | Done | | | | Shadows, midtones, highlights and global wheels, with Blending and Balance |
| Profiles | Yes | Done | Different | | EDT-04 | Profiles are Base Looks inside Recipes: six built-in looks and the film looks, each with an Amount slider (0–200) |
| Camera-matching looks | Yes | Done | Different | | TON-14 | Four looks measured from Fujifilm cameras' own JPEGs (one provisional), under Redlamp's own names |
| More camera-matching looks (Eterna, Classic Negative, Acros and others) | Yes | In progress | | P3 | TON-14, TON-20, TON-35 | Need more photos with the camera's JPEG beside the raw |
| DNG camera profiles | Yes | Done | | | CAM-04, TON-09 | Dual-illuminant colour and the embedded HueSatMap; a profile's look is offered as a Base Look |
| Custom `.dcp` camera profiles | Yes | Later | | | | Deferred on 2 October 2026 |
| ICC input profiles | No | Planned | | P2 | TON-10 | |
| A scene-referred rendering for reproduction work, with exposure tied to the camera's metering | No | Done | | | TON-39, CAM-28 | The Base Look Redlamp Reproduction: no tone curve or look, and each camera's exposure calibrated from a target, so a metered grey scale exports at its own L*; Lightroom needs a custom linear profile for this |
| Calibration panel | Yes | Done | | | | Shadows Tint and the red, green and blue primaries |
| Process versions | Yes | Done | | | P1-01 | An edit keeps rendering the way it was made; moving it to a newer process is your choice |
| HDR editing and export | Yes | Planned | | P4 | | |
| Adaptive (AI) profile and personalised auto settings | Yes | Later | | | AUT-03, AUT-04 | |

## Detail

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Sharpening | Yes | Done | | | SHP-01 | Lightroom's four controls; the photo's noise and grain aren't sharpened |
| Noise reduction | Yes | Done | | | DN-01, DN-02 | Lightroom's six controls, scaled to each photo's measured noise; calibrated profiles for the first ten bodies wait on calibration shots |
| AI Denoise | Yes | Planned | | P3 | DN-06, DN-07, DN-08 | On the Mac, working on the raw data, as an edit rather than a new file, as Lightroom has done since June 2025; proposed as one network that demosaics and denoises Bayer and X-Trans ([DN-11](research/notes/DN-11-lightroom-raw-denoise.md)) |
| Super Resolution | Yes | Planned | | P4 | SR-01, SR-02 | 2x and 4x, faithful to the photo rather than inventing detail |
| Raw Details | Yes | Later | | | DEC-36 | Proposed as the noise-free mode of the AI Denoise network; a learned demosaic measured 4.5 dB better than Redlamp's on Bayer photos, mostly in fine colour detail ([DN-11](research/notes/DN-11-lightroom-raw-denoise.md)) |

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
| Custom crop ratios, and rotating by dragging outside the crop | Yes | Planned | | P2 | LNS-12, LNS-13 | Today `X` swaps the crop's orientation and the Angle slider turns the photo |
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
| People and their parts | Yes | Done | | | MSK-08, MSK-13, UX-21 | A picker shows who is in the photo as crops to tick, with the parts to mask and a mask for each person if you like. Face parts from Apple Vision; body skin, clothes and hair from SAM 3, a download under Meta's SAM License |
| Objects | Yes | Done | | | MSK-10 | Hover to preview, click to select (Segment Anything 2.1, an 80 MB download, an open model trained partly on data Redlamp couldn't use itself) |
| Objects by rectangle and brush | Yes | Done | | | MSK-19 | |
| Landscape | Yes | Done | | | MSK-17, MSK-22, UX-26 | A picker lists the regions found, each with its share of the photo, to mask together or one each: water, vegetation, mountains, architecture, ground and snow, from SAM 3 (a 988 MB download under Meta's SAM License) |
| Snow in Landscape masks, and adaptive Landscape presets | Yes | Done | | | MSK-22 | |
| Depth Range | Yes | Done | | | MSK-14 | From the photo's own depth map, or estimated by Depth Anything, an open model trained partly on data Redlamp couldn't use itself |
| Refine AI mask edges | Yes | Done | Different | | MSK-07, MSK-26, MSK-31 | Refine Edges, which solves a mask's whole edge again per pixel, and a Refine Edge brush that solves an edge again where you paint; from process 13, coarse masks (iPhone mattes, face parts) refined at full resolution as the photo is drawn |
| Feather and Edge sliders for AI masks | Yes | Done | | | MSK-18 | Lightroom Classic 15.5 added the sliders |
| Mask presets (Blue Sky, Whiten Teeth and others) | Yes | Done | | | UX-25 | On one photo or every selected photo at once, each one's AI masks made for it; save your own from any mask |
| Add, Subtract, Intersect, invert and duplicate | Yes | Done | | | UX-24 | A component or the whole mask inverted; Duplicate and Invert inverts the copy as a whole |
| A masks panel with a thumbnail of each mask, and its overlay on hover | Yes | Done | | | UX-20, UX-22, UX-23, UX-24 | One picker for every mask and component, a menu on each mask and component, pins where each mask covers most, and Option-click on an eye to show one mask alone |
| Reorder masks and components, every overlay mode and its opacity | Yes | Done | | | MSK-21 | |
| Local adjustments in masks | Yes | Done | | | MSK-03, MSK-24 | Local Whites and Blacks move the end points as the global sliders do, for new edits (process 13) |
| Local Whites and Blacks as true end points | Yes | Done | | | MSK-24 | |
| Color swatch inside masks | Yes | Done | | | MSK-23 | |
| Curves inside masks | Yes | Done | | | MSK-20 | |
| Point Color inside masks | Yes | Done | | | TON-29 | With an Even Skin Tone preset on Face Skin and Body Skin |
| Update AI masks across photos | Yes | Done | | | EDT-17 | Pasted and synced settings recompute their AI masks for each photo |
| Reuse a mask inside another, and keep only its textured areas | Partly | Done | Beyond | | MSK-04, MSK-06 | Lightroom can start a new mask from an existing one; Redlamp also adds, subtracts or intersects one inside another, and a mask's Detail keeps only its textured or flat areas |

## Healing and removal

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Heal and Clone | Yes | Done | | | RM-01 | Spots and brushed strokes, each finding its own source |
| Content-aware Remove | Yes | Done | | | RM-07 | A classical fill on the Mac; large areas are for Generative Remove |
| Remove people and objects with a click | Yes | Done | | | RM-08, RM-13 | Their cast shadows and their reflections on water go with them |
| Pick an object to remove with a rough stroke (Detect Objects) | Yes | Planned | | P3 | RM-19 | Or with a box dragged around it; today a click picks it, and Objects masks already select by rectangle or brush |
| Find and remove things named in words | No | Done | | | RM-08 | Trash, signs, cables and more, found anywhere in the photo; something as large as a car needs Generative Remove, since content-aware fill leaves a smeared patch |
| Generative Remove | Yes (cloud, credits) | Done | Different | | RM-10, RM-15 | Runs on the Mac, without a cloud or credits, from an opt-in 2.4 GB download; tested on Macs with 16 GB or more, and offered on smaller ones with a note that it hasn't been tested there; fills are labelled as generated |
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
| Generative and AI tools run in the cloud | Yes (cloud, credits) | Later | | | INF-11, INF-13, RM-17 | An option for later, beside the models that run on the Mac: a provider you bring your own key for, a third-party provider, or a ComfyUI server (DEC-39) |

## Presets and looks

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Presets | Yes | Done | Different | | EDT-07 | Presets, profiles and LUTs are all Recipes, with an Amount slider; Lightroom's words still work in search |
| Lightroom presets (`.xmp`) | Yes | Done | | | EDT-11, EDT-24 | Imported with a report of what came across exactly, approximately or not at all. Sliders aren't yet calibrated against Lightroom's renders, so a preset can look different |
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
| Ratings, flags and colour labels | Yes | Done | | | | Saved with the photo's edit, shown in the grid, the loupe and the filmstrip |
| Batch export | Yes | Planned | | P4 | EDT-16 | |
| Batch rename | Yes | In progress | | P4 | LIB-25, LIB-26 | Rename Photos (F2): naming templates shared with importing, batch export and capture sessions, a live preview of every new name, and Undo; Move to Folder from the menus, dragging later |
| Open photos edited in Lightroom | Yes | Planned | | P4 | EDT-12 | Converts Lightroom's XMP sidecars once, and never writes them |
| Bring a Lightroom Classic catalog across | Yes (Lightroom's migration from Classic) | Undecided | | | EDT-23 | Each photo's develop settings, rating, flag and label, read without changing the catalog |
| Match Total Exposures | Yes (Classic) | Undecided | | | EDT-21 | |

## History and versions

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| History and unlimited undo | Yes | Done | | | | The last 20 editing sessions are kept with the photo |
| Snapshots | Yes | Done | | | | |
| Virtual copies and versions | Yes | Planned | | P2 | EDT-09 | |
| Before and after | Yes | Done | | | | Three layouts |
| Before and after: your choice of layout, Copy and Swap | Yes | Undecided | | | UX-31 | Left/right or top/bottom by choice, Copy Before's or After's settings, and Swap; Redlamp orients side by side from the photo's shape |
| Reference view | Yes | Planned | | P4 | UX-34 | |

## Viewing

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Zoom, Navigator and clipping | Yes | Done | Behind | | | Fit, Fill, 1:1 and 2:1; Lightroom zooms to 11:1 |
| Zoom, pan and brush sizes in every tool | Yes | Done | | | UX-15 | The wheel zooms and Space pans while masking, healing and cropping, and every brush sizes with [ and ] or ⌘-scroll |
| Panels that hide automatically or stay up | Yes | Done | Different | | UX-19 | The filmstrip hides automatically or stays up with the photo fitted above it (View › Filmstrip, its right-click menu, Settings); Lightroom offers Auto Hide & Show, Auto Hide and Manual for each panel |
| Histogram you can drag to adjust | Yes | Done | | | | |
| RGB and L*a*b* values of the pixel under the pointer | Yes | Done | Different | | UX-32 | Under the histogram; RGB in Display P3, where Lightroom uses Melissa RGB, and L*a*b* relative to D50 |
| Readout points pinned on the photo | No | Planned | | P3 | UX-40 | As Photoshop's colour samplers, with values that stay while sliders move |
| Panel on/off switches | Yes | Done | | | UX-30 | Turn a panel's settings off and on without losing them |
| Hiding Develop panels you don't use | Yes (Classic) | Planned | | P2 | UX-41 | From a panel header's right-click menu; a hidden panel that holds edits shows anyway |
| Reordering Develop panels | Yes (Classic) | Undecided | | | | |
| Typing a slider's value | Yes | Done | | | UX-01 | Arithmetic works too (`x+15`) |
| A value on every control, and values that scrub when dragged | Yes | Done | | | UX-28, UX-29 | Including the grading wheels, the curve's points, Base Look Amount and the Masks panel's sizes and ranges, each typed or scrubbed |
| Lightroom Classic's keyboard shortcuts | Yes | Done | | | | 98 actions on 96 key bindings |
| Your own keyboard shortcuts | No | Planned | | P4 | LIB-36 | Any action on the key you choose, with keymaps for people coming from Lightroom Classic, Photo Mechanic and Bridge |
| Command palette | No | Done | | | UX-07 | Every action and slider from the keyboard (⌘K) |
| Sensor clipping and a colour-assessment view | No | Done | | | UX-05 | |
| Soft proofing | Yes (Classic) | Planned | | P4 | | |
| Secondary display | Yes | Planned | | P4 | LIB-20 | The grid, loupe, Compare or Survey on another screen |

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
| Adobe RGB, ProPhoto and custom ICC output | Yes | Planned | | P3 | EDT-26 | |
| DNG, PSD and JPEG XL output | Yes | Planned | | P4 | | |
| Watermarks | Yes | Planned | | P4 | EDT-25 | |
| Output sharpening | Yes | Planned | | P4 | | |
| Edit in Photoshop or another app | Yes | Planned | | P4 | | |
| Content Credentials | Yes | Planned | | P3 | RM-03 | |
| The edit embedded in exported files | Yes | Done | | | EDT-14 | |
| Command-line rendering and export | No | Done | | | | The `redlamp` tool |

## Library and organising

| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Catalog | Yes | In progress | | P4 | LIB-05, LIB-07, LIB-08, LIB-09, LIB-10, LIB-11 | An index on your Mac of the folders you add, designed for a million photos and rebuilt from the photos and their sidecars at any time; folders on your disk stay the organisation, and edits and metadata stay beside each photo or in Redlamp on this Mac; thumbnails and previews are kept so slow and disconnected drives can be browsed |
| Library and Develop modules | Yes (Classic) | In progress | | P4 | LIB-13 | One window, switched by a key or a click, with the selection, source, filter and filmstrip carried across |
| Search and filters | Yes | In progress | | P4 | LIB-06, LIB-12, LIB-18, LIB-19 | Results as you type; a filter bar of text, attributes and metadata columns with counts, sorts and saved filters, in one query language with the command palette, smart collections and the command line; traits such as long exposures; an empty search names the filter in its way, or a name a typo away; text found whatever its accents and width, so sao finds São Paulo; names found with a typo or by their letters in order, in completion and the palette |
| Grid, Loupe, Compare and Survey | Yes | In progress | | P4 | LIB-14, LIB-16, LIB-17 | Held arrow keys move through photos without waiting; thumbnails show the edit |
| Judging photos while culling | No | Planned | | P4 | LIB-38 | Sensor clipping and a raw histogram in the loupe and Compare, since a raw's embedded JPEG hides clipping, with focus peaking, the camera's focus point and a loupe that follows the pointer |
| Rating, flagging and labelling many photos at once | Yes | In progress | | P4 | LIB-15 | With Undo and Redo, custom labels and marks; by key, by mouse, from menus or the command palette, with Auto Advance; custom labels' colours to come |
| Keywords | Yes | In progress | | P4 | LIB-21 | Keywording and the Keyword List panels on the selection, with completion, counts and keyword sets on ⌥1 to ⌥9; full paths in each photo's sidecar, synonyms and export flags, Lightroom Classic's keyword file both ways, and exports following each keyword's flags |
| Metadata editing and presets | Yes | In progress | | P4 | LIB-22 | The Metadata panel: IPTC fields on many photos at once, presets that replace, append or prefix, code replacements, and Edit Capture Time with the camera's time zone, each with Undo, carried into exports |
| Collections and smart collections | Yes | In progress | | P4 | LIB-23 | In the left panel with All Photographs, Previous Import, Marked and Rejected, the panels, Group By and the filter bar working on each as on a folder; a target collection; smart collections from a rule editor that is the query's text; saved in each photo's sidecar by path, so moving photos never breaks them, and kept current, with stacks |
| Metadata shared with other apps (XMP) | Yes | In progress | | P4 | LIB-24 | Other apps' XMP is read, a corrected capture time included; standard `.xmp` sidecars are written only when you turn it on (Settings › Library, as Lightroom's Automatically write changes into XMP), after each change and its Undo, and originals are never changed |
| Import from cards and cameras | Yes | In progress | | P4 | LIB-27 | A card's photos browsed and culled from their previews before copying, those already imported left out; folder and name templates with a live example; metadata presets applied on import; a backup copy; every copy verified before a card is said to be safe to erase; the window opening when a card is inserted |
| Moving files and folders | Yes (Classic) | In progress | | P4 | LIB-26 | With a preview and Undo, and Recently Trashed to put photos back after Undo is gone |
| Stacks | Yes | In progress | | P4 | LIB-28 | Raw and JPEG pairs, bursts and focus stacks |
| Bringing a Lightroom Classic catalog | Yes | Planned | | P4 | LIB-29, LIB-30 | Ratings, flags, labels, keywords and collections, from a copy of the catalog, with a report; Capture One and darktable libraries too |
| Library Health | Partly | In progress | | P4 | LIB-39, LIB-40 | Exact duplicates, damaged and misnamed files, and a rule for raw and JPEG pairs, each shown only while it has findings and moved to the Trash only from a list you confirm, with Undo |
| Photos grouped into moments | No | In progress | | P4 | LIB-41 | In the grid, by pauses in shooting with one Tighter–Looser control, or by day, folder, camera, lens or orientation; each group with its count and picks, opened and closed, ⌥← and ⌥→ between them, and the moments that have no pick shown alone |
| Soft frames found in bursts | Partly | Later | | | LIB-42 | The sharpest frame of each burst at the camera's focus point, proposed and never applied to a frame you decided. Lightroom Classic's assisted culling judges sharpness; whether it ranks a burst isn't documented |
| People (face recognition) and Map | Yes | Later | | | LIB-34, LIB-35 | |
| AI search | Yes | Later | | | LIB-32, LIB-33 | On the Mac |
| AI-assisted culling | Yes | Later | | | OTH-02 | Lightroom's Assisted Culling judges sharpness, faces and eyes; rating, flagging and labelling work on whole selections in Redlamp's Library today |
| Similar photos | Yes | Later | | | LIB-31 | |

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
| A library shared between Macs | Yes (cloud) | Planned | | P4 | LIB-37 | Ratings, keywords and collections another Mac changes, through iCloud Drive or a shared volume, merged field by field |
| Edits moving between your Mac, iPad and iPhone | Yes (cloud) | Planned | | P5 | | Through iCloud Drive and Files, rather than Adobe's cloud |
| Cloud sync with smart previews | Yes (cloud) | Later | | | | |
| Photos library and a Photos editing extension | Partly (mobile) | Planned | | P2 | | |
