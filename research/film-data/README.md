# Film and paper datasheet curves

Numeric curves digitised from the manufacturers' published technical datasheets, for use as
reference data by Redlamp's film/print model. One JSON file per stock; `extract.py` regenerates all
of them from the source PDFs.

Stock names appear only here and in each file's provenance fields. Redlamp ships its looks under
its own names.

## Clean-room and provenance rules

- Every value comes from the manufacturer's own PDF, digitised by `extract.py` in this directory.
  No data files, curve tables, presets or code from other film-emulation projects were used or
  consulted (for example agx-emulsion, spektrafilm, darktable, RawTherapee, Filmulator, or any
  GPL or unclear-licence repository). Keep it that way: when adding a stock, digitise it from the
  maker's datasheet.
- The curves are measured facts; the PDFs themselves are copyrighted. **PDFs, page renders and
  check overlays are never committed.** They live under `build/film-data/` (gitignored):
  - `build/film-data/pdf/`: the source PDFs;
  - `build/film-data/check/`: the overlays.
- Each JSON records the document number, edition, URL, retrieval date and the PDF's SHA-256.
  `extract.py` refuses to run on a PDF whose hash differs, so a re-fetched or revised datasheet
  can't silently change the numbers.
- PDFs were fetched politely: one request at a time, at least 1 s apart, stopping on 403/429.
  `fetchedVia` is `direct` for all but two files. Some URLs (Endura Premier, Superia X-TRA 400)
  were located through the Internet Archive CDX index but downloaded live from the manufacturer.
  Two discontinued stocks have no live datasheet left, so they were downloaded from Internet
  Archive captures of the manufacturer's own URL. These are Kodachrome 64 (Kodak E-55, captured
  2000-08-17) and Eterna Vivid 250D (Fujifilm KB-1009E, captured 2012-02-16). `source.url` keeps
  the original manufacturer URL and `fetchedVia` gives the capture URL. Only raw (`id_`) captures
  of manufacturer URLs were used, never third-party mirrors.
- Values that are not published are `null`, with the reason in the nearest `notes` field. Nothing
  is extrapolated beyond the drawn curves or filled in from other sources. The one exception to
  "no interpolation" is the 2383 sensitivity's grid-line samples: they are interpolated only
  across a vertical grid line, only where both sides are traced, and are listed in
  `interpolatedSamples`.

## Regenerating

```sh
python3 -m venv build/film-data/venv && build/film-data/venv/bin/pip install pymupdf
# download each SOURCES[...]['url'] in extract.py to build/film-data/pdf/<SOURCES[...]['file']>
build/film-data/venv/bin/python research/film-data/extract.py              # all stocks
build/film-data/venv/bin/python research/film-data/extract.py kodak-2383   # one stock
```

`extract.py` uses only the standard library and PyMuPDF. For every chart it writes an overlay to
`build/film-data/check/<id>-<curve>.png`: the source chart, faded, with the extracted samples drawn
on top. Look at the overlays after any change.

## Files

