import assert from "node:assert/strict";
import { test } from "node:test";
import { parseCameras } from "./cameras.ts";

const doc = `# Cameras

Intro.

<!-- cameras:begin -->
**LibRaw:** 0.22.2

## Verified by the decode tests

| Camera | Format | Sensor | Colour reference | Sample |
| --- | --- | --- | --- | --- |
| Sony ILCE-7M3 (A7 III) | ARW | Bayer RGGB | Yes | [_DSC0009.ARW](https://raw.pixls.us/data/Sony/ILCE-7M3/_DSC0009.ARW) |

## In an evaluation set

| Camera | Set | Sample |
| --- | --- | --- |
| Nikon D7500 | Dust evaluation | [D7500.NEF](https://raw.pixls.us/data/Nikon/D7500/D7500.NEF) |

## Supported by LibRaw 0.22.2

### Nikon

- D7500 *(in an evaluation set)*
- Z 6 III (HE/HE* formats are not supported yet)

### Sony

- ILCE-7M3 (A7 III) *(verified)*
<!-- cameras:end -->
`;

test("parseCameras reads the verified and evaluation tables, and LibRaw's list by make", () => {
  const cameras = parseCameras(doc);
  assert.equal(cameras.libraw, "0.22.2");
  assert.deepEqual(cameras.verified, [
    {
      camera: "Sony ILCE-7M3 (A7 III)",
      format: "ARW",
      sensor: "Bayer RGGB",
      colourReference: true,
      sample: { name: "_DSC0009.ARW", href: "https://raw.pixls.us/data/Sony/ILCE-7M3/_DSC0009.ARW" },
    },
  ]);
  assert.deepEqual(cameras.evaluated.map((row) => [row.camera, row.set]), [["Nikon D7500", "Dust evaluation"]]);
  assert.deepEqual(cameras.makes, [
    {
      make: "Nikon",
      models: [
        { name: "D7500", mark: "evaluation" },
        { name: "Z 6 III (HE/HE* formats are not supported yet)", mark: null },
      ],
    },
    { make: "Sony", models: [{ name: "ILCE-7M3 (A7 III)", mark: "verified" }] },
  ]);
});

test("parseCameras asks for the generator when the LibRaw list is missing", () => {
  assert.throws(() => parseCameras("# Cameras\n"), /scripts\/camera-list\.py --apply/);
});
