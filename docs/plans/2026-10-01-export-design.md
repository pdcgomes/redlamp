# Export: design

The owner's goal: an export dialog like Lightroom's, where you set the format, size, quality, compression and whether the file is lossy or lossless. It exports the active photo; exporting several photos at once comes later, and nothing here should stand in its way. Tracker rows EDT-15 (this) and EDT-16 (batch).

## What it writes

Every format goes through ImageIO. On macOS 26 it encodes these, checked in memory:

| Format | Kind | Bits | Options |
| --- | --- | --- | --- |
| JPEG | Lossy | 8 | Quality, file size limit |
| HEIC | Lossy | 8 or 10 | Quality, file size limit |
| AVIF | Lossy | 8 or 10 | Quality, file size limit |
| PNG | Lossless | 8 or 16 | None |
| TIFF | Lossless | 8 or 16 | Compression: None, LZW, ZIP |

- HEIC and AVIF store 10 bits when given a 16-bit render. Quality 1.0 is still lossy in all three lossy formats, so lossless means PNG or TIFF.
- ImageIO's AVIF encoder fails at quality exactly 1.0, and files stop changing above 0.99, so 100 writes 0.99.
- JPEG XL isn't offered: ImageIO decodes it but has no encoder.
- The color space is sRGB or Display P3, chosen before rendering, because the develop kernel clips the gamut into the output primaries. Adobe RGB, ProPhoto and Rec.2020 need output ICC support (TON-10).
- A file size limit bisects quality in at most seven in-memory encodes and keeps the best one under the limit. If even the lowest quality is over, the export fails and says how small it can get.
- Files are written beside the target and moved into place, so a failure never leaves a partial file or loses the one it would have replaced.

## The dialog

A sheet on the editor window (`ExportSheet`, presented like New Recipe), in grouped-form sections:

- **Preset:** a popup, as in the Print dialog: four built-ins (Full Size JPEG; Web, 2048 px; Email, under 500 KB; Print, 16-bit TIFF), then your own, then Save as Preset…, Update and Delete. A preset with a changed setting reads "(edited)". The dialog opens with the last export's settings.
- **Location:** Export to the same folder as the original or a chosen one; the file name is the original's plus a suffix (`-redlamp`) or a custom name, with the result shown; if the file exists: Ask, Add a Number or Overwrite.
- **File:** the format grouped as Lossy and Lossless, then the options above, then the color space. The footer says what the format is good for.
- **Size:** full size, long edge, short edge, width and height, megapixels or percentage, each keeping its own value, with a readout such as `6000 × 4000 → 2048 × 1365 px`. Exports are never enlarged. Resolution (ppi) only goes into the file's metadata.
- **Metadata:** All, All Except Location, or None; and Show in Finder after export.

Export closes the sheet and runs in the background; the canvas pill says "Exporting…" and then "Exported IMG_1234-redlamp.jpg". **Export with Previous** (`⌥⇧⌘E`) repeats the last export without the dialog, asking first only if the file exists and the rule is Ask; with no export yet it opens the dialog.

## Metadata

The original is re-read with ImageIO, which reads raw files' EXIF too, and only an allowlist is copied: Exif (without the pixel size and color space tags), ExifAux, the camera, date, artist, copyright and description from TIFF, IPTC, and GPS. Maker notes, thumbnails and raw dictionaries stay behind. Exports are always tagged upright, since the pixels are, and name Redlamp as the software. All Except Location drops GPS and the IPTC city, region, country and location fields. Focus stack documents export without camera metadata for now.

## Ready for batch

Settings never name a photo (`ExportSettings` in RedlampDocument): the folder and file name are worked out for each photo when it is exported, and `EditorModel.export(_:to:)` takes one photo. A batch then needs a selection, a queue and an engine call that renders a file that isn't open. Exports run on the engine's still path, which renders the open photo; `StillRequest.source` makes that render fail rather than export a photo opened in the meantime, since a background export lets you move on straight away.

## Built in the harness first

- **Live** (`--scene export`): the real dialog on the harness window, exporting the sample photo to its temporary folder, and Export with Previous, with a list of things to try (the Ask prompt, an unreachable size limit, editing and deleting a preset, arrow keys behind the sheet).
- **States** (`--scene export-states`): the dialog for each format, size mode and problem, as still specimens.

The key monitor steps aside while a sheet is up, so ← and → don't change the photo behind the dialog.

## Later

Batch export (EDT-16): multi-selection, background progress and cancel, naming templates with sequence numbers and dates, and Skip for existing files. Then wider color spaces, output sharpening, watermarks, the recipe embedded in the file (EDT-14), JPEG XL once ImageIO encodes it, HDR gain maps, and the CLI writing through `ImageExporter`.
