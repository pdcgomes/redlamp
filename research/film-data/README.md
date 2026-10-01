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
  `fetchedVia` is `direct` for every file here. Two URLs (the Endura Premier and Superia X-TRA 400
  datasheets) were located through the Internet Archive CDX index, but the files were downloaded
  live from the manufacturers' servers.
- Values that are not published are `null`, with the reason in the nearest `notes` field. Nothing
  is interpolated beyond the drawn curves or filled in from other sources.

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
| `kodak-2383.json` | Vision Color Print 2383/3383 | Kodak H-1-2383 (8/2026) | characteristic, sensitivity, dye (C/M/Y, visual neutral), MTF | raster | medium; sensitivity low |
| `kodak-endura-premier.json` | Endura Premier (RA-4 paper) | Kodak E-4070 (3/2013) | characteristic, sensitivity, dye (C/M/Y) | vector | high |
| `fuji-provia-100f.json` | Provia 100F (RDP III) | Fujifilm AF3-036E | characteristic, sensitivity, dye (C/M/Y), MTF | stencil raster + vector | high |
| `fuji-velvia-50.json` | Velvia 50 (RVP 50) | Fujifilm AF3-0221E2 | characteristic, sensitivity, dye (C/M/Y), MTF | raster (1-bit scan) | medium |
| `kodak-tri-x-400.json` | Tri-X 400 (400TX) | Kodak F-4017 (12/2016) | 16 characteristic variants, sensitivity (2 criteria), MTF | vector | high |
| `ilford-hp5-plus.json` | HP5 Plus | Ilford HP5 Plus TI (11/2018) | characteristic (relative log E), relative sensitivity | raster | medium |
| `ilford-multigrade-rc.json` | Multigrade RC Deluxe/Portfolio (2020 emulsion) | Ilford Multigrade RC TI (10/2020) | characteristic for filters 00-5 (relative log E), relative sensitivity | raster | medium; 4 vs 5 and sensitivity low |

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
dyeDensity         (colour only)
  wavelength       nm grid
  cyan/magenta/yellow   spectral densities of the individual dyes (null where not published)
  minimum          D-min spectral density;  midscaleNeutral / visualNeutral  where published
granularity        {rmsDiffuse (manufacturer's rms × 1000, conditions in notes), printGrainIndex
                   (Kodak table: negativeFormat, printSize, magnification, value), notes}
resolvingPower     (Fujifilm) lines/mm at test-object contrast 1.6:1 and 1000:1
mtf                {units "percent response", frequencyUnits "cycles/mm", frequency, red/green/blue or neutral}
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

- **Per-dye curves:** Portra 400, Ektar 100, Gold 200 and Superia X-TRA 400 publish only
  mid-scale-neutral and D-min spectral densities, so their `cyan`/`magenta`/`yellow` are null.
- **MTF:** none is published for Gold 200, Endura Premier, HP5 Plus or Multigrade.
- **Granularity:**
  - Vision3 500T and 2383 publish granularity only as σD-vs-log-E curves, which are not digitised.
  - Endura, HP5 Plus and Multigrade publish none.
  - Kodak still films give Print Grain Index, not rms.
- **Relative scales:**
  - Ilford gives relative log exposure only, so HP5 Plus and Multigrade can't be placed in
    lux-seconds.
  - Superia's sensitivity has only a relative log scale.
  - Multigrade's sensitivity chart has no y scale at all; its values are normalised to the peak.
- **Partially drawn curves:**
  - Provia green and blue characteristic curves are drawn only through the shoulder.
  - Velvia's short-wavelength dye tails are truncated at about 385–415 nm.
  - Short fragments and grid-line peaks in the 2383 sensitivity chart are null.
- **Tri-X legend:** the spectral-sensitivity legend (D = 1.0 vs 0.3) looks swapped as published;
  it is stored as labelled.
