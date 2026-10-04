# The camera bench

The camera bench tests raw files from any camera on the Mac they're on: it checks how each file decodes, then compares Redlamp's default rendering with the JPEG the camera embedded in the same file. Only the measurements are kept or sent; the photos never leave the Mac. It is how a camera without a CC0 sample in the decode tests gets evidence on the [cameras page](cameras.md) (CAM-14 to CAM-17).

## Running it

From the command line, on files or folders:

```bash
redlamp camera-bench ~/Pictures/2026 -o report.json --pairs /tmp/pairs
```

Folders are searched for raws. Photos are grouped by camera mode, and up to eight per mode are chosen to cover the evidence checklist below (`--per-mode`, or `--all` for every file). `-o` writes the report in the format the app sends ([`camera-bench.schema.json`](camera-bench.schema.json)); `--pairs` writes each photo's rendering beside the camera's. The command exits with status 2 when a check fails.

In the app, Help › Test Your Camera… opens the Camera Bench window, which runs the same checks and asks one question per camera mode before anything is sent. [redlamp.app/cameras/test](https://redlamp.app/cameras/test) walks through it with screenshots.

## Camera modes

Evidence is counted per camera mode: the camera, LibRaw's decoder (one per compression scheme), the bits per sample and the frame size. One body's modes can fail separately: a Nikon Z 8's standard NEFs open, its High Efficiency NEFs don't (CAM-12). A mode's key reads `Sony|ILCE-7M4|sony_ljpeg_load_raw|14|7028x4688`, and people see it as "Sony ILCE-7M4, 14-bit lossless compressed ARW, 7028 × 4688". Nothing is picked by hand: the camera and mode come from the file.

## The checks

Each check has a version, which changes whenever its measurements or thresholds do, and a verdict: pass, warn, fail or skipped. Reports carry the measurements behind each verdict, so evidence can be judged again under new thresholds. The thresholds are in `CameraBenchChecks.Threshold` (`packages/RedlampRecipes/Sources/Bench/CameraBenchChecks.swift`).

**The decode**, measured inside the decoder:

| Check | What it measures | Warn | Fail |
| --- | --- | --- | --- |
| `decode.opens` | Whether Redlamp opens the file; a known refusal names its tracker row (CAM-10, CAM-12, CAM-13) | | Doesn't open |
| `decode.black` | The black level against the masked margins, where the sensor has margins that look masked, and against the 0.1th percentile of the photosites, edge strips and zeros left out (a photosite at 0 is a dead one or padding; their share is recorded) | Margins 3σ (and 2 units) off, or the percentile 1% of the range below | Margins 5σ (and 4 units) and 1% of the range off, or the percentile 2% below; margins under a quarter of the stated black are padding |
| `decode.white` | Where the photosites clip against LibRaw's white level (CAM-02), and the share clipped | | White within 10% of black |
| `decode.colour` | The camera's colour matrix and white balance | Multipliers outside 0.2 to 8 | No matrix |
| `decode.edges` | Lines along each edge at the black level while the image isn't (the Sony A1 II's strip, CAM-13); a strip the camera's JPEG is dark along too, a fisheye's or a 360° camera's image circle, passes | | Any |

**Against the camera's JPEG**, at 512 pixels, after aligning the two frames with the look profiler's gradient correlation:

| Check | What it measures | Warn | Fail |
| --- | --- | --- | --- |
| `render.default` | Whether the default edit renders | | Doesn't |
| `preview.orientation` | Which quarter turn of Redlamp's matches the camera's best | | Another turn, by 0.15 in correlation |
| `preview.framing` | Scale, offset and aspect ratio against the camera's | Scale 3%, offset 2%, aspect 2% | Scale 7%, offset 5% |
| `preview.structure` | How alike the two frames' edges are | Under 0.5 | Under 0.25 |
| `preview.exposure` | Redlamp's midtones against the camera's, in stops | 2 stops | 3 stops |
| `preview.cast` | The mean OKLab a/b difference (× 100) where the camera rendered a neutral | 4 | 8 |
| `preview.highlights` | Redlamp's chroma (× 100) where the camera's highlights are white | 4 | 8 |
| `preview.colour` | The mean OKLab ΔE (× 100) over flat areas, exposure difference removed | 15 | Never |

The camera's JPEG carries its picture style, its tone curve and often its own lens correction, so these find gross errors: a cast, a frame turned or cropped wrongly, a scrambled mosaic. Colour accuracy is the colour references' job (`tests/golden/cameras`). Files that embed no JPEG (Hasselblad's FFF, Phase One's IIQ) or embed an HEVC preview (the Canon R5 Mark II) skip these checks, and a black and white JPEG skips the colour ones.

**Calibration.** On the 25 verified cameras' 26 samples, no check fails. The Nikon Z 6 warns on framing: its JPEG is cropped by the camera's distortion correction, which Redlamp doesn't read for Nikon. Redlamp's default renders up to 1.7 stops darker than some cameras' JPEGs (the Canon 5D Mark IV's), which set the exposure thresholds. The tests (`CameraBenchTests`) put faults into the decode of a Sony and a Canon sample and check that each is caught by its own check: a quarter turn, the CFA pattern read one column off, a black level 4% of the range too high, a white level three stops too high, and green a third too dark. The run over raw.pixls.us (820 photos in 742 camera modes) found real problems and four false alarms, which set the black and edge checks' current versions; [its note](research/notes/CAM-14-seed-run.md) has both.

## What leaves the Mac

A report holds, per photo: the camera mode, firmware and lens; ISO, shutter, aperture, focal length, orientation and the camera's white balance; the decode's measurements (levels, colour matrix, the previews' sizes); each check's measurements and verdict; and decode and render times. Per report: Redlamp's, LibRaw's, the process's and the bench's versions, the macOS version and the Mac's chip, and from the app, one answer per camera mode with an optional note, a random contributor ID that can be reset, and a name to credit if the contributor gives one. Each photo carries a SHA-256 of the file, so a photo sent twice counts once.

Never sent: pixels, file names, paths, GPS, serial numbers, owner or copyright fields, or capture times. The schema closes every object, so the relay refuses a report carrying anything else. A problem can still be reported with UX-10's feedback reports, where a screenshot is the contributor's choice.

## Evidence and tiers

Submissions go through `redlamp.app/api/bench` to a private repository (CAM-16). `scripts/camera-bench.py` turns them into an evidence checklist per camera mode, published as `docs/camera-bench.json` without contributor IDs or file hashes, and `scripts/camera-list.py` adds the tiers to the cameras page (CAM-17). The thresholds are DEC-28's, proposed until the owner decides:

- **Verified** stays a CC0 sample in the decode tests, which re-check it on every change.
- **Tested by photographers:** on the current LibRaw, 3 contributors and 10 distinct photos, covering base ISO (200 or lower), ISO 3200 or more, a portrait frame, clipped highlights and warm light (under 4000 K); no check failing on more than 10% of the photos, none unexplained; and 2 "same" answers with no open "differs".
- **Reported working:** one photo opened with no failed check.
- **Problem reported:** a failure seen by 2 contributors, or a "differs" answer.

Evidence describes the Redlamp and LibRaw versions it was gathered with. A camera mode without a verified sample links to [raw.pixls.us](https://raw.pixls.us), where a CC0 sample can be given; once it's there, it can join the camera coverage set (`tests/decode/samples.json`) and the camera becomes verified.
