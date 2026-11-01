# Models for the DN-11 and DN-17 bake-offs

Evaluated internally only (licences and training data in the
[DN-11 note](../../../../docs/research/notes/DN-11-lightroom-raw-denoise.md#56-licences-of-the-open-models)
and [DN-17's](../../../../docs/research/notes/DN-17-open-raw-denoisers.md#6-licences)).
Weights go to `build/proto-data/raw-denoise/models/<name>/`, code to `build/oss/<name>/`. GPL
packages run only as black boxes; their source is not read.

| Model | Code | Weights | Fetch |
| --- | --- | --- | --- |
| RawNIND joint Bayer and linear (Brummer & De Vleeschouwer 2025), darktable-ai's ONNX export | GPL-3.0 (conversion) | GPL-3.0; source checkpoints GPL-3.0 and CC BY 4.0 | `curl -L -o rawdenoise-nind.dtmodel https://github.com/darktable-org/darktable-ai/releases/download/release-5.6.0/rawdenoise-nind.dtmodel`, unzip to `darktable-rawdenoise-nind/unpacked/` |
| demosaicnet Bayer and X-Trans (Gharbi et al. 2016) | MIT | MIT (package files) | `uv pip install demosaicnet==0.0.14 "setuptools<81"` |
| Gharbi et al. 2016 noise-aware Bayer | MIT | MIT | `git clone https://github.com/mgharbi/demosaicnet_caffe build/oss/demosaicnet_caffe`; copy `pretrained_models/bayer_noise` to `demosaicnet/caffe-bayer_noise`; `python models/demosaicnet_noise.py` writes `bayer_noise_from_caffe.pth` |
| Sánchez-Beeckman & Buades 2026 (`rawnoise_25_15_9nbr`) | MIT | not stated (release asset) | clone `MIA-UIB/nonlocal-matchfilter` and `MIA-UIB/deform-neighbourhood-sampling` (v0.1.1, `uv pip install --no-build-isolation --no-deps` builds its CPU kernel); the checkpoint is the v1.0.0 release asset |
| PMRID (Wang et al. 2020) | Apache-2.0 | Apache-2.0 (`models/torch_pretrained.ckp` in the repository) | `git clone https://github.com/MegEngine/PMRID build/oss/PMRID`; copy the checkpoint to `PMRID/` |
| AutoShade raw denoiser v2 (DN-17) | MIT (skymanbp/autoshade; adapted in `autoshade_raw.py`); KAIR's `network_unet.py` and `basicblock.py` MIT | MIT (the Hugging Face card and LICENSE; the repository's LICENSE) | `autoshade-raw-denoise-v2.pth` from `https://huggingface.co/Azng0/autoshade-mirror-autoshade-raw-denoise` or the v1.6.0 release (130,590,559 bytes, SHA-256 `ffafa40a…f9c4`), and KAIR's two files at the commits `autoshade_raw.KAIR` names, all into `autoshade/` |
| Starfish (DN-17) | Apache-2.0 or MIT (monkeypangit/starfish) | The repository's licence (the weights are repository files) | `training/common.py`, `wgsl.py`, `train_bayer.py`, `train_xtrans.py`, `bayer.pt` and `xtrans.pt` at `b43b610` into `starfish/` |
| RawForge and RawRefinery | MIT | Not stated (release assets) | `run_rawrefinery.py fetch` (checks each file against the author's signature) |

`smoke_models.py` and `nonlocal_matchfilter_smoke.py` check each model on a small synthetic tile.
`stubs/patchmatch` stands in for a CUDA-only package that the Buades networks used here never call.
