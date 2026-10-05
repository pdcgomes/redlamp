# Nikon's High Efficiency NEFs (CAM-12)

What Nikon's High Efficiency raw files are, how Redlamp handles them, and the routes to opening them, researched on 5 October 2026. Every source below was read on that date. The samples are CC0 files from [raw.pixls.us](https://raw.pixls.us), downloaded to a temporary folder, checked against their published SHA-256 and deleted afterwards.

## Summary

**Assessment:** take Nikon HE support from LibRaw's next public snapshot, which its maintainers say carries an HE and HE* decoder "this fall", together with CAM-13's update. Until then Redlamp refuses HE files and says they aren't supported yet, with Send Feedback… beside the message (a80c683, 31ce266). No stopgap decoder is worth carrying for the few weeks or months the snapshot is likely to take, and every open decoder raises the same patent question a licensed one would answer.

- HE and HE* are intoPIX's TicoRAW: each raw image is a JPEG XS codestream with Nikon's extensions. HE stores about 3 bits per photosite and HE* about 5, against 14 for the uncompressed data.
- LibRaw 0.22.2 looks for HE data only in the Z 9, Z 8, Z f and Z 6III, and refuses it there. The Z5 II's and Z50 II's HE files went to its ordinary Nikon decoder and opened as noise; since a80c683 they are refused too.
- macOS's own raw engine decodes HE and HE* on every body tried, but gives a demosaiced, processed image, not the sensor data Redlamp develops.

## The format

**Evidence:**