| file | stock | source document | charts | method | confidence |
|---|---|---|---|---|---|
| `kodak-portra-400.json` | Portra 400 | Kodak E-4050 (1/2025) | characteristic, sensitivity, dye (neutral + D-min), MTF | vector | high |
| `kodak-ektar-100.json` | Ektar 100 | Kodak E-4046 (1/2025) | characteristic, sensitivity, dye (neutral + D-min), MTF | vector | high |
| `kodak-gold-200.json` | Gold 200 | Kodak E-7022 (3/2022) | characteristic, sensitivity, dye (neutral + D-min) | vector | high |
| `fuji-superia-xtra-400.json` | Superia X-TRA 400 | Fujifilm AF3-0217E | characteristic, relative sensitivity, dye (neutral + D-min), MTF | vector | high |
| `kodak-vision3-500t.json` | Vision3 500T 5219/7219 | Kodak H-1-5219 (3/2026) | characteristic, sensitivity, dye (C/M/Y, neutral, D-min), MTF | raster | medium |
| `cinestill-800t.json` | CineStill 800T | = H-1-5219 (5219 without rem-jet) | as Vision3 500T | raster | medium |
| `kodak-2383.json` | Vision Color Print 2383/3383 | Kodak H-1-2383 (8/2026) | characteristic, sensitivity (re-traced in batch 2), dye (C/M/Y, visual neutral), MTF | raster | medium |
| `kodak-endura-premier.json` | Endura Premier (RA-4 paper) | Kodak E-4070 (3/2013) | characteristic, sensitivity, dye (C/M/Y) | vector | high |
| `fuji-provia-100f.json` | Provia 100F (RDP III) | Fujifilm AF3-036E | characteristic, sensitivity, dye (C/M/Y), MTF | stencil raster + vector | high |
| `fuji-velvia-50.json` | Velvia 50 (RVP 50) | Fujifilm AF3-0221E2 | characteristic, sensitivity, dye (C/M/Y), MTF | raster (1-bit scan) | medium |
| `kodak-tri-x-400.json` | Tri-X 400 (400TX) | Kodak F-4017 (12/2016) | 16 characteristic variants, sensitivity (2 criteria), MTF | vector | high |
| `ilford-hp5-plus.json` | HP5 Plus | Ilford HP5 Plus TI (11/2018) | characteristic (relative log E), relative sensitivity | raster | medium |
| `ilford-multigrade-rc.json` | Multigrade RC Deluxe/Portfolio (2020 emulsion) | Ilford Multigrade RC TI (10/2020) | characteristic for filters 00-5 (relative log E), relative sensitivity | raster | medium; 4 vs 5 and sensitivity low |

Batch 2 (2026-10-01):

| file | stock | source document | charts | method | confidence |
|---|---|---|---|---|---|
| `kodak-portra-160.json` | Portra 160 | Kodak E-4051 (1/2025) | characteristic, sensitivity, dye (neutral + D-min), MTF | vector | high |
| `kodak-portra-800.json` | Portra 800 | Kodak E-4040 (1/2025) | characteristic (EI 800 plus EI 1600 / 3200 push variants), sensitivity, dye (neutral + D-min), MTF | vector | high |
| `kodak-ultramax-400.json` | UltraMax 400 | Kodak E-7023 (2/2016) | characteristic, sensitivity, dye (neutral + D-min) | vector | high |
| `kodak-ektachrome-e100.json` | Ektachrome E100 | Kodak E-4000 (8/2018) | characteristic, sensitivity, dye (C/M/Y, visual neutral), MTF | vector | high |
| `kodak-t-max-100.json` | T-Max 100 (TMX) | Kodak F-4016 (6/2018) | 11 characteristic variants (D-76, T-MAX, T-MAX RS …), sensitivity (2 criteria), MTF | vector | high |
| `kodak-t-max-400.json` | T-Max 400 (TMY-2) | Kodak F-4043 (2/2016) | 9 characteristic variants, sensitivity (2 criteria), MTF | vector | high |
| `ilford-delta-100.json` | Delta 100 | Ilford TI (4/2023) | characteristic (relative log E), relative sensitivity | raster | medium |
| `ilford-delta-3200.json` | Delta 3200 | Ilford TI (6/2025) | 8 characteristic variants (DD-X, Microphen; 7–16 min), contrast vs time, relative sensitivity | raster | medium; toe of merged curves lower |
| `ilford-fp4-plus.json` | FP4 Plus | Ilford TI (11/2018) | characteristic (relative log E), relative sensitivity | raster | medium |
| `ilford-pan-f-plus.json` | Pan F Plus | Ilford TI (B26) | characteristic (relative log E), relative sensitivity | raster | medium |
| `kodak-vision3-250d.json` | Vision3 250D 5207/7207 | Kodak H-1-5207 (3/2026) | characteristic, sensitivity, dye (C/M/Y, neutral, D-min), MTF | raster | medium |
| `kodak-vision3-50d.json` | Vision3 50D 5203/7203 | Kodak H-1-5203 (3/2026) | characteristic, sensitivity, dye (C/M/Y, neutral, D-min), MTF | raster | medium; sensitivity medium-low |
| `cinestill-50d.json` | CineStill 50D | = H-1-5203 (5203 without rem-jet) | as Vision3 50D | raster | as Vision3 50D |
| `fuji-velvia-100.json` | Velvia 100 (RVP 100) | Fujifilm 163AR0096C (5/2017, Japanese) | characteristic, sensitivity, dye (C/M/Y), MTF | raster | medium |
| `fuji-eterna-vivid-250d.json` | Eterna Vivid 250D (8546/8646) | Fujifilm KB-1009E (©2010; archive capture) | characteristic (camera stops), relative sensitivity, dye (neutral + D-min), CTF | vector | high; sensitivity medium |
| `fuji-pro-400h.json` | Pro 400H (discontinued) | Fujifilm 013AR0328A (2/2013, Japanese) | characteristic, relative sensitivity (+ fourth layer), dye (neutral + D-min), MTF | vector | high; MTF medium |
| `kodak-kodachrome-64.json` | Kodachrome 64 (discontinued) | Kodak E-55 (12/1996; archive capture) | characteristic, sensitivity, dye (C/M/Y, visual neutral), MTF | vector | high |

