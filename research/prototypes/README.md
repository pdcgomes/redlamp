# Research prototypes

Throwaway Python code that backs the measurements in
[docs/research/ai-findings.md](../../docs/research/ai-findings.md) (Appendix C). Nothing here ships in
Redlamp or is linked into the app; the product versions are Swift and Metal.

## Setup

```bash
uv venv --python python3.12 build/research-venv
VIRTUAL_ENV=build/research-venv uv pip install -r research/prototypes/requirements.txt
```

coremltools 9.0 is tested with torch up to 2.7, so torch is pinned.

## Data

Downloaded into `build/proto-data/` (gitignored). Nothing is committed.

| Data | Source | License |
| --- | --- | --- |
| NAFNet-SIDD-width32 weights | [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) (Google Drive link in its README; `gdown 1lsByk21Xw-6aW7epCwOQxvm6HYCQZPHZ`) | Code MIT; weights have no stated license and are trained on SIDD. Used for timing and fidelity only |
| SAM 2.1 tiny Core ML packages | [apple/coreml-sam2.1-tiny](https://huggingface.co/apple/coreml-sam2.1-tiny) | Apache-2.0 |
| PCB focus stacks (`examples/pcb`, `examples/depthmap`) | [PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack) | MIT |
| Mite in Burmese amber, `26E_tubercules_dorsal_100x.zip` (109 frames) | [figshare 10.6084/m9.figshare.14707077](https://doi.org/10.6084/m9.figshare.14707077) | CC BY 4.0 |
| Raw focus stack, Canon EOS R5 Mark II + RF 100 mm macro, 25 of 999 CR3 frames (`focus_stack/fetch_raw_stacks.sh`) | [jjjsood/focus-stack-sample](https://huggingface.co/datasets/jjjsood/focus-stack-sample) (Johannes Sood), revision `0f8256ed` | CC BY 4.0 |

Expected layout: `build/proto-data/NAFNet-SIDD-width32.pth`, `build/proto-data/sam2.1-tiny/`,
`build/proto-data/stacks/{pcb7,pcb10,mite}/`, and `build/proto-data/stacks/pcb_000.JPG` (the test crop
source for the Core ML scripts).

## Scripts

| Script | What it measures |
| --- | --- |
| `coreml/bench_nafnet.py` | Converts NAFNet (sRGB with SIDD weights; raw 4-channel shapes with seeded random weights) to fp16 ML Programs, plus 8-bit and 6-bit palettized and int8 weight variants. Reports latency per compute unit, load time, op placement from `MLComputePlan`, and output fidelity against PyTorch fp32 |
| `coreml/bench_sam21.py` | Apple's SAM 2.1 packages: encoder latency per photo, prompt encoder + mask decoder latency per hover, load and compile times, op placement, embedding cache size |
| `focus_stack/focus_stack.py` | Classical focus stacking: chained ECC alignment, sum-modified-Laplacian focus volume, guided-filter depth solve, streaming Smooth / Detail / Auto fusion |
| `focus_stack/compare.py` | Contact sheet of crops, Tenengrad sharpness, PSNR/SSIM against a reference result |

| `restoration/make_testset.py` | Upscaling and sharpening test set: CC0 fixture renders and a public-domain panel, 512 px ground truth, synthetic downscale, blur, shake and noise degradations with known ground truth, plus native "real" crops |
| `restoration/fetch_models.py` | Downloads the bake-off weights (only models whose terms allow internal evaluation) |
| `restoration/run_bakeoff.py` | Classical baselines, spandrel-loaded upscalers, deblur and face models, InstructIR and a noise-aware sharpen pipeline on PyTorch MPS; wall time per image |
| `restoration/run_vt.py`, `restoration/vt_superres.swift` | Apple's VideoToolbox super-resolution scaler on the same items |
| `restoration/run_s3diff.py` | S3Diff one-step diffusion upscaler (separate pinned environment, see its docstring) |
| `restoration/shp01_calibrate.py` | SHP-01 noise-aware sharpening: the planned GPU algorithm in NumPy over the bake-off set, choosing the separator strength, Richardson–Lucy iterations and Detail blend (`build/proto-out/shp01/summary.md`, `docs/research/images/shp01-calibration.jpg`) |
| `raw_denoise/` | DN-11: Redlamp's noise reduction through its real pipeline (a Swift harness), non-local means on the mosaic before demosaicing, and open raw models, scored on charts with exact truth, binned CC0 photos and RawNIND pairs; its own README has the setup and run order |
| `highlights/` | CAM-31: why clipped skies turn lilac with a cyan band once pulled below white, and the candidate fixes rendered by the engine's prototype branch and scored against unclipped originals; its own README has the setup |
| `thumbnails/libraw_thumbs.cpp`, `thumbnails/run.sh` | Filmstrip thumbnails: ImageIO's thumbnail of the raw file against LibRaw picking the smallest embedded JPEG preview of at least 192 px, per file and as throughput over distinct files on many threads. C++ against the vendored LibRaw, no Python |
| `restoration/score.py` | PSNR, SSIM, LPIPS, DISTS, back-projection consistency, zero-shot CLIP-IQA; summary tables and the contact sheets in `docs/research/images/restoration-*.jpg` |

Outputs go to `build/proto-out/`.

```bash
build/research-venv/bin/python research/prototypes/coreml/bench_nafnet.py
build/research-venv/bin/python research/prototypes/coreml/bench_sam21.py --variant tiny
build/research-venv/bin/python research/prototypes/focus_stack/focus_stack.py \
  build/proto-data/stacks/pcb7 --out build/proto-out/focus/pcb7
build/research-venv/bin/python research/prototypes/focus_stack/compare.py build/proto-out/focus/pcb7 \
  --frames build/proto-data/stacks/pcb7 --reference build/proto-data/stacks/pcb7/expected.jpg \
  --crop 1330,760,360 --crop 1180,300,360 --crop 260,380,360
```

The restoration bake-off uses its own environment (current torch plus spandrel, LPIPS, DISTS and
transformers), because the Core ML scripts pin torch 2.7:

```bash
uv venv --python python3.12 build/restoration-venv
VIRTUAL_ENV=build/restoration-venv uv pip install -r research/prototypes/restoration/requirements.txt
cd research/prototypes/restoration
../../../build/restoration-venv/bin/python make_testset.py   # renders the fixtures with the redlamp CLI
../../../build/restoration-venv/bin/python fetch_models.py
../../../build/restoration-venv/bin/python run_bakeoff.py
../../../build/restoration-venv/bin/python run_vt.py
../../../build/s3diff-venv/bin/python run_s3diff.py            # optional; setup in its docstring
../../../build/restoration-venv/bin/python score.py
```

InstructIR and S3Diff need their repositories cloned into `build/oss/` (see each script's docstring).
The test-set panel images are public domain (NASA) and CC0 Wikimedia Commons files; their URLs and
licences are recorded in `make_testset.py` and the generated `manifest.json`.

Run the Core ML scripts one at a time: running them in parallel skews the timings. The first
Neural Engine load of each model compiles it (seconds for NAFNet, minutes for the SAM encoder); later
processes reuse the OS cache because models are compiled to a stable `.mlmodelc` path.
