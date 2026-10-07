# Lightroom Feature Inventory (Editing-Focused)

Source: working knowledge of Lightroom Classic 14.x, Lightroom (desktop) 8.x, and Lightroom mobile, as of about mid-2025, with what Lightroom has added since in section 22. Adobe ships about every two months; `scripts/lightroom-releases.py` lists the releases since the comparison was last checked. Items marked **(verify)** are ones where the exact name or availability is uncertain.

The phase tags below are the plan as written in September 2026, kept for reference. Where each feature stands today, and in which phase it's planned now, is in [Redlamp and Lightroom compared](lightroom-comparison.md).

Each feature has a roadmap tag:
- **[P1]-[P4]:** the plan phase that builds it.
- **[Later]:** after 1.0.
- **[Replace]:** we build an on-device or open equivalent instead of Adobe's cloud service.
- **[Skip]:** Adobe-ecosystem specific, or not part of an editing product.

## 1. File and Format Support
- Proprietary RAW formats from all Camera Raw-supported bodies [P1, through LibRaw coverage]
- DNG, including lossy DNG and JPEG XL-compressed DNG [P1 for reading; P4 for lossy/JXL]
- Fujifilm X-Trans sensors [P2]
- Apple ProRAW, Samsung Expert RAW, and other smartphone DNGs, including embedded depth maps and gain maps [P2]
- JPEG, TIFF, PNG, PSD (flattened), HEIC/HEIF, AVIF, JPEG XL [P1 for JPEG, TIFF, HEIC; P2 for the rest]
- HDR source images with gain maps and HDR AVIF/JXL [P4]
- Smart Previews, meaning editing without the original [Later, with CloudKit proxies]
- Embedded-preview-first display [P1]
- Per-camera raw defaults: Adobe Default, Camera Settings, a preset, or overrides per camera model, serial number, or ISO [P2]
- Tethered capture (Classic) for Canon, Nikon, Sony, Fujifilm (since 14.4) and Leica (since 15.0), with Live View and a watched folder (Auto Import) for other cameras; see the [tethered capture findings](research/tethering-findings.md) [Later]
- In-app camera with Pro mode, DNG, and HDR capture (mobile) [Later]
- Video (basic trims and adjustments) [Skip]

## 2. Profiles (Profile Browser)
- Adobe Raw set: Color, Standard, Vivid, Portrait, Landscape, Neutral, Monochrome [P2, our own clean-room equivalents]
- Adaptive Color profile, which is AI and scene-adaptive (verify the name) [Later]
- Camera Matching profiles that emulate Canon Picture Styles, Fujifilm Film Simulations, Nikon Picture Controls, and so on [Later; we can't ship Adobe's profiles, and building our own requires reference JPEG capture]
- Creative (LUT) profiles with an Amount slider: Artistic, B&W, Modern, Vintage [P2 for the engine; our own looks in P4]
- Legacy profiles [Skip]
- Custom DCP profiles, for example from DNG Profile Editor, dcamprof, or a ColorChecker [P2]
- Profile favorites, grid or list browsing, and hover preview [P2]
- HDR-capable profiles [P4]
- **Beyond Lightroom:** direct LUT import (`.cube`, `.3dl`, HaldCLUT) with an input-space setting and an Amount slider [P2]. Lightroom only accepts LUTs wrapped as creative profiles made in Camera Raw.
- **Beyond Lightroom:** ICC input profiles [P2]
- **Beyond Lightroom:** look matching, meaning our own fitted looks inspired by camera makers' styles and Adobe renderings, made by black-box measurement [P3+]. Details are in the plan's color science pillar.

## 3. Basic Panel (Mobile: Light and Color)
- Treatment: Color or B&W [P1]
- White Balance presets: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom [P1 except Auto; Auto in P2]
- Temperature and Tint, plus the White Balance Selector eyedropper with a loupe grid [P1]
- Exposure, Contrast, Highlights, Shadows, Whites, Blacks [P1]
- Auto tone (one click) and auto Whites/Blacks with Shift+double-click [P4; needs an auto-tone model or heuristic]
- Texture, Clarity, Dehaze [P2]
- Vibrance, Saturation [P1]
- HDR editing: HDR mode toggle, visualize HDR range, SDR rendition settings, highlight headroom [P4]

