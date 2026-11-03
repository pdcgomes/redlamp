# Export: design

The owner's goal: an export dialog like Lightroom's, where you set the format, size, quality, compression and whether the file is lossy or lossless. It exports the active photo, or the photos selected (Batch export, below). Tracker rows EDT-15 (the dialog) and EDT-16 (batch).

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
- **Location:** Export to the same folder as the original or a chosen one; the file name is a naming template, the original's name with `-redlamp` by default, with the result shown; if the file exists: Ask, Add a Number, Overwrite or Skip.
- **File:** the format grouped as Lossy and Lossless, then the options above, then the color space. The footer says what the format is good for.
- **Size:** full size, long edge, short edge, width and height, megapixels or percentage, each keeping its own value, with a readout such as `6000 × 4000 → 2048 × 1365 px`. Exports are never enlarged. Resolution (ppi) only goes into the file's metadata.
- **Metadata:** All, All Except Location, or None; and Show in Finder after export.

Export closes the sheet and runs in the background; the canvas pill says "Exporting…" and then "Exported IMG_1234-redlamp.jpg". **Export with Previous** (`⌥⇧⌘E`) repeats the last export without the dialog, asking first only if the file exists and the rule is Ask; with no export yet it opens the dialog.

## Metadata

The original is re-read with ImageIO, which reads raw files' EXIF too, and only an allowlist is copied: Exif (without the pixel size and color space tags), ExifAux, the camera, date, artist, copyright and description from TIFF, IPTC, and GPS. Maker notes, thumbnails and raw dictionaries stay behind. Exports are always tagged upright, since the pixels are, and name Redlamp as the software. All Except Location drops GPS and the IPTC city, region, country and location fields. Focus stack documents export without camera metadata for now.

## Batch export (EDT-16)

Decided with the owner on 14 October 2026.

- **How it starts:** Export… (⇧⌘E), the toolbar's Export and the palette act on the photos selected in the filmstrip or the grid. With several, the dialog is titled and buttoned "Export 12 Photos"; Export with Previous (⌥⇧⌘E) exports the selection with the last settings, without the dialog. The open photo, selected alone, exports as it always has, rendered by the editor's engine. In the Library, the photos chosen in the grid aren't open, so even one of them goes to the worker, and the dialog leaves out the exported size, which takes the open photo's size and crop.
- **Naming:** the File name is the naming template field Rename Photos and the import window share (LIB-25), with its presets (Lightroom Classic's nine, Redlamp's three, and those saved, shared with renaming and importing), Insert Token, Custom Text, Shoot Name and a start number for sequences. "Filename with Suffix", `{name}-redlamp`, is the default, and settings saved before templates name files as they did (`ExportNaming`). `ExportNames` (RedlampLibrary) names a batch: sequences number the photos in the filmstrip's order, `{total}` counts them, named counters carry on, and no two photos get one name, those after the first numbered in the order they were taken; a raw's export and its JPEG's are two files.
- **Files already there:** a photo is never replaced, whatever the rule; an earlier export is replaced, numbered or skipped, or asked about once for the whole batch (Replace, Keep Both, Skip). Skip joins the rules.
- **The worker** (`BatchExport`, RedlampUI) renders in an engine of its own, made by the factory Sync Settings' worker uses, with its own GPU queue, so Develop's frames never wait behind an export. One photo at a time is opened, rendered, written and let go, since a downscaled export still renders at full resolution in half floats. The library's edit renders wait while a batch runs, as they do for one export.
- **Edits:** each photo exports as it was when Export was clicked. A batch takes every photo's edit as soon as it's asked for, the open photo's as it is on screen and the others' from their sidecars once their saves are on disk; until a photo's edit is taken, opening it waits, and so do Sync Settings' writes to it. The edits are kept without their masks' bitmaps, read again from each photo's sidecar when its turn comes. A photo moved, renamed or deleted while it waits fails, by name, and so does one whose edit is damaged or can't be read, rather than exporting as shot.
- **Progress, Cancel and failures:** the filmstrip's status, where Sync Settings shows its own, says "Exporting: 3 of 12" with Cancel, in Develop and Library, and the toolbar's Export button carries the count left. Cancel stops after the photo being written; what's written stays. A photo that fails is left and the rest go on; at the end one alert names each with its reason, with Show in Finder and Report This Problem…, and the status says how it went for a few seconds.
- **From the command line:** `redlamp export <photos or folders…> --to <folder>` exports as the worker does, one photo at a time in an engine of its own, each with the edit its sidecar holds when its turn comes (as shot without one), named by `ExportNames` and written by `ImageExporter`. A folder gives the photos in it, in name order. The dialog's settings are options (`--name`, `--text`, `--start`, `--existing number|overwrite|skip`, the format, size and metadata); there's no Ask, so an earlier export with the same name is numbered unless `--existing` says otherwise. It reads no library, so names come from what each file and its sidecar say, and photos whose sidecars the library keeps on this Mac export as shot. Each file written and each photo that failed, with why, is printed, and it exits 1 if one failed.

## Built in the harness first

- **Live** (`--scene export`): the real dialog on the harness window, exporting the sample photo to its temporary folder, and Export with Previous, with a list of things to try (the Ask prompt, an unreachable size limit, editing and deleting a preset, arrow keys behind the sheet).
- **States** (`--scene export-states`): the dialog for each format, size mode and problem, as still specimens.

The key monitor steps aside while a sheet is up, so ← and → don't change the photo behind the dialog.

## Later

Wider color spaces, output sharpening, watermarks, the recipe embedded in the file (EDT-14), JPEG XL once ImageIO encodes it, HDR gain maps, and `redlamp render` writing through `ImageExporter`, as `redlamp export` does.