Source URLs for batch 2 (each JSON's `source` block also has the SHA-256):

| stock | URL |
|---|---|
| Portra 160 | https://kodakprofessional.com/sites/default/files/2025-07/e4051.pdf |
| Portra 800 | https://kodakprofessional.com/sites/default/files/2025-07/e4040.pdf |
| UltraMax 400 | https://kodakprofessional.com/sites/default/files/wysiwyg/KodakUltraMax400TechSheet-1.pdf |
| Ektachrome E100 | https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf |
| T-Max 100 | https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4016_TMax_100.pdf |
| T-Max 400 | https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4043_TMax_400.pdf |
| Delta 100 | https://www.ilfordphoto.com/amfile/file/download/file/3/product/679/ |
| Delta 3200 | https://www.ilfordphoto.com/amfile/file/download/file/1913/product/682/ |
| FP4 Plus | https://www.ilfordphoto.com/amfile/file/download/file/1919/product/688/ |
| Pan F Plus | https://www.ilfordphoto.com/amfile/file/download/file/1905/product/699/ |
| Vision3 250D | https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION3-250D-5207-7207-technical-information.pdf |
| Vision3 50D / CineStill 50D | https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION3-50D-5203-7203-technical-information.pdf |
| Velvia 100 | https://asset.fujifilm.com/www/jp/files/2024-04/56c15e414d446997d6d609f5726df093/datasheet_velvia100_01.pdf |
| Pro 400H | https://asset.fujifilm.com/www/jp/files/2024-04/198fe31ee57628013d29171770b28218/datasheet_pro400h_01.pdf |
| Eterna Vivid 250D | http://www.fujifilm.com/products/motion_picture/pdf/eterna_vivid250d.pdf, via https://web.archive.org/web/20120216070558id_/http://www.fujifilm.com/products/motion_picture/pdf/eterna_vivid250d.pdf |
| Kodachrome 64 | http://www.kodak.com:80/global/en/professional/support/techPubs/e55/e55.pdf, via https://web.archive.org/web/20000817190405id_/http://www.kodak.com:80/global/en/professional/support/techPubs/e55/e55.pdf |

Each file's `extraction.notes` and the section `notes` fields record what was traced, what was
left null and why.

### How the curves were extracted

- **Vector charts.** Curves are the PDF drawing paths themselves:
  - Bézier segments are flattened, and pieces drawn separately are joined end to end.
  - Axes are calibrated by snapping the numeric tick labels to their tick or grid marks with a
    least-squares fit. Calibration residuals are well under 0.01 units.
  - Curves are identified by the position of their peak (sensitivity and dye), their order at
    D-max, or their dash style (Tri-X development times, checked against the legend).
- **Raster charts** (embedded bitmaps, 1.7–8 px/pt). Axes come from detected grid lines or tick
  marks, paired with the printed labels. Where a chart has no ticks, the centres of the label
  text are used. Each curve is then followed by a dynamic-programming tracker that:
  - keeps each curve's direction through crossings and merges;
  - skips grid-line columns;
  - bridges short gaps linearly.

  Very steep curves (Multigrade) are followed row by row instead. Where one trace cannot pass a
  crossing, or a peak lying on a grid line, the curve is traced as separate pieces and joined; the
  samples on the grid line stay `null`. Provia's charts are 1-bit stencils, one per curve,
  identified by their paint colour, so overlapping curves separate exactly.
- **Additions in batch 2:**
  - **Rotated pages.** Eterna Vivid 250D's page is stored with `/Rotate 90`. PyMuPDF reports
    drawings and text unrotated, so `page_drawings` and `_number_spans` map them through the
    page's rotation matrix. Overlays embed a de-rotated copy of the page.
  - **Column reading (`curves_by_columns`).** This is for bitmaps whose curves and grid share one
    colour. Every image column is read:
    - Ink runs, with grid rows removed, are named by a top-to-bottom order given per x range.
    - Steep segments use the run centre.
    - A sample on a vertical grid line is interpolated linearly between the nearest clean columns
      on both sides. This happens only when both sides lie within 2.5 pt, and such samples are
      listed in `interpolatedSamples`. It is used for the 2383 spectral sensitivity.
  - **MTF by runs (`mtf_by_runs`).** The Vision3 250D and 50D MTF curves cross too tightly for the
    tracker. Each standard frequency is read as a column, and runs are named by the order of the
    curves in that frequency range. Columns where the run count doesn't match (touching curves)
    stay null.
  - **Ilford wedge axes (`wedge_axes`).** Ilford's wedge-spectrogram charts have no x ticks. x
    comes from the centres of the wavelength-label glyph groups, and y from the 0.5 / 1.0 ticks
    right of the frame.
  - **Vision3 configs.** The Vision3 stocks share one function driven by a per-datasheet config:
    chart xrefs, axes, seeds, `densityType` and notes.

### Kodak 2383 spectral sensitivity re-trace (batch 2)

No vector or higher-resolution version exists. H-1-2383 Revised 8-26 is the current and only
revision found, and it carries the chart only as a 428×397 px bitmap (1.7 px/pt). So the chart was
re-read with `curves_by_columns` instead of the tracker. What changed:

- **Magenta-forming (green) peak.** It is a cusp on the 550 nm grid line. The old file had −0.58
  at 540 nm and −0.54 at 555 nm, with 545/550 null. It now reads −0.40 at 545 and −0.27 at 550,
  interpolated across the line; the drawn tip is about −0.2. Simply interpolating the old 540 and
  555 samples would have flattened the peak.
- **Steep tails added:**
  - blue at 500–510 nm (down to −2.87);
  - red at 730 nm (−2.86).
- **Red near its peak.** 700 and 705 nm are now filled: 700 is interpolated across the grid line;
  705 is read directly.
- **Fewer interpolated samples.** The old 1.0 pt grid-column band was wider than the drawn line.
  It is now ±0.75 pt, so fewer samples need interpolation.
- **Label excludes.** The magenta label exclude used to clip the curve at 561–565 nm. It was
  tightened, and the top text box is now excluded explicitly.
- **Interpolated samples (all on grid lines):**
  - blue 400 / 450 / 500 nm;
  - green 500 / 550 nm;
  - red 600 / 650 / 700 nm.
- **Still null:**
  - blue at 355–370 nm, which runs along the 0.0 grid line;
  - green's vertical start at 450 nm, which runs along the grid line;
  - the green/red tails at 584–592 nm, where the curves merge;
  - two unlabelled fragments from about 368 nm down to −3.0, which can't be attributed to a layer.

Confidence is raised from low to medium.
- **Sampling.** Output grids are every 0.05 log H for characteristic curves and every 5 nm for
  spectra. MTF uses a fixed frequency list (1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 10, 12, 15, 20,
  25, 30, 35, 40, 50, 60, 70, 80, 100, ... 300 c/mm), restricted to each chart's traced range.
  Samples outside a curve's drawn extent are `null`.

## Schema (`schemaVersion` 1)

```text
id, name, manufacturer
type               "negative" | "reversal" | "print" | "bw-negative" | "bw-paper"
process            development process as stated by the datasheet
exposureIndex      manufacturer's rated EI (null for print materials)
source             {title, document, edition, url, fetchedVia, retrieved, sha256, pages}
support            (print materials only) description of the base
characteristicCurves
  densityType      "status-M", "status-A", "status-A (reflection)", "diffuse visual", or null if unstated
  exposure         illuminant / exposure time used for the sensitometry
  logHRef          (Kodak still films) the "Log H Ref" printed on the chart, in log lux-s
  logExposureUnits "log10 exposure in lux-seconds", or "relative log exposure" (Ilford: arbitrary origin)
  logExposure      x grid
  red/green/blue   density arrays aligned with logExposure (colour);  neutral  (black-and-white)
  dMin             density at the lowest plotted exposure (base + fog [+ mask]); per channel for colour
  dMax             (reversal) density at the lowest plotted exposure
  variants         (black-and-white) every published development condition or filter grade, each with
                   its own logExposure and neutral arrays and the condition (format, developer, time;
                   or filter, isoRange, isoSpeedP)
spectralSensitivity
  units            log10 sensitivity, S = 1 / exposure (erg/cm² for Kodak, J/cm² for Fujifilm;
                   the two differ by a constant 7.0 in log S), or a relative scale as stated
  densityCriterion density at which S is defined (e.g. "0.2 above D-min (Status M)"), null if unstated
  wavelength       nm grid;  red/green/blue (colour, by sensitive layer) or neutral
                   neutralD03 (Kodak B&W: the second published criterion, D = 0.3);
                   fourthLayer (Pro 400H: Fujifilm's fourth colour-sensitive layer, relative scale)
  interpolatedSamples  (2383) wavelengths per curve interpolated across a vertical grid line
dyeDensity         (colour only)
  wavelength       nm grid
  cyan/magenta/yellow   spectral densities of the individual dyes (null where not published)
  minimum          D-min spectral density;  midscaleNeutral / visualNeutral  where published
granularity        {rmsDiffuse (manufacturer's rms × 1000, conditions in notes), printGrainIndex
                   (Kodak table: negativeFormat, printSize, magnification, value), notes}
resolvingPower     (Fujifilm) lines/mm at test-object contrast 1.6:1 and 1000:1
mtf                {units "percent response", frequencyUnits "cycles/mm", frequency, red/green/blue or neutral}
                   (Eterna Vivid 250D: a square-wave contrast transfer function, flagged in units/notes)
contrastVsDevelopmentTime  (Delta 3200) published contrast-vs-time curves, {series: ...}
interlayer         layer-structure / interimage description as published, or null
notes              stock-level notes (EI alternatives, related stocks, what is not digitised)
derived            sanity checks computed by extract.py, NOT published values:
                   gamma (least-squares slope over the central 25-75 % of each curve's density range;
                   omitted for curves that span < 60 % of the widest one), monotonic,
                   sensitivityPeakNm, dyePeakNm, gammaByVariant / gammaByFilter
extraction         {method, tool, notes, confidence, checks}
```

Units, in short:
- density: base-10 optical density;
- exposure: base-10 log lux-seconds (unless marked relative);
- wavelength: nm;
- spatial frequency: cycles/mm;
- MTF: percent (values above 100 at low frequency are as published).

Arrays are plain JSON numbers with `null` for "not drawn / not published"; there is no NaN or
Infinity.

## Known gaps

- **Per-dye curves:** these stocks publish only mid-scale-neutral and D-min spectral densities,
  so their `cyan`/`magenta`/`yellow` are deliberately null (not fitted here; the model fits dyes
  from the neutral):
  - Portra 400, Ektar 100, Gold 200 and Superia X-TRA 400;
  - in batch 2, also Portra 160, Portra 800, UltraMax 400, Pro 400H and Eterna Vivid 250D.
- **MTF:** none is published for these stocks:
  - Gold 200, UltraMax 400, Endura Premier and Multigrade;
  - the Ilford films: HP5 Plus, Delta 100, Delta 3200, FP4 Plus and Pan F Plus.
- **Eterna Vivid 250D's sharpness curve** is a square-wave CTF, not an MTF.
- **Granularity:**
  - The Vision3 stocks (500T, 250D, 50D) and 2383 publish granularity only as σD-vs-log-E curves,
    which are not digitised.
  - Endura and the Ilford films publish none.
  - Kodak still colour negatives (including Portra 160 / 800 and UltraMax) give a Print Grain
    Index, not rms.
  - rms values, all on the ×1000 scale with a 48 µm aperture:
    - E100 8, Kodachrome 64 10, T-Max 100 8 and T-Max 400 10 (Kodak);
    - Velvia 100 8, Pro 400H 4 and Eterna Vivid 250D 3.5 (Fujifilm).
  - The reference density differs: Kodak reversal reads at gross D = 1.0, Kodak B&W at net
    D = 1.0, and Fujifilm at 1.0 above D-min.
- **Discontinued and not found:**
  - ETERNA 250D (non-Vivid): the only Internet Archive capture of Fujifilm's URL (2009-01-09) is a
    truncated PDF that opens with zero pages, even when re-fetched with the same SHA-256. ETERNA
    Vivid 250D was digitised instead.
  - Other ETERNA variants (250, 400, 500, Vivid 160, Vivid 500, RDI) have captures listed but
    were not digitised.
  - Kodachrome 25 and 200 are in the same E-55 PDF but were not asked for.
- **Rem-jet versus AHU (CineStill 800T / 50D):**
  - Kodak's current (Revised 3-26) VISION3 datasheets say an anti-halation undercoat now replaces
    the rem-jet backing.
  - CineStill describes its stocks as "rem-jet removed".
  - No manufacturer document says which construction current CineStill stock uses, or what
    anti-halation protection it keeps.
  - The notes say to model halation as if there were no effective anti-halation layer.
- **Relative scales:**
  - Ilford gives relative log exposure only, so HP5 Plus, Delta 100, Delta 3200, FP4 Plus, Pan F
    Plus and Multigrade can't be placed in lux-seconds.
  - Ilford's sensitivity charts are wedge-spectrogram outlines, and the datasheets don't say
    whether the scale is linear or logarithmic.
  - Eterna Vivid 250D's characteristic x axis is camera stops (converted at 0.301 log per stop,
    origin = normal exposure).
  - The sensitivity of Superia, Pro 400H and Eterna Vivid has only a relative log scale.
  - Multigrade's sensitivity chart has no y scale at all; its values are normalised to the peak.
- **Partially drawn curves:**
  - Provia green and blue characteristic curves are drawn only through the shoulder.
  - Velvia's short-wavelength dye tails are truncated at about 385–415 nm.
  - Short UV fragments and the merged green/red tails in the 2383 sensitivity chart are null; its
    grid-line samples are interpolated (see above).
- **Tri-X legend:** the spectral-sensitivity legend (D = 1.0 vs 0.3) looks swapped as published;
  it is stored as labelled.
