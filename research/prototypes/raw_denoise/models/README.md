# Models for the DN-11 bake-off

Evaluated internally only; none can ship (licences and training data in the
[DN-11 note](../../../../docs/research/notes/DN-11-lightroom-raw-denoise.md#56-licences-of-the-open-models)).
Weights go to `build/proto-data/raw-denoise/models/<name>/`, code to `build/oss/<name>/`. GPL
packages run only as black boxes; their source is not read.

| Model | Code | Weights | Fetch |
| --- | --- | --- | --- |
| RawNIND joint Bayer and linear (Brummer & De Vleeschouwer 2025), darktable-ai's ONNX export | GPL-3.0 (conversion) | GPL-3.0; source checkpoints GPL-3.0 and CC BY 4.0 | `curl -L -o rawdenoise-nind.dtmodel https://github.com/darktable-org/darktable-ai/releases/download/release-5.6.0/rawdenoise-nind.dtmodel`, unzip to `darktable-rawdenoise-nind/unpacked/` |
| demosaicnet Bayer and X-Trans (Gharbi et al. 2016) | MIT | MIT (package files) | `uv pip install demosaicnet==0.0.14 "setuptools<81"` |
| Gharbi et al. 2016 noise-aware Bayer | MIT | MIT | `git clone https://github.com/mgharbi/demosaicnet_caffe build/oss/demosaicnet_caffe`; copy `pretrained_models/bayer_noise` to `demosaicnet/caffe-bayer_noise`; `python models/demosaicnet_noise.py` writes `bayer_noise_from_caffe.pth` |
| Sánchez-Beeckman & Buades 2026 (`rawnoise_25_15_9nbr`) | MIT | not stated (release asset) | clone `MIA-UIB/nonlocal-matchfilter` and `MIA-UIB/deform-neighbourhood-sampling` (v0.1.1, `uv pip install --no-build-isolation --no-deps` builds its CPU kernel); the checkpoint is the v1.0.0 release asset |
| PMRID (Wang et al. 2020) | Apache-2.0 | Apache-2.0 (`models/torch_pretrained.ckp` in the repository) | `git clone https://github.com/MegEngine/PMRID build/oss/PMRID` |

`smoke_models.py` and `nonlocal_matchfilter_smoke.py` check each model on a small synthetic tile.
`stubs/patchmatch` stands in for a CUDA-only package that the Buades networks used here never call.
