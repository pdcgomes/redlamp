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

Run the Core ML scripts one at a time: running them in parallel skews the timings. The first
Neural Engine load of each model compiles it (seconds for NAFNet, minutes for the SAM encoder); later
processes reuse the OS cache because models are compiled to a stable `.mlmodelc` path.
