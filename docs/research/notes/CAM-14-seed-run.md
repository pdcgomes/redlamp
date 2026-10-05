# The camera bench over raw.pixls.us (CAM-14)

The camera bench's first run beyond the decode tests' own samples, on 4 October 2026: one CC0 file from [raw.pixls.us](https://raw.pixls.us) for each camera the decode tests don't verify, run through `redlamp camera-bench` and deleted (`scripts/camera-bench-seed.py`). Its report is `research/camera-bench/raw-pixls-seed.json`, and `scripts/camera-bench.py` publishes it as the cameras page's first evidence (`docs/camera-bench.json`).

## Method

- **Files:** raw.pixls.us's repository lists 2,016 files, 1,870 of them CC0, from 921 cameras. For the 898 cameras without a verified sample, the smallest file at full resolution was chosen (no sRAW, mRAW or other reduced mode), and the 865 of at most 60 MB were downloaded, one at a time with a 2-second pause, each checked against the SHA-256 raw.pixls.us publishes.
- **Bench:** Redlamp at `cameras/bench` (process 12, LibRaw 0.22.2), on an M1 Ultra. Two checks changed during the run, after its first results showed false alarms (below); the cameras that failed them were run again on the new versions.
- **Result:** 820 photos in 742 camera modes. 45 files weren't benched: 33 aren't a format Redlamp opens as a raw, and 12 crashed the decoder (below).

| Evidence | Camera modes |
| --- | --- |
| Reported working: opened, and no check failed | 675 |
| Problem found once: a check failed | 65 |
| Verified: a decode test sample of the same camera | 2 |

The failures by check: dark strips along an edge 25, not opening 14, no colour matrix 13, a cast on neutrals 8, the black level 7, the detail not matching the camera's 6, the framing 4, the orientation 2, tinted highlights 1. A camera mode can fail more than one.

## What it found

Each is a Redlamp or LibRaw limitation, seen on the files themselves (the side-by-side pairs are kept locally in `build/camera-bench/pairs`).

1. **Monochrome raws don't open.** The Leica M Monochrom, the M Monochrom (Typ 246) and the Pentax K-3 Mark III Monochrome are refused: their sensors have no colour filter, and the decoder has no single-channel path. Two Plustek film scanners' DNGs are refused too.
2. **Bodies newer than LibRaw 0.22.2 open wrongly instead of being refused.** The Nikon Z50 II and Z5 II decode as coloured noise, and fail every comparison. *(Corrected on 5 October 2026: their samples are High Efficiency NEFs, which LibRaw 0.22.2 sends to its ordinary Nikon decoder; they are refused as CAM-12 since a80c683, and the bodies' lossless files open without a colour matrix. See [CAM-12-nikon-high-efficiency.md](CAM-12-nikon-high-efficiency.md).)* The Canon EOS R6 Mark III's masked margins sit at 537 against a stated black of 71, and its rendering has a cast (9.4). Sony's 15-bit YCbCr ARWs (the RX1R III and the FX2) have a cast. The Fujifilm X-E5, OM System OM-3, Canon PowerShot V1, Nikon Coolpix P1100 and Panasonic TZ95D have no colour matrix, so their colours can't be right. The Sony A7 V is refused, as CAM-13 says.
3. **Fujifilm SuperCCD files crash the decoder.** The S2Pro, S3Pro, S5Pro, S100FS, S5000, S5200, S6000fd, S6500fd, S7000, S9500, S9600 and the GX680's digital back all ended `redlamp camera-bench` with a segmentation fault (signal 11). In the app they decode in the decode service, so the editor survives, but the photo doesn't open.
4. **A raw that states no white balance renders with a strong cast.** The Canon EOS D30's renders orange where its JPEG is neutral (cast 9.5): with no as-shot multipliers, Redlamp uses neutral ones.
5. **Some frames carry dark strips along an edge.** One row along the bottom of the Fujifilm X-H2S and X-S20, and 12 columns along the right of the X-M5 and X-T30 III (bodies LibRaw 0.22.2 may not crop exactly); strips on the Panasonic FZ300, V-LUX 4 and D-LUX 5, the Pentax K-S2, three LG phones, the Blackmagic Pocket Cinema Camera 4K and CHDK DNGs from Canon PowerShots.
6. **Some raws aren't opened as raws.** Olympus and OM System's high-resolution ORI files (which LibRaw reads as ORF) and TIF raws from Kodak DCS bodies, Phase One backs and the first Canon EOS-1D bodies aren't in Redlamp's raw extensions. Lossy DNGs, such as Adobe DNG Converter's lossy option, are refused. GoPro's GPR, Sigma's Foveon X3F and ARRI's ARI aren't supported, as the README says.
7. **Two files render turned or scrambled against their JPEG.** The Leaf Aptus 22's MOS and the Ricoh GXR S10's DNG both match their JPEG best a quarter turn round, with little detail in common.
8. **Framing:** DJI's FC9287 (a Mavic 3) is 9% off its JPEG, beyond what its DNG's own lens correction explains; the Olympus E-10 and Sony DSLR-A100 are a few percent off.

## False alarms it showed, and what changed

- **Zeros counted as dark photosites.** CHDK writes its bad pixels as 0, which took the 0.1th percentile down to 0 where the masked margins agreed with the stated black (the PowerShot A3300 IS: margins at 135 against 127, within their noise of 22). The percentile now leaves zeros out, and the share at 0 is recorded (decode.black 2).
- **Edge strips counted in the percentile.** The bq Aquaris U Plus's dark strip took the percentile down. It's now taken inside the strips' reach (decode.black 2).
- **Image circles taken for strips.** KanDao's 360° cameras leave the frame's edges black in the camera's JPEG too. A strip the camera's JPEG is dark along now passes (decode.edges 2).
- **Margins that aren't the image's black.** The Fujifilm F770EXR's margins are padding at 0, and Pentax's and CHDK's sit 10 to 66 units off their stated black. Margins under a quarter of the stated black are now padding, and only an offset over 1% of the range fails (decode.black 3); `scripts/camera-bench.py` judges the run's version 2 results again by that rule.

## Proposed rows

Tracker rows CAM-20 to CAM-26 propose the work, each citing this note: monochrome raws (1), refusing or flagging bodies LibRaw doesn't know until CAM-13's update (2), the SuperCCD crash (3), white balance when a file states none (4), cropping edge strips (5), the missing raw formats (6), and the turned Leaf and Ricoh files (7).
