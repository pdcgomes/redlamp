# Clipped highlights (CAM-31)

The measurements behind [the design](../../../docs/plans/2026-10-10-clipped-highlights-design.md): why skies clipped in green and blue turn lilac with a cyan band once they're pulled below white, and how each candidate fix renders them. Nothing here ships.

Two kinds of prototype:

- **A NumPy model of the raw stages** (`cam08.py`): `rl_cfa_normalize`, `HighlightModel.fit` and `rl_cfa_reconstruct_highlights` as on main at process 14, with 2 × 2 or 3 × 3 binning in place of the demosaic. `variants.py` models candidate A, `look.py` gives a quick look close to `rl_develop`'s defaults, and `auto.py` reproduces Auto's values (`ImageAnalysis.autoTone`). Its numbers are marked as the model's in the design.
- **The engine itself**, on the local branch `fix/clipped-highlights-prototype`: the candidates are selected by `REDLAMP_PROTO_HIGHLIGHTS` (`main`, `a` to `e`), `REDLAMP_PROTO_FADE_NEAR=0.9` gives E its final form (the scripts call it `ef`), `REDLAMP_PROTO_RIM_NEAR=0.8` turns E into E8, `REDLAMP_PROTO_OVEREXPOSE=<stops>` overexposes a mosaic and clips it at its white level, and the CLI's `--proto-auto` applies Auto's values as the engine computes them. All pictures and most numbers come from it.

## Running

```bash
uv venv build/highlights-venv
VIRTUAL_ENV=build/highlights-venv uv pip install rawpy numpy scipy tifffile pillow
git switch fix/clipped-highlights-prototype
xcodebuild build -workspace Redlamp.xcworkspace -scheme redlamp -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-highlights
export REDLAMP_CLI=$PWD/build/DerivedData-highlights/Build/Products/Release/redlamp
export HIGHLIGHTS_OUT=$PWD/build/proto-out/highlights PYTHON=$PWD/build/highlights-venv/bin/python
PYTHONPATH=research/prototypes/highlights research/prototypes/highlights/batch.sh
```

`batch.sh` renders each sample with each candidate at the defaults, Highlights −80, Exposure −1.5, Exposure −3 and Auto's values (2048 pixels, 16-bit TIFF), and writes, under `$HIGHLIGHTS_OUT`: `logs/<sample>.txt` with the measurements, `logs/<sample>.truth.txt` for the overexposed samples, and `pictures/<sample>-<setting>.jpg`, a strip of each candidate. `SAMPLES="z8 pixel4a"` runs only those.

| Script | What it does |
| --- | --- |
| `survey.py <raws…>` | Which samples clipped, per class of clipped colours (`CAM08_OVEREXPOSE` for the overexposed ones) |
| `study.py <raw>` | The model's colour per class before and after CAM-08, and the rim it fitted on |
| `explore.py <raw> <name>` | The model's CAM-08 against candidate A, per class, with quick looks |
| `measure.py <raw> <render> [<reference>]` | A render's colour, chroma and hue per class, the edge measure, and the change elsewhere against a reference |
| `compare.py`, `truth.py` | All candidates of one sample against main, or against the unclipped original's render |
