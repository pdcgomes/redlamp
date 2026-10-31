# Where Canon's small raws clip (CAM-33)

Canon's sRAW and mRAW CR2s, the smaller sizes Canon's bodies record as YCbCr, are decoded by LibRaw's `canon_sraw_load_raw`, which converts them to RGB and states a black level of 0 and a white level of 16383 whatever the body. Each body's small raw data clips elsewhere, so normalised at 16383 a body's small raws open darker or brighter than its full raws. This note measures where 15 bodies' small raws clip, on raw.pixls.us samples of one scene shot both ways, and checks the levels on the camera bench. From process 20 (raw revision 6) Redlamp normalises those bodies' small raws at these levels (`RawDecoder.smallRawWhiteLevels`; [the raw pipeline](../../raw-pipeline.md), section 6), measured on 30 and 31 October 2026.

## Method

- **Files.** CC0 sets on [raw.pixls.us](https://raw.pixls.us) in which one contributor shot one scene on one day as RAW and as sRAW, mRAW or both, each file checked against the SHA-256 raw.pixls.us publishes: 31 small raws and 16 full raws of 16 bodies. 26 of the small raws were shot at their full raw's ISO, shutter speed and aperture. Five weren't, and were benched but not measured: the 5D Mark IV's mRAW (982) at another shutter speed, the 5DS's sRAW (2085) at another aperture, the EOS-1D Mark IV's sRAW (4260) at another shutter speed, and the 80D's mRAW and sRAW (1295, 1296), shot at 1/250 s and 1/320 s where its full raw (1294) was shot at 1/160 s.
- **Means.** Each colour's mean over the frame, black subtracted, from LibRaw's unpacked data: a full raw's photosites, a small raw's `color4_image`.
- **Gain.** A small raw's green mean over its full raw's.
- **White level.** The gain times the full raw's white level less its black, as Redlamp decodes the full raw (at its clip spike, where it has one): where the full raw clips, in the small raw's units. For a body with an sRAW and an mRAW shot at its full raw's settings, the mean of the two, rounded.
- **Prediction.** log2 of the white level over 16383 is how much brighter a small raw renders at 16383 than at its own level, and so how far it renders from its full raw at 16383.
- **Bench.** `redlamp camera-bench --all`, a Release build on an M1 Ultra: the 31 small raws at process 19 and at process 20, and the 16 full raws at process 19, which renders full raws as process 20 does. Its exposure check (`preview.exposure`) compares the midtones of a file's default rendering with its embedded JPEG, in stops; a small raw and its full raw are each judged against their own JPEG, so the difference between their results is how far apart Redlamp renders them.

## The levels

| Body | Full raw | Its white − black | Small raws: getfile, size, gain | White level |
| --- | --- | --- | --- | --- |
| EOS 40D | 2101 | 15200.5 | 2102 sRAW 1.146 | 17421 |
| EOS 50D | 1792 | 12409.25 | 1793 mRAW 1.120, 1794 sRAW 1.130 | 13960 |
| EOS 5D Mark II | 1593 | 14576.25 | 1594 mRAW 1.137, 1595 sRAW 1.143 | 16619 |
| EOS 5D Mark III | 771 | 13416.75 | 772 mRAW 1.153, 773 sRAW 1.175 | 15622 |
| EOS 5D Mark IV | 983 | 15871.5 | 981 sRAW 1.206 | 19147 |
| EOS 5DS | 2083 | 13462 | 2084 mRAW 1.138 | 15313 |
| EOS 5DS R | 2974 | 12687 | 2975 mRAW 1.143, 2976 sRAW 1.147 | 14523 |
| EOS 60D | 993 | 11535.5 | 994 mRAW 1.099, 995 sRAW 1.121 | 12801 |
| EOS 6D | 799 | 13443 | 800 mRAW 1.147, 801 sRAW 1.116 | 15210 |
| EOS 6D Mark II | 1625 | 14046 | 1624 mRAW 1.113, 1623 sRAW 1.195 | 16209 |
| EOS 70D | 784 | 11535 | 785 mRAW 1.049, 786 sRAW 1.033 | 12007 |
| EOS 7D | 131 | 10603.5 | 130 mRAW 1.113, 129 sRAW 1.110 | 11785 |
| EOS 7D Mark II | 1064 | 11537 | 1065 mRAW 1.082, 1066 sRAW 1.144 | 12842 |
| EOS-1D Mark IV | 4258 | 13231.5 | 4259 mRAW 1.149 | 15200 |
| EOS-1D X Mark II | 1058 | 14336 | 1059 mRAW 1.106, 1060 sRAW 1.101 | 15819 |

The gains run from 1.03 to 1.21, and the levels from 11785 (7D) to 19147 (5D Mark IV). Three bodies' levels are above 16383 (the 40D, 5D Mark II and 5D Mark IV), so at 16383 their small raws' brightest values were clamped at white before the data clipped. Where a scene has highlights, a small raw's largest values reach its level or a little past it (the 5D Mark IV's sRAW peaks at 18950 in green, the 7D's at 13579), as values do where a clipped area's YCbCr is converted to RGB; past the level they clip, as the full raw's photosites do.

The prediction held on the bench at process 19: over the 26 small raws shot at their full raw's settings, each file's predicted distance from its full raw (from its own gain) was within 0.05 stops of the measured one at the median, and within 0.14 at worst (the 50D's mRAW).

## The bench at process 20

Each small raw's exposure against its JPEG at processes 19 and 20, its full raw's, and the differences, in stops:

| File | Body | Size | At 19 | At 20 | Full raw | 19 − full | 20 − full |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2102 | EOS 40D | sRAW | +0.01 | −0.11 | −0.09 | +0.10 | −0.02 |
| 1793 | EOS 50D | mRAW | −0.74 | −0.39 | −0.37 | −0.37 | −0.02 |
| 1794 | EOS 50D | sRAW | −0.62 | −0.27 | −0.37 | −0.25 | +0.10 |
| 1594 | EOS 5D Mark II | mRAW | −0.07 | −0.09 | −0.09 | +0.02 | −0.00 |
| 1595 | EOS 5D Mark II | sRAW | −0.07 | −0.09 | −0.09 | +0.02 | −0.00 |
| 772 | EOS 5D Mark III | mRAW | −0.21 | −0.12 | −0.07 | −0.14 | −0.05 |
| 773 | EOS 5D Mark III | sRAW | −0.21 | −0.12 | −0.07 | −0.14 | −0.05 |
| 981 | EOS 5D Mark IV | sRAW | −0.92 | −1.22 | −1.12 | +0.20 | −0.10 |
| 982 | EOS 5D Mark IV | mRAW, other shutter speed | −0.92 | −1.22 | −1.12 | +0.20 | −0.10 |
| 2084 | EOS 5DS | mRAW | −0.44 | −0.30 | −0.29 | −0.15 | −0.01 |
| 2085 | EOS 5DS | sRAW, other aperture | −0.49 | −0.36 | −0.29 | −0.20 | −0.08 |
| 2975 | EOS 5DS R | mRAW | −0.01 | +0.16 | +0.16 | −0.17 | +0.00 |
| 2976 | EOS 5DS R | sRAW | −0.01 | +0.16 | +0.16 | −0.17 | +0.00 |
| 994 | EOS 60D | mRAW | −0.17 | +0.21 | +0.16 | −0.34 | +0.05 |
| 995 | EOS 60D | sRAW | −0.18 | +0.19 | +0.16 | −0.34 | +0.02 |
| 800 | EOS 6D | mRAW | −0.11 | −0.02 | −0.03 | −0.08 | +0.01 |
| 801 | EOS 6D | sRAW | −0.11 | −0.02 | −0.03 | −0.08 | +0.01 |
| 1623 | EOS 6D Mark II | sRAW | −0.06 | −0.04 | +0.00 | −0.06 | −0.04 |
| 1624 | EOS 6D Mark II | mRAW | −0.06 | −0.04 | +0.00 | −0.06 | −0.04 |
| 785 | EOS 70D | mRAW | −0.52 | −0.02 | −0.02 | −0.50 | +0.00 |
| 786 | EOS 70D | sRAW | −0.55 | −0.07 | −0.02 | −0.53 | −0.05 |
| 129 | EOS 7D | sRAW | −0.23 | +0.23 | +0.19 | −0.42 | +0.04 |
| 130 | EOS 7D | mRAW | −0.23 | +0.25 | +0.19 | −0.42 | +0.06 |
| 1065 | EOS 7D Mark II | mRAW | −0.26 | +0.08 | +0.04 | −0.30 | +0.04 |
| 1066 | EOS 7D Mark II | sRAW | −0.26 | +0.07 | +0.04 | −0.29 | +0.03 |
| 1295 | EOS 80D | mRAW, other shutter speed | +0.11 | +0.11 | −0.12 | +0.23 | +0.23 |
| 1296 | EOS 80D | sRAW, other shutter speed | +0.13 | +0.13 | −0.12 | +0.25 | +0.25 |
| 4259 | EOS-1D Mark IV | mRAW | −0.22 | −0.07 | +0.01 | −0.22 | −0.08 |
| 4260 | EOS-1D Mark IV | sRAW, other shutter speed | −0.20 | −0.05 | +0.01 | −0.21 | −0.06 |
| 1059 | EOS-1D X Mark II | mRAW | −0.23 | −0.17 | −0.26 | +0.02 | +0.08 |
| 1060 | EOS-1D X Mark II | sRAW | −0.25 | −0.19 | −0.26 | +0.01 | +0.07 |

Over the 26 small raws of the measured bodies shot at their full raw's settings, a small raw rendered a median 0.17 stops from its full raw at process 19, and 0.53 at worst (the 70D's sRAW); at process 20, a median 0.04 and 0.10 at worst (the 5D Mark IV's sRAW). The three small raws of measured bodies shot at other settings come within 0.11, and the 80D's two, which keep 16383, render as they did. No check failed or warned on any of the 31 at either process. The highlights check (`preview.highlights`) passes on all 18 files with white highlights to compare, with a chroma of 0.2 to 2.5 at process 20, where it was 0.2 to 2.9 at process 19; the other 13 have too few.

## Limits

- Each level comes from one scene of one body, and from LibRaw's conversion as the pinned fork does it (`canon_sraw_load_raw`, which scales by the colour data's small-raw balance): a change to that decoder needs the levels measured again, and the decode goldens of the suite's four Canon small raws would show it.
- A level is green's. Red's and blue's gains agree with green's within 3% on most files, but the 5DS's mRAW's are 0.93 and 0.94 against green's 1.14, and the 70D's and the 7D's mRAW differ by up to 7%; no check of the bench's fails or warns on them.
- Bodies without such a pair keep LibRaw's 16383, the 80D among them, whose small raws were shot at other shutter speeds than its full raw. A pair shot at matching settings measures another body.
