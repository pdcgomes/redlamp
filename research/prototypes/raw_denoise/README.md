# Raw denoise study (DN-11, DN-17)

The measurements behind [the DN-11 note](../../../docs/research/notes/DN-11-lightroom-raw-denoise.md)
and [DN-17's](../../../docs/research/notes/DN-17-open-raw-denoisers.md): Redlamp's noise reduction
through its real pipeline, a classical denoiser that works on the mosaic before demosaicing, and open
models (DN-17: AutoShade v2, Buades 2026, RawForge, PMRID and Starfish), on synthetic scenes with exact
truth and on real RawNIND pairs, with float16, Core ML and 24 MP timings for the open models. Nothing
here ships; data and outputs go to `build/proto-data/raw-denoise` and `build/proto-out/raw-denoise`,
and nothing downloaded is committed.

## Setup

Two environments: one for the test set, Redlamp's renders and the scores, one for the models
(PyTorch and onnxruntime).

```bash
uv venv --python python3.12 build/dn11-venv
VIRTUAL_ENV=build/dn11-venv uv pip install -r research/prototypes/raw_denoise/requirements.txt
uv venv --python python3.12 build/rawdn-venv
VIRTUAL_ENV=build/rawdn-venv uv pip install torch numpy scipy onnx onnxruntime omegaconf demosaicnet==0.0.14 "setuptools<81"
# DN-17's Core ML check only: coremltools 9.0 supports torch up to 2.7
uv venv --python python3.12 build/coreml-venv
VIRTUAL_ENV=build/coreml-venv uv pip install coremltools==9.0 torch==2.7.0 numpy scipy
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

DN-17's round, with the same environments (`--no-prototype` leaves out DN-11's classical prototype and
Malvar renders; `run_models.py` without `--models` runs DN-17's candidates):

```bash
$P make_testset.py && $P run_redlamp.py --worktree ../../../../darkroom-rawdn --no-prototype
$M run_models.py synthetic                             # AutoShade (with and without its noise field), Buades, PMRID, Starfish
$P -c "import os; from run_redlamp import run; from common import OUT; run(OUT/'models-harness', os.path.abspath('../../../../darkroom-rawdn'))"
../../../build/rawdn-venv/bin/python run_rawrefinery.py fetch && ../../../build/rawdn-venv/bin/python run_rawrefinery.py synthetic
$P fetch_rawnind.py && $P real_pairs.py prepare --no-prototype && $P real_pairs.py run --worktree ../../../../darkroom-rawdn
$M run_models.py real
$P -c "import os; from run_redlamp import run; from real_pairs import REAL; run(REAL/'models-harness', os.path.abspath('../../../../darkroom-rawdn'))"
../../../build/rawdn-venv/bin/python run_rawrefinery.py real
$P score.py && $P real_pairs.py score
$P dn17_report.py --results ../../benchmarks/results/denoise-open-models-2026-11-01.json
$M fp16_timing.py prepare
for m in autoshade jdd starfish buades; do $M fp16_timing.py fp16 $m; done   # float16 against float32
for m in autoshade starfish jdd buades; do $M fp16_timing.py time $m; done   # a 24 MP photo, one model per process
../../../build/coreml-venv/bin/python fp16_timing.py coreml autoshade      # the Neural Engine
```

`make_benchmark.py` writes the benchmark set's synthetic cases as DNGs (INF-14,
`research/benchmarks/denoise.json`); `python3 research/benchmarks/benchmarks.py fetch --set denoise
--synthetic` runs it for every case.

| Script | What it does |
| --- | --- |
| `common.py` | CFA tiles, noise levels, file layout |
| `make_testset.py` | Charts rendered at 4x through a lens blur and pixel aperture; CC0 raws binned to full colour; mosaics with exact Poisson–Gaussian noise |
| `harness/RawDenoiseHarnessTests.swift` | Renders queued mosaics through `SessionBuilder` and `DetailStage`, writing balanced camera RGB |
| `prototype.py` | Non-local means on the mosaic, between patches of the same CFA phase, with distances scaled by the noise model |
| `run_redlamp.py` | Prototype mosaics, harness jobs for Redlamp's settings, and the harness run |
| `run_models.py` | RawNIND (joint and linear), Gharbi's noise-aware joint model and demosaicnet, Buades 2026, PMRID, AutoShade v2 and Starfish, each with its own input conventions |
| `models/autoshade_raw.py` | AutoShade's raw sidecar, adapted (MIT, with attribution): the transform per colour plane, its noise field and blind noise model, DRUNet on the two triplets, the exact inverse |
| `dn17_report.py` | DN-17's tables (`dn17-summary.md`), and the per-case results file for `research/benchmarks/results/` |
| `fp16_timing.py` | Float16 against float32 at 256, 512 and 768 px tiles (MPS; Buades on the CPU), Core ML on the Neural Engine, and a 24 MP photo's time and peak memory |
| `make_benchmark.py` | The benchmark set's synthetic cases as DNG 1.4 CFA files (noisy, clean) and their full-colour truth |
| `fetch_rawnind.py`, `real_pairs.py` | A RawNIND subset; crops, exposure matching and fitted noise profiles; scores at full resolution and binned |
| `score.py`, `analyze.py` | Fidelity, texture, slanted-edge MTF50, false colour, flat noise, shadow cast, the fine-text panel; `summary.md` |
| `figures.py` | The note's figures, from CC0 and synthetic sources only |
| `run_rawrefinery.py` | RawRefinery's and RawForge's models (the [RawRefinery study](../../../docs/research/rawrefinery-findings.md)): fetched and checked against the author's signatures, run with the inputs RawForge gives them, on both test sets; float16, conditioning and the study's figures |
| `models/` | The port of Gharbi's noise-aware Caffe model, smoke tests for every model, and an import stub for a CUDA-only package |
