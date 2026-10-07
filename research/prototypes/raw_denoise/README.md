# Raw denoise study (DN-11)

The measurements behind [the DN-11 note](../../../docs/research/notes/DN-11-lightroom-raw-denoise.md):
Redlamp's noise reduction through its real pipeline, a classical denoiser that works on the mosaic
before demosaicing, and open research models, on synthetic scenes with exact truth and on real
RawNIND pairs. Nothing here ships; data and outputs go to `build/proto-data/raw-denoise` and
`build/proto-out/raw-denoise`, and nothing downloaded is committed.

## Setup

Two environments: one for the test set, Redlamp's renders and the scores, one for the models
(PyTorch and onnxruntime).

```bash
uv venv --python python3.12 build/dn11-venv
VIRTUAL_ENV=build/dn11-venv uv pip install -r research/prototypes/raw_denoise/requirements.txt
uv venv --python python3.12 build/rawdn-venv
VIRTUAL_ENV=build/rawdn-venv uv pip install torch numpy scipy onnx onnxruntime omegaconf demosaicnet==0.0.14 "setuptools<81"
```

The models and their code are fetched as `models/README.md` describes. The harness renders through
Redlamp's engine, so it needs a worktree of `main` with the build inputs cloned (`AGENTS.md`), the
harness copied into the engine's test target and the tests built:

```bash
git worktree add --detach ../darkroom-rawdn main   # then clone the build inputs into it
cp research/prototypes/raw_denoise/harness/RawDenoiseHarnessTests.swift ../darkroom-rawdn/packages/RedlampEngine/Tests/
(cd ../darkroom-rawdn && mise exec -- tuist generate --no-open && mise exec -- xcodebuild build-for-testing \
  -workspace Redlamp.xcworkspace -scheme RedlampEngine -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData-rawdn")
```

## Run

From `research/prototypes/raw_denoise`:

```bash
P=../../../build/dn11-venv/bin/python
M="env PYTHONPATH=../../../build/oss/nonlocal-matchfilter/src:models/stubs:models ../../../build/rawdn-venv/bin/python -W ignore"
$P make_testset.py                                     # charts and binned CC0 photos, Bayer and X-Trans, 3 noise levels
$P run_redlamp.py --worktree ../../../../darkroom-rawdn # Redlamp and the pre-demosaic prototype
$M run_models.py synthetic                             # open models; Buades and PMRID write mosaics for the harness
$P -c "import os; from run_redlamp import run; from common import OUT; run(OUT/'models-harness', os.path.abspath('../../../../darkroom-rawdn'))"
$P fetch_rawnind.py && $P real_pairs.py prepare && $P real_pairs.py run --worktree ../../../../darkroom-rawdn
$M run_models.py real
$P -c "import os; from run_redlamp import run; from real_pairs import REAL; run(REAL/'models-harness', os.path.abspath('../../../../darkroom-rawdn'))"
$P score.py && $P analyze.py && $P real_pairs.py score && $P figures.py
```

| Script | What it does |
| --- | --- |
| `common.py` | CFA tiles, noise levels, file layout |
| `make_testset.py` | Charts rendered at 4x through a lens blur and pixel aperture; CC0 raws binned to full colour; mosaics with exact Poisson–Gaussian noise |
| `harness/RawDenoiseHarnessTests.swift` | Renders queued mosaics through `SessionBuilder` and `DetailStage`, writing balanced camera RGB |
| `prototype.py` | Non-local means on the mosaic, between patches of the same CFA phase, with distances scaled by the noise model |
| `run_redlamp.py` | Prototype mosaics, harness jobs for Redlamp's settings, and the harness run |
| `run_models.py` | RawNIND (joint and linear), Gharbi's noise-aware joint model and demosaicnet, Buades 2026, PMRID, each with its own input conventions |
| `fetch_rawnind.py`, `real_pairs.py` | A RawNIND subset; crops, exposure matching and fitted noise profiles; scores at full resolution and binned |
| `score.py`, `analyze.py` | Fidelity, texture, slanted-edge MTF50, false colour, flat noise, shadow cast; `summary.md` |
| `figures.py` | The note's figures, from CC0 and synthetic sources only |
| `run_rawrefinery.py` | RawRefinery's and RawForge's models (the [RawRefinery study](../../../docs/research/rawrefinery-findings.md)): fetched and checked against the author's signatures, run with the inputs RawForge gives them, on both test sets; float16, conditioning and the study's figures |
| `models/` | The port of Gharbi's noise-aware Caffe model, smoke tests for every model, and an import stub for a CUDA-only package |