- intoPIX's TicoRAW page lists the codec as "Added in Nikon Z9, Z8, Z6 III, Z5 II", "presented as N-RAW by Nikon", and says "the technology and associated products are covered by one or more claims of patent" ([intopix.com/tico-raw](https://www.intopix.com/tico-raw)).
- The JPEG committee describes JPEG XS (ISO/IEC 21122) as supporting "raw Bayer, classic RGB and the typical YUV representations"; Part 1, 2nd edition, defines decoding "in a bit exact manner". Its reference software (ISO/IEC 21122-5:2025) is offered "for evaluation only" ([jpeg.org/jpegxs](https://jpeg.org/jpegxs/index.html), [software](https://jpeg.org/jpegxs/software.html)).
- In every HE and HE* sample, the raw image (the SubIFD with NewSubfileType 0 and Compression 34713) starts with JPEG XS's SOC and CAP markers, `FF10 FF50`. The capabilities segment, 34 bytes, holds the ASCII text `CONTACT_INTOPIX_`. Then come a 39-byte picture header (PIH), a 14-byte component table (CDT), a 52-byte weights table (WGT) and the first slice header.
- The picture header declares no profile or level (`Ppih` and `Plev` 0), four components, `Cpih` 0 (no colour transform) and a 13-byte extension past the standard 24 bytes, identical on every body and in both modes (`50887083f01523d149cd3f7f07`). Its decomposition-level fields read 81 and 20 and the component table is longer than four components need, so Nikon's stream doesn't follow the standard's field ranges; Alexey Danilchenko describes it as "TICO own Jpeg XS implementation with a lot of quirks" ([LibRaw#826](https://github.com/LibRaw/LibRaw/pull/826), 23 May 2026).
- LibRaw reads Nikon's `NEFCompression` maker-note value on every body: 13 for HE, 14 for HE*, 3 for lossless compressed.

| Sample | Mode | Raw image | Raw data | Bits per photosite |
| --- | --- | --- | --- | --- |
| Nikon Z 9, 23.69 MB | HE | 8280 × 5520 | 17,139,200 bytes | 3.0 |
| Nikon Z 8, 23.25 MB | HE | 8280 × 5520 | 17,139,200 bytes | 3.0 |
| Nikon Z f, 12.84 MB | HE | 6064 × 4040 | 9,186,816 bytes | 3.0 |
| Nikon Z f, 18.72 MB | HE* | 6064 × 4040 | 15,311,360 bytes | 5.0 |
| Nikon Z 6III, 6.22 MB | HE, DX crop | 4000 × 2672 | 4,007,936 bytes | 3.0 |
| Nikon Z5 II, 5.89 MB | HE, DX crop | 4000 × 2672 | 4,007,936 bytes | 3.0 |
| Nikon Z50 II, 8.05 MB | HE, 1:1 | 3728 × 3728 | 5,211,648 bytes | 3.0 |

raw.pixls.us labels all of these "8bit compressed", as it labels the same bodies' lossless files, so its mode names can't tell HE apart; the markers and `NEFCompression` can.

## How Redlamp handled them, and handles them now

**Evidence** (Redlamp at 2ecfcf3 and at a80c683, LibRaw 0.22.2, macOS 26.6.2):

- LibRaw checks for the JPEG XS markers only when the model is `NIKON Z 9`, `NIKON Z 8`, `NIKON Z f` or `NIKON Z6_3` (`src/metadata/tiff.cpp`), and its `nikon_he_load_raw` throws "unsupported". Before a80c683, those four bodies' files gave "… is not a supported image."
- The Z5 II's and Z50 II's HE files went to `nikon_load_raw`, which printed "data corrupted" and returned coloured streaks over a flat green field. The camera bench recorded them as black-level, colour and detail faults (CAM-14's seed run, finding 2).
- Their lossless files (28.17 MB and 17.78 MB) open, but LibRaw 0.22.2 has no colour data for either body, so `decode.colour` fails: the colours can't be right (CAM-21).
- Since a80c683, any Nikon file whose raw image starts with the markers is refused with `EngineError.notSupportedYet` naming CAM-12, unless LibRaw routes it to `nikon_he_load_raw` without flagging that decoder unsupported. The guard steps aside by itself once LibRaw's decoder works, and keeps catching any body LibRaw still misses. The camera bench gives such files the decoder `nikon_he_load_raw`, so their camera mode is apart from the same body's lossless files.
- Since 31ce266, the canvas reads "Nikon's High Efficiency raw files (HE and HE*) aren't supported yet." with **Send Feedback…**, which opens an Idea under Photos & Cameras › Unsupported Camera or Format with the message quoted.

## The routes

### 1. LibRaw's next public snapshot

**Evidence:**

- LibRaw on [#826](https://github.com/LibRaw/LibRaw/pull/826): "We will most likely include HE/HE* decoder in the next public snapshot this Fall" (23 May 2026), then "we've decided to release our/your version along with the next public snapshot this fall. … this specific PR is not planned for use in the library and will be closed after promised public snapshot release" (12 September 2026).
- Alexey Danilchenko: LibRaw "already has the decoder for Nikon HE/HE* (Tico Raw) for quite some time (since 2024) … It is used in FRV and RawDigger"; it "does decode all Nikon lossy Jpeg XS compressions so far"; it was "done by old fashioned painstaking reversing of libraries Nikon decoder is using" (23 May and 12 September 2026).
- Earlier, on [#811](https://github.com/LibRaw/LibRaw/issues/811): "We would be happy to add this decoder to our library if it is offered to us under licensing terms that do not conflict with the current LibRaw licensing" (19 May 2026).
- LibRaw's newest tag is 0.22.2 (16 July 2026). Master's commits up to 2 October 2026 don't touch HE, and its `nikon_he_load_raw` is still the stub.
- Licence: LGPL-2.1 or CDDL-1.0, at the user's choice ([COPYRIGHT](https://github.com/LibRaw/LibRaw/blob/master/COPYRIGHT)); Redlamp uses CDDL-1.0 (`config/vendored-libs.json`).

**Assessment:** the route with the least to build and maintain, shared with CAM-13 (master also has Sony's ARW 6 compressed decoder, merged on 18 July, after 0.22.2). A snapshot isn't a tagged release: `scripts/vendor-libraw.sh` accepts a full 40-character commit SHA as the version, since GitHub's archive of a commit unpacks to `LibRaw-<sha>`. The snapshot's own detection may still name models; Redlamp's guard refuses what it misroutes, so check the Z5 II, Z50 II and ZR samples against it. No date is promised. **Verdict: Shippable** (CDDL-1.0); the patents question below applies.

### 2. The community decoder in LibRaw#826, patched into 0.22.2

**Evidence:** written by Dmitri Sotnikov (yogthos) at `499bfd4`, under LibRaw's dual licence header. It decodes HE only, and refuses HE*. Its author describes the method as an LLM instrumenting "the process when live decoding was happening" and using "Ghidra extensively" (12 September 2026). RdWing's four comments (11 September 2026) fix the last two rows, a lookup-table overread, the transfer curve and raw-GCLI packets; with those fixes it matched "Adobe at every sample in those nine files and two additional Zf/Z5II files", against Adobe DNG Converter 17.5.1's uncompressed mosaics. LibRaw won't merge it.

**Assessment:** a possible stopgap for HE only, at the cost of carrying an unreviewed patch on LibRaw whose provenance is reverse engineering. Not worth it while LibRaw's own decoder is weeks or months away. **Verdict: Shippable** by licence; not recommended.

### 3. dnglab

**Evidence:** [dnglab#835](https://github.com/dnglab/dnglab/pull/835), "Add (experimental) Nikon HE compression Support", opened on 30 August 2026, still open; dnglab is LGPL-2.1 ([licence](https://github.com/dnglab/dnglab/blob/main/LICENSE)) and written in Rust.

**Assessment:** **Avoid** in Redlamp's code (LGPL). As a separate tool it could cross-check a decoder's output.

### 4. A decoder of Redlamp's own

**Evidence:** JPEG XS Part 1 is a published standard, but Nikon's codestream departs from it (the header fields above), and the published details of the departures come from reverse engineering: RdWing's transfer function reads three parameters "from the vendor extension to the JPEG XS picture header".

**Assessment:** large work (bitplane-count decoding, the 5/3 wavelet, Nikon's Bayer reconstruction and tone curve), which can't be written from published specifications alone, and has the same patent exposure as any other unlicensed decoder. Not recommended.

### 5. A licence from intoPIX

**Evidence:** intoPIX offers a "FastTicoRAW SDK — RAW sensor codec · CPU/GPU" for "ARM64, M1" among other platforms, and asserts patents ([intopix.com/tico-raw](https://www.intopix.com/tico-raw)). Its terms and prices aren't public: **UNCLEAR**.

**Assessment:** the only route that comes with a patent licence. A closed binary can't live in the public repository, so it would be a private build input for release builds. Worth asking about only if counsel says the patents rule out an unlicensed decoder.

### 6. macOS's raw engine

**Evidence:** on macOS 26.6.2, `CIRAWFilter` (decoder version 8) lists 15 Nikon Z bodies, the Z5II, Z50II and ZR among them, and decoded all seven HE and HE* samples into the expected photographs.

**Assessment:** it returns a demosaiced, white-balanced image in Apple's colour, not the mosaic, so CFA highlight reconstruction, Redlamp's demosaic, the noise model and Redlamp's camera colour wouldn't apply, and the result would change with Apple's decoder versions. A possible fallback for previews or a "develop with Apple's decoder" mode, not the route for CAM-12. Whether Apple licenses TicoRAW wasn't checked.

### 7. What photographers can do now

Shooting Lossless compressed works on every body, though the Z5 II's and Z50 II's lossless files still lack a colour matrix (CAM-21). Converting with Adobe DNG Converter to an uncompressed or lossless-JPEG DNG should open, since Redlamp reads such DNGs, but wasn't tried here: DNG Converter isn't installed, and JPEG XL DNGs are refused (CAM-10).

| Route | Licence | Patents | Size | When | Verdict |
| --- | --- | --- | --- | --- | --- |
| LibRaw's snapshot | CDDL-1.0 or LGPL-2.1 | Unlicensed (reverse engineered) | S, with CAM-13 | "This fall" | Recommended |
| LibRaw#826 patch | CDDL-1.0 or LGPL-2.1 | Unlicensed | S to M, HE only | Now | Not recommended |
| dnglab | LGPL-2.1 | Unlicensed | — | — | Avoid; cross-check only |
| Redlamp's own decoder | Ours | Unlicensed | L | Months | Not recommended |
| intoPIX FastTicoRAW | Commercial, UNCLEAR | Licensed | S to integrate | After a contract | Only if counsel requires |
| macOS `CIRAWFilter` | System framework | Apple's | M | Now | A fallback at most |

## Checking the decoder when it lands

- **Samples:** the seven files above (raw.pixls.us files 5148, 6616, 6887, 6886, 7810, 7737 and 7767) join the camera coverage set (`tests/decode/samples.json`) with decode and colour goldens. raw.pixls.us has HE* only from the Z f; more HE* samples are needed.
- **Exact references:** Adobe DNG Converter's uncompressed mosaics of the same files, compared photosite by photosite, as RdWing did. The owner would need to install DNG Converter, and the references stay outside the repository like the fixtures.
- **Lossy data in Redlamp's raw stages:** the white level comes from a spike of photosites at the clip point (`WhiteLevel.measured`), which a wavelet codec may spread out; hot-pixel repair works at 8 sigmas; `DecodedImage.noise` prefers a measured noise below 40% of the camera's profile, which quantisation may trigger; the bench's optical black check needs margins the HE frame may not carry. Run the camera bench on the samples and record what each check finds.

## For the owner

1. Accept the route: LibRaw's snapshot when it's public, and no stopgap decoder before it.
2. Ask counsel about patents. intoPIX asserts patents on TicoRAW and JPEG XS; LibRaw's decoder, like every open one, is unlicensed.
3. Optionally install Adobe DNG Converter, for the exact references.
4. ~~Decide how to triage the Send Feedback requests for HE support~~: decided on 5 October 2026, they stay open, labelled `follows:CAM-12`, and are answered and closed when CAM-12 is done (`.cursor/rules/tracker-issues.mdc`).

## Not verified

- Whether Apple licenses TicoRAW, and whether DNG Converter's output opens in Redlamp.
- HE* on any body but the Z f, and the Nikon ZR's files.
- When LibRaw's snapshot ships, and which bodies its detection covers.
