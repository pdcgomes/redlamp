import assert from "node:assert/strict";
import { test } from "node:test";
import { parseCameras } from "./cameras.ts";

const doc = `# Cameras

Intro.

<!-- cameras:begin -->
**LibRaw:** 0.22.2

## Verified by the decode tests

| Camera | Format | Sensor | Resolution | Colour reference | Sample |
| --- | --- | --- | --- | --- | --- |
| Sony ILCE-7M3 (A7 III) | ARW | Bayer RGGB | 24 MP | Yes | [_DSC0009.ARW](https://raw.pixls.us/data/Sony/ILCE-7M3/_DSC0009.ARW) |

## Tested with the camera bench

| Camera | Raw mode | Evidence | Photos | Photographers | Problems |
| --- | --- | --- | --- | --- | --- |
| Canon PowerShot A480 (CHDK hack) | 12-bit uncompressed DNG, 3720 × 2772 | Problem found once | 1 | 1 | Edges: Lines at the black level: 12 along the top |
| Nikon Z 7 | 14-bit compressed NEF, 8256 × 5504 | Reported working | 2 | 1 | None |

## In an evaluation set

| Camera | Set | Sample |
| --- | --- | --- |
| Nikon D7500 | Dust evaluation | [D7500.NEF](https://raw.pixls.us/data/Nikon/D7500/D7500.NEF) |

## Supported by LibRaw 0.22.2

### Canon

- PowerShot A480 (CHDK hack) *(problem found once)*

### Nikon

- D7500 *(in an evaluation set)*
- Z 7 *(reported working)*
- Z 6 III (HE/HE* formats are not supported yet)

### Sony

- ILCE-7M3 (A7 III) *(verified)*
<!-- cameras:end -->
`;

test("parseCameras reads the verified, camera bench and evaluation tables, and LibRaw's list by make", () => {
  const cameras = parseCameras(doc);
  assert.equal(cameras.libraw, "0.22.2");
  assert.equal(cameras.fork, null);
  assert.deepEqual(cameras.verified, [
    {
      camera: "Sony ILCE-7M3 (A7 III)",
      format: "ARW",
      sensor: "Bayer RGGB",
      resolution: "24 MP",
      colourReference: true,
      sample: { name: "_DSC0009.ARW", href: "https://raw.pixls.us/data/Sony/ILCE-7M3/_DSC0009.ARW" },
    },
  ]);
  assert.deepEqual(cameras.evaluated.map((row) => [row.camera, row.set]), [["Nikon D7500", "Dust evaluation"]]);
  assert.deepEqual(cameras.bench, [
    {
      camera: "Canon PowerShot A480 (CHDK hack)",
      mode: "12-bit uncompressed DNG, 3720 × 2772",
      evidence: "Problem found once",
      photos: 1,
      photographers: 1,
      problems: "Edges: Lines at the black level: 12 along the top",
    },
    {
      camera: "Nikon Z 7",
      mode: "14-bit compressed NEF, 8256 × 5504",
      evidence: "Reported working",
      photos: 2,
      photographers: 1,
      problems: null,
    },
  ]);
  assert.deepEqual(cameras.makes, [
    { make: "Canon", models: [{ name: "PowerShot A480 (CHDK hack)", mark: "unconfirmed" }] },
    {
      make: "Nikon",
      models: [
        { name: "D7500", mark: "evaluation" },
        { name: "Z 7", mark: "working" },
        { name: "Z 6 III (HE/HE* formats are not supported yet)", mark: null },
      ],
    },
    { make: "Sony", models: [{ name: "ILCE-7M3 (A7 III)", mark: "verified" }] },
  ]);
});

test("parseCameras reads the commit and the fork when LibRaw is built from Redlamp's fork", () => {
  const forked = doc
    .replace("**LibRaw:** 0.22.2", "**LibRaw:** 4abfcd2 ([Redlamp's fork](https://github.com/pdcgomes/redlamp-libraw))")
    .replace("## Supported by LibRaw 0.22.2", "## Supported by LibRaw 4abfcd2");
  const cameras = parseCameras(forked);
  assert.equal(cameras.libraw, "4abfcd2");
  assert.equal(cameras.fork, "https://github.com/pdcgomes/redlamp-libraw");
  assert.equal(cameras.makes.length, 3);
});

test("parseCameras asks for the generator when the LibRaw list is missing", () => {
  assert.throws(() => parseCameras("# Cameras\n"), /scripts\/camera-list\.py --apply/);
});
