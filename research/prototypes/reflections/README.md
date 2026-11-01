# Remove Reflections prototypes (RM-22)

Throwaway Python that backs [docs/research/reflection-removal-findings.md](../../../docs/research/reflection-removal-findings.md): WindowSeat run through MLX on this Mac, the reflection layer subtracted at the photo's full resolution, and the glass benchmark set (INF-14) with its scorer. Nothing here ships in Redlamp or is linked into the app.

| Script | What it does |
| --- | --- |
| `windowseat_mlx.py` | WindowSeat (an Apache-2.0 LoRA on Qwen-Image-Edit-2509) through mflux's MLX ports of the Qwen-Image transformer and VAE: `convert` fuses the LoRA into the base weights and quantises the transformer to 4 or 8 bits, `run` removes reflections at the model's resolution, `bench` times one tile at each size, stage by stage, with MLX's peak memory |
| `windowseat_torch.py` | The same pass through diffusers on PyTorch's Metal backend in bfloat16: the reference the MLX port is checked against |
| `fullres.py` | The full-resolution method: the reflection layer estimated at the model's resolution, corrected for the model's drift in tone and colour, upsampled and subtracted from the full-size photo in linear light, with an Amount |
| `make_glass.py` | The glass set's composites: a CC0 photo plus a reflection made from another CC0 photo in linear light, with the exact truth and reflection layer beside it. `sources.json` lists the photos it is made from |
| `score_glass.py` | PSNR, SSIM and detail PSNR against the truth at full resolution for each method and model variant, written to `research/benchmarks/results/glass-<round>.json`; for the real photos, both methods' results and the blind picks' pairs |
| `glassio.py` | 16-bit TIFF read and write, sRGB and linear light, resizing in linear light, with NumPy and Pillow only |

## Setup

Everything goes in `build/rm22/` (gitignored); delete it when done.

```bash
cd build/rm22
export UV_CACHE_DIR=$PWD/uv-cache HF_HOME=$PWD/hf
uv venv --python python3.12 venv
VIRTUAL_ENV=$PWD/venv uv pip install mflux==0.24.0 diffusers peft accelerate scikit-image scipy pillow safetensors
# The base model's transformer and VAE only (41 GB); WindowSeat needs neither text encoder.
hf download Qwen/Qwen-Image-Edit-2509 --include "transformer/*" --include "vae/*" --include model_index.json --local-dir models/qwen-image-edit-2509
hf download huawei-bayerlab/windowseat-reflection-removal-v1-0 --revision c1f59ca02bff68535c976e5e17147b3d9323309e \
  model_index.json LICENSE.txt transformer_lora/adapter_config.json transformer_lora/pytorch_lora_weights.safetensors \
  text_embeddings/state_dict.safetensors --local-dir models/windowseat
```

The first import of diffusers and transformers can take minutes on a busy disk: transformers 5 reads its whole package tree when it starts. `python -m compileall` over `site-packages/{diffusers,transformers}` first helps. On a GPU other processes are using, MLX evaluates the transformer block by block (`WINDOWSEAT_EVAL_PER_BLOCK=0` turns that off for timing), since macOS cancels a command buffer that runs too long, and a tile that fails or comes back with NaN is run again.

## Run order

From the repository's root, with `PY=build/rm22/venv/bin/python`:

```bash
$PY research/prototypes/reflections/windowseat_mlx.py convert --bits 4 --out build/rm22/windowseat-q4   # 50 s; 13.2 GB
$PY research/prototypes/reflections/windowseat_mlx.py convert --bits 8 --out build/rm22/windowseat-q8   # 21.7 GB
$PY research/prototypes/reflections/windowseat_mlx.py bench --model build/rm22/windowseat-q4 --sizes 512,768,1024 photo.png
$PY research/prototypes/reflections/windowseat_torch.py --size 768 --out-dir build/rm22/out/variants/torch-bf16 photo.png

python3 research/benchmarks/benchmarks.py fetch --set glass --synthetic   # the real photos, then the composites (about 5 minutes)
$PY research/prototypes/reflections/score_glass.py --variants windowseat-q4:768 --ablations --real
$PY research/prototypes/reflections/score_glass.py --variants windowseat-q4:768,windowseat-q8:768,windowseat-q4:512,windowseat-q4:1024
python3 research/benchmarks/picks.py make glass-2026-11-01 --pairs build/rm22/out/glass/pairs.json \
  --question "Which removes the reflection better and keeps more of the photo?" --tags "Reflection left,Soft,Halo,Colour shift,Artefacts"
```

`score_glass.py` keeps each variant's model outputs in `build/rm22/out/glass/` and reuses them, and each run adds its variants to the round's results file, so variants can be scored as their outputs arrive (`--outputs-only` makes the outputs and stops). A variant is `name:size`, or `name:size:scale` to work at `scale` times `size` on the short side in tiles of `size`, nearer the photo's own resolution, as WindowSeat's `--more-tiles` does; `windowseat-bf16:768` builds the bfloat16 model in memory from the base and the LoRA. `fullres.py` runs the full-resolution method on any photo, with `--amount` (−1 gives the reflection alone, as Lightroom's −100 does), `--scale`, and the settings §4 of the findings compares (`--drift`, `--smooth`, `--clip`):

```bash
$PY research/prototypes/reflections/fullres.py --model build/rm22/windowseat-q4 --size 768 --out-dir build/rm22/out/fullres photo.jpg
```

## Licences of what's used

| Component | Licence | Source |
| --- | --- | --- |
| WindowSeat code | Apache-2.0 | [LICENSE.txt](https://github.com/huawei-bayerlab/windowseat-reflection-removal/blob/main/LICENSE.txt) |
| WindowSeat LoRA and prompt embedding | Apache-2.0 | [model card](https://huggingface.co/huawei-bayerlab/windowseat-reflection-removal-v1-0) |
| Qwen-Image-Edit-2509 transformer and VAE | Apache-2.0 | [model card](https://huggingface.co/Qwen/Qwen-Image-Edit-2509) |
| mflux | MIT | [LICENSE](https://github.com/mflux-community/mflux/blob/main/LICENSE) |
| The glass set's photos | CC0, as each Wikimedia Commons file page states | `sources.json`, `research/benchmarks/glass.json` |
