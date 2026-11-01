# DN-17: licence requests for two sets of open raw-denoise weights

**Date:** 1 November 2026. **Tracker:** DN-17, DEC-108. **For:** the owner to send; nothing has been sent and no issue has been opened.

Two of the open raw denoisers measured in [DN-17](DN-17-open-raw-denoisers.md) publish their code under MIT but their trained weights as GitHub release assets with no licence of their own (read from GitHub's licence API, the repositories' LICENSE files and the release notes on 1 November 2026). Without a licence, Redlamp can measure them but can't offer them for download. The messages below ask each author whether they would state one. Both say that the training data's terms are a separate question Redlamp is checking itself (DEC-03), so the authors are asked only about what they own.

Where to send them: Sánchez-Beeckman and Buades through a GitHub issue or discussion on [MIA-UIB/nonlocal-matchfilter](https://github.com/MIA-UIB/nonlocal-matchfilter), or by email to the corresponding author named in the paper (arXiv [2604.17453](https://arxiv.org/abs/2604.17453)); Ryan Mueller through a GitHub issue or discussion on [rymuelle/RawForge](https://github.com/rymuelle/RawForge). A public issue leaves the answer where others can find it.

## 1. To the authors of nonlocal-matchfilter (MIA-UIB)

> **Subject:** A licence for the nonlocal-matchfilter checkpoints?
>
> Dear Dr Sánchez-Beeckman and Prof. Buades,
>
> I make Redlamp, an open-source raw photo editor for the Mac (MPL-2.0; https://redlamp.app, https://github.com/pdcgomes/redlamp). We have been measuring open raw denoisers against our own noise reduction, and your learned non-local match-and-filter network (arXiv 2604.17453) was among the strongest we tested on synthetic and real high-ISO raws, with few parameters for its quality.
>
> The code in MIA-UIB/nonlocal-matchfilter is MIT-licensed, but the checkpoints attached to release v1.0.0 don't state a licence of their own. The file we use is `rawnoise_25_15_9nbr.ckpt` (183,578,760 bytes, SHA-256 `b31bc8e21022389b0b209a9d1e6649485ed4dacc552b7ea04612df5f7515fcf2`). Would you be willing to state a licence for the released weights, such as MIT (as for the code), Apache-2.0 or CC BY 4.0? A line in the README or the release notes would be enough.
>
> If you did, we might offer the network in Redlamp as an optional download that the photographer chooses to install, run on their own Mac, and credited to you and the paper in the app and its documentation. Nothing would be sold or sent to a server.
>
> The datasets the network was trained on carry their own terms (RawNIND is CC BY-SA 4.0, and the others vary); that is a separate question, which we are checking ourselves, and we are not asking you to answer it. We are only asking about the weights themselves.
>
> Thank you for publishing the code and checkpoints. Whatever you decide, we will credit the paper in our research notes.
>
> Kind regards,
> [Your name], Redlamp

## 2. To RawForge's author

> **Subject:** A licence for RawForge's released models?
>
> Dear Ryan,
>
> I make Redlamp, an open-source raw photo editor for the Mac (MPL-2.0; https://redlamp.app, https://github.com/pdcgomes/redlamp). We have been measuring open raw denoisers against our own noise reduction, and RawForge's models did well: the joint demosaic-and-denoise model kept the sharpest edges and the most texture of the learned models we tested on synthetic high-ISO raws, and the X-Trans models are among the very few open ones for Fujifilm files.
>
> RawForge's code is MIT-licensed, but the models attached to its releases don't state a licence of their own. The files we use are `DemoRestormerDiT_to_demo_cont_cont_768_RawNIND.pt` (release JDD_v1.0.0) and `restormer.pt` and `xtrans_fixed_exposure_no_conditioning_400.pt` (release xtrans_v1.0.0), each checked against your signatures. Would you be willing to state a licence for the released weights, such as MIT (as for the code), Apache-2.0 or CC BY 4.0? A line in the README or the release notes would be enough.
>
> If you did, we might offer a model in Redlamp as an optional download that the photographer chooses to install, run on their own Mac, and credited to you and RawForge in the app and its documentation. Nothing would be sold or sent to a server.
>
> The models were trained on RawNIND, which is CC BY-SA 4.0; whether that affects a shipped model is a separate question, which we are checking ourselves, and we are not asking you to answer it. We are only asking about the weights you made.
>
> Two things we found while testing, in case they help: the JDD archives were traced on CUDA with `torch.device("cuda:0")` in the rotary embedding, so they don't load on a Mac or a CPU as published; and the JDD model returns NaN in float16 on Apple's GPU with 768-pixel tiles, but not with 512-pixel ones. Our notes on both are public in our repository.
>
> Thank you for RawRefinery and RawForge.
>
> Kind regards,
> [Your name], Redlamp

## What an answer settles

- **A licence that allows redistribution (MIT, Apache-2.0, CC BY 4.0):** the weights move from "no licence" to the licence stated, and the model's verdict in DN-17 §6 depends only on its training data (DEC-03) and on DEC-24's rule.
- **No answer, or no:** the weights stay usable for internal measurement only, as now.
- Either way, record the reply, its date and its link in DN-17 and DEC-108.