## 4. Tone Curve
- Parametric curve: Highlights, Lights, Darks, Shadows, plus 3 region split points [P2]
- Point curve (RGB composite), with presets Linear, Medium Contrast, Strong Contrast [P2]
- Separate Red, Green, and Blue point curves [P2]
- Targeted Adjustment Tool on the curve [P2]
- Refine Saturation on the curve (verify) [P2]
- Input and output readout, and point numeric entry [P2]

## 5. Color Mixer (HSL / Color / B&W)
- HSL: Hue, Saturation, and Luminance for 8 bands (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta), plus an "All" view [P2]
- B&W Mix: gray mixer for the 8 bands [P2]
- Targeted Adjustment Tool for HSL and B&W [P2]
- Point Color: sample a color, then shift its hue, saturation, and luminance; set hue, saturation, and luminance range widths; visualize the range; multiple swatches; also available inside masks [P3]

## 6. Color Grading
- Shadows, Midtones, Highlights, and Global wheels, each with Hue, Saturation, and Luminance [P2]
- Blending and Balance [P2]
- Fine adjustment by modifier-dragging, and a hue-lock or saturation-only drag [P2]

## 7. Detail
- Sharpening: Amount, Radius, Detail, Masking, with an Alt-drag preview [P2]
- Noise reduction, luminance: Amount, Detail, Contrast [P2, a best-in-class classical denoiser profiled per camera and ISO, working on raw data]
- Noise reduction, color: Amount, Detail, Smoothness [P2]
- Enhance, AI Denoise with Amount [P3, an on-device model that demosaics and denoises raw data in one step; an edit rather than a new DNG, as Lightroom's has been since June 2025. See the AI research brief and the DN-11 study]
- Enhance, Raw Details (improved demosaic) [proposed as the noise-free mode of the AI Denoise network (DEC-36, DN-11)]
- Enhance, Super Resolution (2x upscale) [P4, on-device, faithful and not inventing detail]

## 8. Lens Corrections (Mobile: Optics)
- Remove Chromatic Aberration (automatic) [P2]
- Profile corrections: automatic lens lookup, manual make, model, and profile, plus distortion and vignetting amount sliders [P2, clean-room implementation on the lensfun database]
- Manual Distortion, and Lens Vignetting amount and midpoint [P2]
- Defringe: Purple and Green amount and hue range, with a fringe eyedropper [P2]
- Lens Blur (AI depth-of-field): blur amount; bokeh shapes (Circle, Bubble, 5-Blade, Cat Eye, and others); boost; focal range; subject detection; Focus and Blur refine brushes; depth visualization [Later]

## 9. Transform (Mobile: Geometry)
- Upright: Off, Auto, Level, Vertical, Full, and Guided (up to 4 guide lines) [P2 for Guided, Level, and Vertical; P3 for Auto and Full, which need line detection]
- Manual: Vertical, Horizontal, Rotate, Aspect, Scale, X Offset, Y Offset [P2]
- Constrain Crop [P2]
- Loupe while placing guides [P2]

## 10. Effects
- Post-crop vignetting: Style (Highlight Priority, Color Priority, Paint Overlay), Amount, Midpoint, Roundness, Feather, Highlights [P2]
- Grain: Amount, Size, Roughness [P2]

## 11. Calibration
- Process version selector [P1 for the process version stored in every edit; P2 for the selector and "Update to current process"; our own versioned pipeline]
- Shadows Tint [P2]
- Red, Green, and Blue Primary Hue and Saturation [P2]

## 12. Crop and Straighten
- Aspect presets, custom ratios, lock aspect, and swapping orientation (`X`) [P2]
- Overlays: Grid, Thirds, Diagonal, Triangle, Golden Ratio, Golden Spiral, Aspect Ratios; cycle with `O` and change orientation with `Shift+O` [P2]
- Straighten tool, angle slider, and Auto straighten [P2 for manual; P3 for Auto]
- Rotate 90 degrees, and flip horizontal or vertical [P2]
- Constrain to image [P2]
- Generative Expand, which fills beyond the frame using Firefly (verify whether Lightroom has it or only Camera Raw) [Skip or Later as an on-device model]

## 13. Healing / Remove
- Remove tool (content-aware, brush-based) [P3]
- Detect Objects in Remove: a rough stroke over or around a thing, and Lightroom selects the thing itself, as the Objects mask's brush select does (Object Aware from May 2024, renamed in [October 2024](https://www.lightroomqueen.com/whats-new-in-lightroom-2024-10/)) [P3]
- Heal and Clone modes: Size, Feather, Opacity, source repositioning, and choosing a new source [P3]
- Generative Remove (Firefly cloud) [Replace with on-device inpainting; Later]
- Distraction Removal for People, Reflections, and Dust (auto-detect) [Later; dust detection could come earlier]
- Visualize Spots with a threshold [P3]
- Red Eye and Pet Eye correction [P3]
- Syncing spot removal across images [P3]

## 14. Masking
**Components**
- Subject [P2]
- Sky [P2]
- Background [P2]
- Objects: brush or rectangle select [P3]
- People: multiple persons, and parts including Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Clothes [P2 for whole people; P3 for parts]
- Landscape: Mountains, Water, Vegetation, Natural Ground, Artificial Ground, Architecture, Sky (verify the exact list) [P3]
- Brush: A and B brushes plus Erase; Size, Feather, Flow, Density, Auto Mask [P2]
- Linear Gradient [P1]
- Radial Gradient with feather and invert [P1]
- Color Range: sample points, then refine [P2]
- Luminance Range: range plus smoothness, with a luminance map [P2]
- Depth Range, for images with depth maps [P3]

**Operations**
- Add, Subtract, Intersect [P1 for the engine; P2 for the UI]
- Invert a component, Duplicate and Invert a mask [P2]
- Rename, reorder, hide, and delete masks and components [P2]
- Show pins and the overlay toggle [P1]
- Overlay modes: Color Overlay, Color Overlay on B&W, Image on B&W, Image on Black, Image on White, B&W, plus overlay color and opacity [P2]

**Local adjustments per mask**
- Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks [P1]
- Texture, Clarity, Dehaze, Hue (with fine adjustment), Saturation [P2]
- Sharpness, Noise, Moiré, Defringe, Color tint swatch [P2]
- Curves inside masks [P3]
- Point Color inside masks [P3]
- Amount slider on the whole mask, which scales all of its adjustments [P2]

**Workflow**
- Adaptive and mask presets, for example "Blue Sky", "Whiten Teeth", "Enhance Portrait" [P3]
- Updating AI masks when syncing or pasting to other images, and batch updating AI masks [P3]
- Creating a new mask from an existing one [P3]

## 15. Presets, Syncing, and Copy/Paste
- Develop presets (partial settings), preset groups, favorites, and hover preview [P2]
- Preset Amount slider [P2]
- Importing and exporting `.xmp` presets [P2 for import; export in P4]
- Adaptive presets (AI-mask based) [P3]
- Premium and Recommended presets (cloud, AI) [Skip]
- Copy and paste settings with a category picker, Previous, Reset, and Reset to defaults [P2]
- Sync settings, Auto Sync, and Match Total Exposures across a selection [P4]
- Syncing presets through Creative Cloud [Skip; iCloud Drive folder in P4]

## 16. History, Versions, and Compare
- Unlimited History panel with hover preview and clear history [P1 for undo; P2 for the panel]
- Snapshots [P2]
- Virtual copies, or named Versions in Lightroom desktop and mobile [P2, as multiple recipes in one sidecar]
- Before/After: Left/Right, Top/Bottom, split views, swapping, and copying After to Before [P1 for basic; P2 for full]
- Reference view: compare against another photo [P4]

## 17. Viewing, Feedback, and Color Management
- Histogram with clipping indicators, and dragging on the histogram to adjust the matching slider [P1 for the histogram; P2 for dragging]
- RGB or Lab readout under the cursor [P2]
- Clipping overlay (`J`) [P1]
- Zoom levels: Fit, Fill, 1:1, 2:1, and up to 11:1, plus the Navigator [P1]
- Loupe overlays: grid, guides, and a layout image [P4]
- Soft proofing: profile, rendering intent, simulating paper and ink, gamut warnings, and creating a proof copy [P4]
- Secondary display [P4 on Mac]
- Display color management and EDR/HDR display [P1 for SDR; P4 for HDR]
- Ratings, flags, and color labels in the Develop toolbar [P2, stored in the sidecar or XMP; library views stay out of scope]

## 18. Photo Merge
- HDR merge: auto align, auto settings, deghosting, DNG output [Later]
- Panorama: Spherical, Cylindrical, Perspective, Boundary Warp, Fill Edges [Later]
- HDR Panorama [Later]
- **Beyond Lightroom: focus stacking** [P3 for v1, P4 for AI assistance]. This is a flagship differentiator; Lightroom has nothing like it.
  - Stack detection from focus-bracketing metadata.
  - Alignment that handles focus breathing and handheld sequences.
  - Depth-map, pyramid and weighted fusion strategies.
  - A retouch brush that paints from a chosen source frame.
  - Results kept as an editable virtual raw.
  - Later, learned fusion and halo suppression.

## 19. Export and Output
- Formats: JPEG, PNG, TIFF, PSD, DNG, JPEG XL, AVIF, HEIF, or the original file [P1 for JPEG and TIFF; P2 for PNG and HEIF; P4 for the rest]
- Color space: sRGB, Display P3, Adobe RGB, ProPhoto, Rec.2020, or a custom ICC profile; bit depth; quality; limiting file size [P1 for basic; P4 for full]
- Resizing: long edge, short edge, dimensions, megapixels, or percentage; resolution in PPI [P2]
- Output sharpening: Screen, Matte, or Glossy, at Low, Standard, or High [P4]
- HDR export with gain map [P4]
- Metadata: include or exclude, and strip location [P2]
- Watermark (text or graphic) [P4]
- File naming templates and export presets [P4]
- Batch export and background export [P4]
- Edit in Photoshop or another external editor, round trip [P4, via the system share sheet and "Open in" on iOS]
- Content Credentials (C2PA) [Later]
- Publish services, Share to web, Print, Book, Slideshow, Web, and Map modules [Skip]

## 20. Mobile-Specific (Lightroom Mobile)
- Edit tabs: Presets, Auto, Light, Color, Effects, Detail, Optics, Geometry, Masking, Remove, Crop, Versions [P1 for the shell; each tool arrives in its phase]
- Press and hold to see before [P1]
- Quick Actions: AI-suggested edits for the subject or background (verify the current form) [Later]
- Apple Pencil support [P2]
- Hardware keyboard shortcuts on iPad [P2]
- Importing from the Photos library and Files [P1 for Files; P2 for Photos]

## 21. Library and Catalog
Lightroom Classic's Library module as of Classic 15.6 (September 2026), from the [Lightroom Classic research note](research/notes/LIB-lightroom-classic.md), which has the sources. What Redlamp should adopt, do better or skip is in the [library findings](research/library-findings.md), and the track is planned in section 13 of the [research tracker](research/research-tracker.md#13-library-and-catalog). Here [P4] is the library that ships in 1.0, and [Later] its AI and the map, after 1.0 (DEC-46).

**Catalog and storage**
- One catalog database (`.lrcat`, SQLite) as the only complete record, with previews, smart previews and AI pixel data (`.lrcat-data`) stored beside it; the photos stay in folders [P4 as an index on the Mac, rebuilt from the photos and their sidecars; a catalog as the record is skipped (SKIP-18)]
- Collections, stacks, virtual copies and history kept only in the catalog [P4, saved in each photo's sidecar instead; for stacks, proposed in the findings]
- Catalog backups on quitting (zipped, catalog only, never pruned), the Backups tab (14.2), repair of a damaged catalog, Optimize Catalog, and a startup check of AI data (15.5) [P4, as snapshots and background integrity checks of the index]
- Catalog format upgrades in 14.0, 15.0 and 15.4 that keep the old catalog aside [P4, as migrations of an index that can always be rebuilt]
- Missing photos and folders: thumbnail badges, greyed folders, Find Missing Folder, files renamed outside Lightroom relinked one at a time, and since 14.4 a badge that offers to locate a missing folder [P4, followed by file identity without asking]
- Synchronize Folder: imports files other apps added, rescans metadata, and can remove missing photos with their edits [P4, as change detection]
- Photos on a network volume with the catalog on a local disk; several computers by moving the catalog, or the catalog and photos on one external drive [P4: photos on SMB and NFS, an index on each Mac, folders shared through sidecars]
- Several catalogs, and merging them [Skip, proposed in the findings]
- **Beyond Lightroom:** renames and moves made in Finder followed by file identity, with missing and offline photos shown [P4]. Classic relinks a renamed file by hand, one at a time.

**Previews**
- Previews chosen at import (Minimal, Embedded & Sidecar, Standard, 1:1), with 1:1 previews discarded after a day, a week or 30 days [P4, as a grid tier and a screen-size tier]
- A preview cache size limit (14.0), discarding standard and 1:1 previews (14.1), and previews built on the GPU (14.5) [P4]
- Smart previews for editing without the originals (see section 1) [Later]

**Views and navigation**
- Grid (`G`) with cell styles cycled by `J`, and Loupe (`E`) zoomed with `Z` or Space [P4]
- Compare (`C`): a Select and a Candidate, the arrow keys promoting the next photos [P4]
- Survey (`N`): several photos side by side, dropping the weaker ones [P4]
- Secondary display (`Cmd+F11`, then `Shift` with `G`, `E`, `C` or `N`), with a normal, live or locked Loupe [P4]
- The filmstrip following the current source in every module (verify) [P4]
- 21 sort orders, and a custom order for folders and collections [P4 for sort orders and collections' own order]
- The selection remembered in each of the 25 latest sources (14.4) [P4]
- People view (`O`) [Later]

**Culling and marking**
- Flags (`P`, `X`, `U`), star ratings (`0` to `5`) and colour labels (`6` to `9`, red to blue; purple has no key), with `Shift` or Caps Lock moving on after marking [P4, on whole selections with Undo]
- Colour labels as text matched to five colours by a label set, with `xmp:LabelColor` also written since 15.0 [P4, with names and colours the user chooses]
- Custom colour labels: ten named labels in Lightroom Desktop 9.4, not in Classic [P4]
- The Quick Collection, or a target collection, with `B` [P4]
- The Painter: labels, ratings, flags, keywords, metadata or Develop presets, rotation or target collection membership sprayed across thumbnails, with `Option` to erase [P4]
- Stacks (`Cmd+G`, `S` to collapse) within one folder, and auto-stacking by the gap between capture times [P4; the findings propose stacks across folders that keep brackets together]
- An activity indicator (15.4) for culling analysis, XMP saving, address lookup, and duplicate and face detection [P4, proposed in the findings]

**Search, filters and collections**
- The filter bar (`\`): Text, Attribute and Metadata, `Cmd+L` to turn filters on and off, `+` and `!` in text, metadata columns as facets (four by default), stacking in the Attribute filter (15.0), and saved filter presets [P4]
- Smart collections: rows of rules with nested groups (`Option`-click +), with criteria added over releases for AI edits, Denoise and Super Resolution [P4]
- Smart-collection rules on likes and comments from web viewers (15.0) [Skip]
- Collections and collection sets, with their own order, not written to the files [P4]
- **Beyond Lightroom:** collections and marks saved with each photo in its sidecar, so a rebuilt index or another Mac finds them [P4]. Classic keeps collections only in its catalog.
- Requested by Classic users: smart collections that show stacks, a missing-photo filter and rule, and sorting by several fields [P4, proposed in the findings]
- Content (AI) search: only in the cloud apps, with natural-language search in Desktop 9.3 [Later, on the Mac]

**Keywords and metadata**
- The Keyword List: keywords nested by dragging, each with Include on Export, Export Containing Keywords, Export Synonyms and Person, and synonyms that search finds [P4; person keywords with People, Later]
- Keyword entry with suggestions, keyword sets of nine (`Option+1` to `Option+9`), and `Cmd+K` to the keyword field [P4; `Cmd+K` is Redlamp's command palette]
- Hierarchical keywords written to XMP both flat and as a hierarchy, with their parents [P4]
- Keyword lists exported as tab-indented text, or as a CSV with every option (12.2), and imported [P4]
- Merging duplicate keywords, by hand in Classic [P4; merging in one step is proposed in the findings]
- Metadata editing, and metadata presets applied at import and with the Painter [P4]

**Import**
- Copy, Move, Add (in place) and Copy as DNG [P4 for Copy and Add, as folders indexed in place; Move and Copy as DNG aren't planned]
- File-name templates, metadata presets and per-camera defaults applied on import; destination folders by capture date; adding to a collection [P4; per-camera defaults are EDT-06, P2]
- Don't Import Suspected Duplicates, matching capture time and file size since 14.4 [P4]
- A second copy elsewhere [P4, with copies verified]
- The Import dialog's embedded previews, improved in 15.1 [P4]
- Assisted Culling in the Import dialog (15.0) [Later]
- Requested by Classic users: importing raw files only, and erasing the card afterwards [P4, proposed in the findings]

**XMP and other apps**
- Automatically write changes into XMP (Catalog Settings › Metadata), which slows work on slow drives [P4, as `.xmp` sidecars written only when turned on (DEC-44)]
- What XMP carries: Develop settings, ratings, label text and keywords, flags since 13.2, label colour since 15.0, large pixel edits in `.acr` sidecars for proprietary raws since 15.0, and face regions (verify) [P4 for reading]
- XMP written inside DNG, JPEG and TIFF files [Skip; originals are never written (DEC-44)]

**Modules, panels and keys**
- Module keys: `G`, `E`, `C`, `N` and `D`; `Cmd+Option+1` to `Cmd+Option+7` for the seven modules; `Cmd+Option+Up` back to the previous module [P4 for Library and Develop; the Map Later; Book, Slideshow, Print and Web Skip, as in section 19]
- Panel keys: `Cmd+0` to `Cmd+9` for the right-hand panels, `Tab` and `Shift+Tab`, and `F5` to `F8` for one edge at a time [P4]
- No shortcut editor: `G` and `D` are fixed, users remap menu commands through macOS, and 15.0 renumbered the panel shortcuts [a shortcut editor is proposed in the findings]

**AI, faces and the map**
- Assisted Culling (early access in 15.0, general in 15.4): subject focus, eye focus and eyes open per face, exposure, documents and misfires, each criterion switchable and three with sliders; where it runs isn't stated (verify) [Later]
- Stacking by visual similarity, with the best photo on top (15.0) [Later]
- Duplicate detection (15.4): a pausable background index, and a Duplicates view of exact matches as collapsed stacks [Later; the findings propose exact duplicates for 1.0]
- Face detection and recognition (since Lightroom 6, 2015) over the catalog or the current source, with names becoming person keywords [Later]
- The Map module: Google Maps, GPS track logs, and addresses looked up in the background [Later]

**Cloud**
- Syncing chosen collections to the cloud apps as smart previews, with keywords since 15.4 and smart collections not at all [Skip; CloudKit is on the roadmap's Later list]

## 22. Added from Lightroom Classic 14.4 to 15.6 (June 2025 to September 2026)

Summarised from The Lightroom Queen's release notes, one post per release (linked), and not yet checked against Adobe's own pages. Where each stands for Redlamp is in [the comparison](lightroom-comparison.md).

- **Classic 14.4, June 2025** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2025-06/)): more Quick Actions on mobile, and AI tools on mobile download the original first.
- **Classic 14.5, August 2025** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2025-08/)): saved checkbox sets for Copy, Sync and new presets; previews built on the GPU; Generative Remove improved.
- **Classic 15.0, October 2025** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/)): a Variance slider in Point Color; Assisted Culling (AI sorting by sharpness, faces and eyes) and stacking by visual similarity; zooming while cropping; an HDR Limit slider; an improved Reflections model; dust removal; Snow in Landscape masks; Adaptive Landscape presets; Edit in Photoshop changes.
- **Classic 15.1, December 2025** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/)): better import previews; sharing and albums in the cloud apps; Assisted Culling in Desktop.
- **Classic 15.2, February 2026** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-02/)): WebP import (Classic) and export; sending a photo to Firefly for prompt-based edits; Topaz Generative Upscale (2x and 4x, Desktop, generative credits).
- **Classic 15.3, April 2026** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/)): film-inspired presets and profiles that don't replicate particular films; natural-language search in the cloud apps; AI updates for Copy, Paste and Sync run in the background; a warning when exporting AI edits; zooming while cropping in Desktop.
- **Classic 15.4, June 2026** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/)): keyword syncing; duplicate detection; an interactive histogram in Desktop; an improved Select Subject model; custom colour labels; Topaz AI sharpening (Desktop, generative credits).
- **Classic 15.5, August 2026** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/)): Feather and Edge sliders for AI masks; Generative Expand (Desktop and mobile, not Classic); Render to DNG (a rendered image in a DNG wrapper, not a raw); crop improvements.
- **Classic 15.6, September 2026** ([notes](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/)): Reflection Removal improved; Prompt to Edit (Desktop, early access, generative credits).

## Notable Gaps We Could Beat Lightroom On
Candidates, not commitments:
- On-device-only AI for masks, denoise, and removal, with no cloud round trip or credits.
- Consistent sub-16ms slider latency on 100MP files, including with many masks.
- Scene-referred HDR as a first-class workflow, not a mode.
- An open, documented recipe format, and an MPL-licensed engine that others can embed.
- A command palette and searchable panels.
