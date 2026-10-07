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

## 21. Library and Catalog (Out of Scope for Now, Kept for the Future Catalog Track)
- Collections and smart collections, folders, and stacks [Later]
- Keywords, metadata editing, and metadata presets [Later]
- Flags, ratings, labels, and filtering [Later; basic per-photo data in P2]
- People (face recognition) and Map/GPS [Later]
- Grid, Compare, and Survey views, and culling, including AI-assisted culling (verify) [Later]
- Smart (AI) search [Later]
- Import presets, rename on import, backup on import, and watched folders [Later]
- Syncing the cloud library [Skip; CloudKit is on the roadmap's Later list]

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
