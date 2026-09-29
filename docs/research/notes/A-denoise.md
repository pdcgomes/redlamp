# Workstream A: Denoise — research notes

**Date checked:** 2026-09-29 (all URLs below fetched on this date unless marked otherwise).
**Scope:** brief section 3.A (classical and AI denoise, noise modeling, data, integration, evaluation).
**Conventions:** see `_conventions.md`. "Evidence:" = sourced; "Assessment:" = our judgement.

**What I could not verify on this pass:** patent databases (Google Patents, Justia, Espacenet, USPTO PPUBS) all refused automated access from this environment (HTTP 403/503), so every patent statement below is either from a primary document that names the patent or is explicitly marked unverified. Adobe HelpX (Lightroom help pages, DNG 1.7 spec on HelpX) returned HTTP 403; I used the Adobe blog, the DNG 1.6.0.0 spec (mirrored PDF) and the Redlamp parameter spec instead. DxO pages returned 403 directly and were read through a text proxy (`r.jina.ai`). RENOIR and the Nam (cross-channel) dataset sites were unreachable.

---

## 0. Summary of recommendations

1. **Classical (Phase 2): build** a noise-profiled, multi-scale denoiser in Metal: a decimated Laplacian-pyramid shrinkage for luma plus a luma-guided multi-scale chroma filter, driven per pixel by a Poisson–Gaussian noise model, running in camera-linear RGB after demosaicing and before highlight reconstruction and the color matrix. Add an optional "HQ" patch-based pass (non-local means on the two finest scales) for 1:1 and export. Do **not** build BM3D as the interactive path (cost, GPU-unfriendly grouping, restrictive reference code, patent status unverified). Estimated cost at 24 MP: fast path about 40 ms on base M1, HQ path about 100–200 ms (Assessment, section 1.4). Effort about 15–18 engineer-weeks, including calibration tooling.
2. **Pre-demosaic "sensor cleanup" stage (Phase 2): build.** Hot and dead pixels, row and column banding, black-level and color-bias correction, optional dark-shading subtraction. It is not slider-driven, so it is cached with the demosaic.
3. **Noise profiles: build** a three-source cascade: the DNG `NoiseProfile` tag (51041) when present, then Redlamp's calibrated per-camera profile (parametric, about 5 KB per camera), then single-image blind estimation. The calibration protocol (bias frames plus flat-field photon-transfer series per ISO) is in section 4.
4. **AI (Phase 3): train our own.** Nothing off the shelf is simultaneously raw-domain, trained on commercially usable data, and suitable for large-sensor cameras. Adopt the **NAFNet** architecture family (MIT; conv-only; best quality per MAC among permissive options; raw variant already demonstrated in the NAFNet paper), train it raw→raw on packed Bayer with a k-sigma/variance-stabilizing input transform and a noise-level map, on synthetic noise over clean raws we have rights to (raw.pixls.us CC0, self-shot, and possibly RawNIND CC-BY-SA pending legal review). X-Trans v1 goes through a linear-RGB model after demosaicing. Effort about 24–30 engineer-weeks plus roughly USD 5–20k of training compute (Assessment).
5. **Integration:** non-destructive stage with cached output (model id and version in the recipe), a deterministic image-aligned tile grid so a 1:1 loupe preview equals the final result, the Amount slider as a live blend over the cached output, and an optional "bake to DNG" export. Do not make DNG baking the primary workflow, as Adobe does.
6. **Neural Engine timing prototype:** convert **NAFNet-SIDD-width32** (MIT) to Core ML now. Its weights are a single Google Drive file linked from the official README, and there is an MIT-labelled Hugging Face mirror of width64. Separately convert **PMRID** (Apache-2.0; 4 MB weights in-repo) as the lower-bound raw baseline. Details in section 7.5.

---

## 1. Classical state of the art for an interactive GPU denoiser

### 1.1 Methods

**BM3D / BM3D-CFA (collaborative filtering).** BM3D groups similar blocks into 3D stacks, applies a 3D transform with shrinkage (hard threshold, then empirical Wiener), and aggregates the results (Dabov, Foi, Katkovnik, Egiazarian, IEEE TIP 2007, DOI 10.1109/TIP.2007.901238). BM3D-CFA applies the same idea to raw CFA data by matching blocks that share the same CFA phase (Danielyan et al., "Cross-color BM3D filtering of noisy raw data", LNLA 2009, DOI 10.1109/LNLA.2009.5278395).
- Evidence (quality): on the Darmstadt raw benchmark, BM3D+VST scores 47.15 dB raw PSNR and 37.86 dB sRGB, at a tabulated runtime of 6,900 ms, against 48.89 dB and 22 ms for Brooks et al.'s learned raw model (Unprocessing, arXiv 1811.11127, Table 1, numbers taken from the DND benchmark site). So BM3D is the strongest classical baseline in that table, and still more than 1.7 dB behind a small CNN.
- Evidence (license): the reference implementation (v4.0.3) is "available exclusively for non-profit education and scientific research. Any unauthorized use ... for industrial or profit-oriented activities is expressively prohibited" (https://webpages.tuni.fi/foi/GCF-BM3D/, legal notice at `/legal_notice.html`: "reproduction, use, and modification are for informational and having non-commercial scope only"). PyPI `bm3d` is classified "License :: Free for non-commercial use". The IPOL re-implementation (Lebrun 2012, https://www.ipol.im/pub/art/2012/l-bm3d/) is GPL-3.0-or-later, so it is **Avoid**. A clean-room implementation from the paper would be required.
- **Patent status: UNVERIFIED.** The brief says BM3D was patented by Tampere / Noiseless Imaging. I could not reach any patent database to confirm numbers. Assessment: BM3D was publicly disclosed in 2006–2007, so any patent must have a priority date of about 2006–2007, and a 20-year term would end around 2026–2027 (later if there were term adjustments or later continuations). **Action:** commission a freedom-to-operate (FTO) search before shipping anything BM3D-like.
- Assessment (GPU): data-dependent grouping (per-reference top-k search plus sorting), variable stack sizes and scatter-add aggregation make BM3D memory-bound and divergent on GPUs. It is at least an order of magnitude costlier than pyramid shrinkage for a modest quality gain once a good noise model is in place. Verdict: not the interactive path; possibly an export-only mode later.

**Non-local means (NLM) and fast variants.** Buades, Coll and Morel, CVPR 2005 (DOI 10.1109/CVPR.2005.38). Fast NLM with integral images makes the cost per pixel proportional to the search-window size, independent of patch size (Darbon et al., ISBI 2008, DOI 10.1109/ISBI.2008.4541250).
- Evidence (patent): IPOL's NLM article states that some files "use algorithms possibly linked to patent [3]", citing "A. Buades, B. Coll, J.M. Morel, 'Image data processing method by reducing image noise, and camera integrating means for implementing said method', EP Patent 1,749,278 (Feb. 7), 2007" (https://www.ipol.im/pub/art/2011/bcm_nlm/article.pdf). Assessment: the EP publication is from 2007, so its filing was about 2005 and the 20-year term has lapsed or is lapsing. US counterparts are unverified; include them in the FTO check. The IPOL code is GPL, so **Avoid** it and implement from the paper.
- In products: darktable's "denoise (profiled)" offers NLM and wavelet modes on profiled Poisson–Gaussian noise (https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/denoise-profiled/). That is product precedent, but darktable is GPL, so its code must not be read.

**Wavelet and multi-scale shrinkage.** BLS-GSM (Portilla et al., TIP 2003, DOI 10.1109/TIP.2003.818640) and bivariate (parent–child) shrinkage (Sendur & Selesnick, TSP 2002, DOI 10.1109/TSP.2002.804091) are the canonical designs. darktable's default profiled mode is wavelets: "Wavelet decomposition allows you to adjust the denoise strength depending on the coarseness of the noise", and "the wavelet algorithm is less resource-intensive than non-local means" (darktable manual, above). Assessment: this is the best fit for a <16 ms slider, because the cost is a few passes over a pyramid (1.33× the pixels, decimated) and the per-band thresholds map naturally onto Lightroom-style "Detail" and "Smoothness" controls (section 3).

**Guided and bilateral hybrids.** Bilateral filter (Tomasi & Manduchi, ICCV 1998, DOI 10.1109/ICCV.1998.710815). Bilateral grid (Chen, Paris & Durand, SIGGRAPH 2007, DOI 10.1145/1276377.1276506). Guided filter (He, Sun & Tang, TPAMI 2013, DOI 10.1109/TPAMI.2012.213). Assessment: the guided filter is ideal for **chroma** denoising with luma as the guide: an O(1) box-filter cost, edge-following, and no staircasing. **Guided-filter patent status: UNVERIFIED** (patent databases unreachable). If the FTO check finds a live patent, a joint-bilateral or bilateral-grid chroma filter is a drop-in alternative; both are published methods from 1998 and 2007.

**Variance-stabilizing transforms.** For Poisson–Gaussian data, the generalized Anscombe transform (GAT) makes the noise approximately unit-variance Gaussian, and exact unbiased inverses matter at low counts (Makitalo & Foi, TIP 2011, DOI 10.1109/TIP.2010.2056693; TIP 2013, DOI 10.1109/TIP.2012.2202675). HDR+ explicitly chose *not* to use a VST in its DFT domain. Instead it approximates the noise as locally constant per 16×16 tile, evaluated at the tile's RMS signal, "for computational efficiency" (Hasinoff et al., SIGGRAPH Asia 2016, DOI 10.1145/2980179.2980254; paper at https://hdrplusdata.org/hdrplus.pdf). A recent paper shows GAT fitting is brittle in blind use and proposes robust per-CFA-plane fitting (RPG-VST, arXiv 2607.24291). Assessment: use a per-pixel σ(x) from the model evaluated on a local low-pass signal estimate, as HDR+ does, for the interactive path. Use GAT only where a method assumes stationary Gaussian noise (the NLM HQ pass and the AI input normalization).

**Real-time systems built on these ideas (Google).**
- HDR+ (Hasinoff et al. 2016). Noise variance is modelled as σ² = Ax + B, with A and B depending on analog and digital gain. Temporal merge is pairwise Wiener-like shrinkage in the 2D DFT domain on 16×16 tiles (32×32 for very dark scenes) of each Bayer plane. Spatial denoising is a separate post-process: "pointwise shrinkage operator, of the same form as equation 7, to the spatial frequency coefficients", with noise variance σ²/N and a hand-tuned "noise shaping" function f(ω) that increases the effective σ at high frequencies. The whole pipeline ran in about 4 s for 12 MP on a 2016 phone, with alignment at 24 ms/Mpix (paper, §5–6).
- Night Sight (Liba et al., arXiv 1910.11336) extends HDR+ with motion-adaptive "mismatch maps", spatially varying merge, and "increasing spatial denoising where merging was limited", with processing "under 2 seconds" on a phone.
- Assessment: the HDR+ spatial stage (overlapping DFT tiles plus Wiener shrinkage with frequency-dependent noise shaping) is a strong single-image option on GPU (vDSP/MPS FFTs or a hand-written 16×16 FFT kernel). It is also the natural stepping stone to burst merge later. Patent status for HDR+ merge techniques is **UNVERIFIED**, so include it in the FTO check.

### 1.2 Evidence summary: learned vs classical

| Method | Benchmark | Result | Source |
|---|---|---|---|
| BM3D + VST | DND raw / sRGB | 47.15 / 37.86 dB, 6.9 s | arXiv 1811.11127 Table 1 |
| Brooks et al. (raw CNN) | DND raw / sRGB | 48.89 / 40.17 dB, 22 ms | same |
| Same CNN, "noise-blind" ablation | DND raw | 48.51 dB | same (shows value of feeding the noise level) |
| BM3D | SIDD sRGB | 25.65 dB | Restormer arXiv 2111.09881 Table 6 (Assessment: not a fair classical setting) |

Assessment: classical methods remain the right tool for an **interactive, parameterized** control. AI wins on absolute quality by 1–2+ dB, which is why the brief asks for both.

### 1.3 Recommended classical method ("Redlamp NR v1")

1. **Input:** demosaiced camera-linear RGB (pre-matrix, pre-HLR) at the pyramid level being displayed; per-channel Poisson–Gaussian parameters (a_c, b_c), corrected for the variance reduction and correlation introduced by the specific demosaic algorithm (measured once per algorithm and CFA type by demosaicing synthetic noise); and a clip mask.
2. **Decorrelate:** convert to an opponent space in the white-balanced linear domain (Y, C1 = R−G, C2 = B−G, or an orthonormal variant). Propagate σ²(x) through the linear transform per pixel.
3. **Luma:** build a decimated Laplacian pyramid with 5–6 levels. For each band j, compute σ_j(x) = η_j · σ_Y(x̂), where x̂ is the low-pass signal and η_j is the filter-bank gain (precomputed). Apply Wiener/garrote shrinkage w' = w · max(0, 1 − (T_j σ_j)² / w²), with a parent–child (bivariate) term for robustness.
4. **Chroma:** apply a guided filter per pyramid level, with the same-level luma as the guide and ε tied to σ at that level. It is strongest at coarse levels, where chroma blotches live.
5. **HQ pass** (1:1 and export only): replace the two finest luma bands with GAT → NLM (5×5 patches, 11×11 search) → exact inverse GAT, or the HDR+-style 16×16 DFT Wiener with 50% overlap.
6. **Clipped samples** (per-channel, at white level) get zero weight in the filters and pass through unchanged, so highlight reconstruction receives honest data (Foi, "Clipped noisy images", Signal Processing 2009, DOI 10.1016/j.sigpro.2009.04.035, models the bias that clipping introduces).

### 1.4 GPU cost estimates (Assessment)

Assumptions: RGBA16F (8 B/pixel), bandwidth-bound kernels, M1 GPU 2.6 TFLOPS (Apple, https://www.apple.com/newsroom/2020/11/apple-unleashes-m1/), M1 Ultra 800 GB/s (https://www.apple.com/newsroom/2022/03/apple-unveils-m1-ultra-the-worlds-most-powerful-chip-for-a-personal-computer/). The base-M1 bandwidth of about 68 GB/s is commonly reported but was **not verified** here.

| Path | Work | Base M1 | M1 Ultra |
|---|---|---|---|
| Fast path, screen-resolution viewport (≈6 MP) | ≈7 full-res-equivalent passes × 48 MB ≈ 0.33 GB for luma, similar for chroma | ≈8–10 ms | ≈1–2 ms |
| Fast path, 24 MP export | ≈4× the above | ≈35–45 ms | ≈4–6 ms |
| HQ NLM on 2 finest luma bands, 24 MP | ≈6 kFLOP/px ≈ 150 GFLOP (brute force); ≈25 GFLOP with integral images | ≈60–120 ms | ≈10–20 ms |
| BM3D (for comparison) | grouping-dominated, divergent | seconds (CPU reference: 6.9 s per DND image, above) | n/a |

At zoom levels below 100%, the fast path runs on the matching mip level with σ rescaled for that level's downsampling, so the preview stays well under 16 ms. The 1:1 view is the "truth" and is computed on visible tiles. This meets both brief targets: slider to screen under 16 ms, and full-res export in hundreds of ms. Numbers must be confirmed with a Metal prototype on the M1 Ultra test machine.

---

## 2. Raw (CFA) vs linear-RGB denoising, and pipeline placement

**Evidence**
- BM3D-CFA and later work argue for denoising *before* demosaicing, because demosaicing spatially correlates noise and makes it signal- and color-dependent (Danielyan et al. 2009). Joint demosaic+denoise networks outperform sequential pipelines (Gharbi et al., "Deep joint demosaicking and denoising", SIGGRAPH Asia 2016, DOI 10.1145/2980179.2982399).
- RawNIND (Brummer & De Vleeschouwer, arXiv 2501.08924): "The performance of Bayer and linear RGB models was comparable, with Bayer models achieving a significant edge in computational efficiency by processing four-channel Bayer data at reduced spatial dimensions ... reduces the computational complexity by a factor of 4." Both beat models trained on developed images.
- Adobe Denoise does joint demosaic+denoise from raw: "our models are designed and trained to perform both demosaicing and denoising in a single step", supported "only for Bayer and X-Trans mosaic raw files", output as a new DNG (Eric Chan, https://blog.adobe.com/en/publish/2023/04/18/denoise-demystified).
- DxO: "DeepPRIME XD3 ... for Bayer and X-Trans sensors ... at the cutting edge of demosaicing and denoising"; DeepPRIME 3 also adds chromatic aberration correction in the raw conversion (https://www.dxo.com/technology/deepprime/, via text proxy).
- darktable (development manual, "neural restore"): "Bayer sensors are denoised directly on the CFA mosaic, with denoise and demosaic combined into a single inference pass ... X-Trans sensors ... are demosaicked first ..., then the AI denoiser operates on the resulting linear Rec.2020 RGB image. The result is saved as a LinearRaw DNG." (https://docs.darktable.org/usermanual/development/en/module-reference/utility-modules/shared/neural-restore/)
- darktable places profiled denoise "before the input color profile module ... so that the profile parameters are accurate" (darktable manual).

**Assessment: interactions**
- **Demosaic.** Gradient- and direction-deciding demosaics (RCD, AMaZE, Markesteijn) make noise-driven decisions at high ISO, producing maze and zipper artifacts. MHC is linear, so it is less sensitive but leaves colored noise. A light, slider-independent CFA pre-clean (hot pixels, banding) helps every demosaic. Strong denoise before a directional demosaic helps most, and that is exactly what the AI raw→raw stage provides.
- **Highlight reconstruction.** Denoise before HLR, with a clip mask. After HLR the reconstructed regions have no noise model, and denoising clipped pixels pulls them below white, which produces magenta casts (Foi 2009).
- **Sharpening.** Sharpening must run after denoise. Its masking should use the same noise model (lower gain where local SNR is low). With AI denoise on, default sharpening should be re-tuned, because AI output is already crisp and sharpening amplifies residual artifacts. Adobe suggests Grain for over-smooth results (Adobe blog), and Redlamp already has Grain.

**Recommended placement**

```text
LibRaw unpack → black level / linearize → [Sensor cleanup: hot/dead px, row/col banding, color-bias, (opt) dark shading]   (cached)
             → [AI raw→raw denoise (Bayer), optional, cached per model version]
             → demosaic (MHC → RCD/AMaZE/Markesteijn) → mip pyramid                                                        (cached)
             → [Classical NR v1 in camera-linear RGB, per displayed level; clip-mask aware]                                (live)
             → highlight reconstruction → camera matrix → Rec.2020 linear → capture sharpening → edits
X-Trans + AI (v1): demosaic → [AI linear-RGB denoise (camera RGB, pre-matrix)] → continue as above
```

Rationale for keeping classical NR post-demosaic: it keeps the <16 ms slider (demosaic stays cached), works identically for Bayer, X-Trans and linear DNG (ProRAW), and the error from demosaic-correlated noise is absorbed by the per-algorithm (a_c, b_c) correction.

---

## 3. Mapping Lightroom's Detail panel onto NR v1

Redlamp already defines Lightroom-compatible ranges and defaults (`packages/RedlampEngineAPI/Sources/ParameterSpec.swift`):

| Control | Default |
|---|---|
| Luminance | 0 |
| Luminance Detail | 50 |
| Luminance Contrast | 0 |
| Color | 25 |
| Color Detail | 50 |
| Color Smoothness | 50 |

Adobe's help pages were unreachable (HTTP 403), so the semantics below come from how the Lightroom UI behaves and should be re-checked against HelpX.

Let L = Luminance/100, Ld = LumDetail/100, Lc = LumContrast/100, C = Color/100, Cd = ColorDetail/100, Cs = ColorSmoothness/100. Luma bands run from j = 1 (finest) to J = 5 or 6.

| Lightroom control | Semantics (Lightroom) | NR v1 mapping (proposal) |
|---|---|---|
| Luminance (Amount) | overall luma NR strength | Threshold multiplier k = k_max · L^γ, with γ ≈ 0.7 for perceptual spacing and k_max ≈ 3 (units of σ_j). Zero bypasses luma NR entirely. |
| Luminance Detail | higher keeps more fine detail and noise | Fine-band protection: T_1 ← k·(1 − 0.6·Ld), T_2 ← k·(1 − 0.4·Ld). Also sets edge protection in the bivariate term: parent weight ∝ Ld. |
| Luminance Contrast | higher preserves mid-frequency contrast and texture, at the risk of mottling | Mid bands j = 2–4: T_j ← T_j·(1 − 0.5·Lc), plus texture re-injection w'' = w' + 0.3·Lc·(w − w')·coherence(x), where coherence comes from the structure tensor. |
| Color (Amount) | chroma NR strength | Guided-filter strength on C1/C2: ε_l = (C·c_max·σ_l)², applied at all chroma levels. Zero bypasses chroma NR. |
| Color Detail | higher keeps small colored details, at the risk of color speckles | Finest 2 chroma levels: blend between filtered and unfiltered by α = 1 − 0.7·Cd. Also scales the guide sharpness (smaller ε at high Cd). |
| Color Smoothness | higher removes larger, low-frequency color mottling | Number and weight of coarse chroma levels processed: weights for levels l ≥ 3 ∝ Cs. At Cs = 1, add an extra 1/64-scale level. |

Calibration target (Assessment): tune k_max, c_max and γ so that default Color = 25 on a mid-ISO file removes chroma blotches without visible desaturation of small colored details, and so that Luminance 30–50 on ISO 6400 files is judged "close to Lightroom manual NR" in the A/B harness (section 8). Keep the mapping in one versioned table (`nrMappingVersion` in the recipe), so tuning changes never alter old edits.

---

## 4. Noise modeling and calibration

### 4.1 Models

- **Poisson–Gaussian (heteroscedastic).** Var[z(x)] = a·x + b per CFA channel, with clipping handled explicitly, fitted from a single raw image by segmenting smooth regions in the wavelet domain and running a maximum-likelihood fit (Foi, Trimeche, Katkovnik & Egiazarian, TIP 2008, DOI 10.1109/TIP.2008.2001399). Foi's MATLAB code (`ClipPoisGaus_stdEst2D`) is TUT-limited, non-commercial (https://webpages.tuni.fi/foi/sensornoise.html), so implement from the paper.
- **Physics-based ELD model.** D = K(I + N_p) + N_o, where N_o combines read noise (Tukey-lambda rather than Gaussian), **row noise**, **color-biased read noise** (a DC offset per channel) and quantization noise. K (system gain) is estimated from flat-field frames; the other parameters come from bias frames. Log-linear joint distributions of (K, σ) across ISO let unseen ISOs be interpolated (Wei et al., CVPR 2020, arXiv 2003.12751; TPAMI extension, arXiv 2108.02158, §3.2). The authors withheld their own calibration code: "Due to the business license, we are unable to provide the noise model as well as the calibration method" (https://github.com/Vandermode/ELD README).
- **Dark-frame sampling.** "Rethinking Noise Synthesis and Modeling in Raw Denoising" (Zhang et al., ICCV 2021, arXiv 2110.04756) synthesizes signal-independent noise by *sampling real dark frames* (pattern-aligned patch sampling, high-bit reconstruction), and models signal-dependent noise only as shot noise. Code is MIT (https://github.com/zhangyi-3/Noise-Synthesis). This technique captures FPN and banding for free.
- **PNNP** (Feng et al., arXiv 2310.09126) decouples dark-frame noise into frame-wise, band-wise and pixel-wise components, with a learned 1×1-conv proxy for the pixel-wise part. Code is Apache-2.0 (https://github.com/fenghansen/PNNP).
- **Noise Flow** (Abdelhamed et al., ICCV 2019, arXiv 1908.08453) is a conditional normalizing flow trained on SIDD. Its code is **CC BY-NC-SA 4.0** (https://github.com/BorealisAI/noise_flow LICENSE), so **Avoid** it. LED's Table 1 (arXiv 2308.03448) shows Noise Flow-based synthesis (37.02 dB at SID ×100) well below ELD calibration (41.83 dB) and LED (41.98 dB).
- **"Noise modeling in one hour"** (Sony Research, arXiv 2505.00045, MIT code at https://github.com/SonyResearch/raw_image_denoising) removes the system-gain calibration and signal-independent profiling steps and reports up to +0.54 dB over the prior best synthesis. This is relevant for scaling calibration to many cameras.
- **Color bias.** Black-level error causes color shifts in low light. Mohammadi et al. (ICCP 2026, arXiv 2607.11090) predict it with a small network and report that SIDD ground truth "contains significant color bias". Redlamp should estimate black level per channel from optical-black or masked pixels when LibRaw exposes them, and fit residual bias in the sensor-cleanup stage.
- **Other effects to model:**
  - hot and stuck pixels (map from long darks; detect per image with a median test);
  - PRNU (≤1%, usually ignorable);
  - row and column banding (per-row and per-column offsets estimated from masked borders or robust row medians of dark regions);
  - dark shading / amp glow (a low-frequency 2D map, per ISO and exposure time);
  - **dual-gain sensors**, which show a discontinuity in read noise (O, σ_r) versus ISO at the gain switch point. Assessment: sample 1/3-stop ISOs around the suspected switch and store piecewise fits rather than one log-linear fit.

### 4.2 Single-image blind estimation

- Foi et al. 2008 fits PG parameters from one raw image (above).
- Liu, Tanaka & Okutomi select weak-texture patches and estimate noise level from the minimum eigenvalue of the patch covariance (PCA): "Single-Image Noise Level Estimation for Blind Denoising", TIP 2013, DOI 10.1109/TIP.2013.2283400. The signal-dependent extension estimates a noise level function: TIP 2014, DOI 10.1109/TIP.2014.2347204.
- Colom & Buades estimate a noise curve from a single image (IPOL 2013, DOI 10.5201/ipol.2013.45). Buades' 2026 raw denoiser re-estimates SIDD noise functions with it "since the noise level functions embedded in SIDD have been shown to be miscalibrated" (arXiv 2604.17453 §3.3).
- YOND (arXiv 2506.03645; MIT code at https://github.com/fenghansen/YOND_public) does coarse-to-fine noise estimation plus an expectation-matched VST for blind raw denoising.

Assessment: implement PCA/weak-texture per CFA plane, with a robust (Student-t-style, per RPG-VST) linear fit of variance against intensity. Use it as (a) the fallback when no profile exists, (b) a sanity check on the DNG tag or the calibrated profile (flag disagreements larger than 2×), and (c) detection of raws with in-camera NR already applied (spatially correlated residual noise). DNG `NoiseReductionApplied` is a hint here.

### 4.3 DNG NoiseProfile (tag 51041)

**Evidence (DNG 1.6.0.0, p. 57–58, mirrored at https://paulbourke.net/dataformats/dng/dng_spec_1_6_0_0.pdf):**
- "Tag 51041 (C761.H) Type DOUBLE Count 2 or 2 * ColorPlanes."
- The noise model is N_i(x) = √(S_i·x + O_i), with x the "recorded linear signal in the range x ∈ [0,1]".
- The model "assumes that the noise is white and spatially independent, ignoring fixed pattern effects".
- The order follows `CFAPlaneColor`.
- A "BaselineNoise tag value of 1.0 at ISO 100 corresponds approximately to NoiseProfile parameter values of S = 2×10⁻⁵ and O = 4.5×10⁻⁷".

ExifTool lists `0xc761 NoiseProfile double[n]` (https://exiftool.org/TagNames/EXIF.html). Android's Camera2 exposes the same model as `SENSOR_NOISE_PROFILE`: "two noise model coefficients for each CFA channel corresponding to the sensor amplification (S) and sensor readout noise (O)" (https://developer.android.com/reference/android/hardware/camera2/CaptureResult#SENSOR_NOISE_PROFILE).

**Use:** after black subtraction and normalization by (WhiteLevel − BlackLevel), set a_c = S_c and b_c = O_c directly. This is a drop-in for the Poisson–Gaussian part. Row, column and FPN terms still come from our calibrated profile or the blind estimator. Precedence: calibrated Redlamp profile (for the terms it has) ≥ DNG tag > blind estimate. Record which source was used in the render metadata, not in the recipe.

### 4.4 Calibration capture protocol (per camera body)

Adapted from ELD §3.2.1 ("flat-field frames ... of a white paper on a uniformly-lit wall ... lens focused on infinity"; "bias frames ... in a lightless environment with the shortest exposure time ... lens capped"), PMRID §3.2 (burst of a static grayscale chart; bracket equal-luminance pixels; linear regression for k and σ²; arXiv 2010.06935), and Zhang 2021 (dark frames for sampling).

1. **Setup.** Raw only; in-camera long-exposure NR and high-ISO NR off; electronic front curtain or mechanical shutter noted; ambient 20–25 °C (log sensor temperature from EXIF or makernotes if available); lens cap plus eyepiece cover.
2. **Bias frames:** shortest shutter speed, per ISO, 16 frames. Cover every full stop from base to max, plus 1/3 stops around suspected dual-gain switch points.
3. **Dark frames:** 1/30 s, 1 s and 30 s at 5 representative ISOs, 8 frames each. These capture dark current, hot pixels and amp glow.
4. **Flat-field photon-transfer series:** a diffuser or defocused uniform target under DC LED light, with ~8 exposure levels from about 1% to 90% of saturation at each full-stop ISO, and 2 frames per level. Differencing a pair cancels FPN and PRNU when estimating variance.
5. **Frame count:** 16 bias + 16 flats ≈ 32 frames/ISO × ~15 ISOs ≈ 480 frames, plus ~120 darks ≈ 600 frames, which is ~15–25 GB at 24–45 MP. This is consistent with the "~300 calibration data" budget attributed to ELD in LED's Table 1. About half a day per body.
6. **Fit, per ISO and CFA channel:**
   - K and b from the photon-transfer curve;
   - Tukey-λ shape and scale, row σ_r, column σ_c and color bias μ_c from bias frames;
   - hot-pixel list from long darks;
   - optional low-order dark-shading model;
   - across ISO, log-linear joint fits (ELD) with piecewise breaks at dual-gain switches.
7. **Store** a `NoiseProfile` JSON keyed by make, model and (optionally) firmware, plus a curve per ISO. Keep the raw calibration frames in cold storage, and also as dark-frame banks for training (section 6.2).

### 4.5 How big is a profile?

- **Evidence:** darktable's `data/noiseprofiles.json` (https://raw.githubusercontent.com/darktable-org/darktable/master/data/noiseprofiles.json) holds 437 cameras and 8,672 ISO profiles (about 20 ISOs per camera, each a[3] and b[3]) in 1.8 MB of JSON, which is about 4 KB per camera. (This is a data file. It was only counted, not copied. Its license is darktable's GPL, so do **not** ship it.)
- **Assessment (Redlamp):**
  - Parametric profile: ~30 ISOs × (4 planes × {a, b, μ_c} + σ_r, σ_c, λ, σ_TL + dual-gain flag) ≈ 20 doubles, so ≈ 5 KB per camera. 1,000 cameras ≈ 5 MB, so bundle all of them.
  - Optional extras per camera: hot-pixel list (1–10 KB) and per-ISO row/column offset vectors ((6000 + 4000) × 2 B ≈ 20 KB per ISO).
  - Low-res dark-shading maps (1/16 resolution, fp16, ≈ 100 KB per ISO and exposure).
  - Total with FPN data is 0.5–3 MB per camera. Deliver these on demand.

---

## 5. AI denoise survey

### 5.1 Candidates (architecture, cost, license, data, results, Apple Silicon fit)

Unless noted, the ANE assessments are **Assessments** from the op types, not measured. Apple's guidance is that the ANE prefers 4D channels-first tensors, runs FP16, and pads the last axis to 64 bytes ("the most conducive data format for the ANE ... is 4D and channels-first"; "last axis ... must be contiguous and aligned to 64 bytes", https://machinelearning.apple.com/research/neural-engine-transformers). So conv-heavy UNets map well. Window-partition reshapes, gathers, custom scans and large attention matrices tend to fall back to the GPU or CPU or blow up memory.

- **NAFNet** (Chen et al., ECCV 2022, arXiv 2204.04676)
  - Architecture: UNet of NAFBlocks (depthwise conv, SimpleGate, simplified channel attention, channel LayerNorm). No nonlinear activations.
  - Results: SIDD 40.30 dB at 65 GMACs for width64 (Table 6). The raw variant (width16, 7 blocks) scores 40.05 dB at 1.1 GMACs vs PMRID's 39.76 dB at 1.2 GMACs on PMRID's 4Scenes (Table 8).
  - Size: width64-SIDD has 115.98M params (Qualcomm AI Hub card, https://huggingface.co/qualcomm/NAFNet-DeNoise). Width32 is about 29M params and about 16 GMACs at 256² (derived from the SIDD config: enc [2,2,4,8], middle 12, dec [2,2,2,2]).
  - NPU timing: 22.4 ms at 256² FP on a Snapdragon 8 Gen 3 NPU (Qualcomm card).
  - Code: MIT (repo LICENSE, "MIT License Copyright (c) 2022 megvii-model"). Weights: Google Drive and Baidu links in the README with no separate weights license, so **UNCLEAR** (leaning MIT). Third-party mirrors are labelled MIT (`mlx-community/NAFNet-SIDD-width64`, `qualcomm/NAFNet-DeNoise`).
  - Data: SIDD, whose site says "under the MIT License" (see section 6).
  - ANE fit: **excellent.** It is all conv, elementwise and global-pool ops. Channel LayerNorm is expressible as reductions. The global pooling in SCA breaks tile equivalence; fix it with TLC-style local pooling (arXiv 2112.04491; https://github.com/megvii-research/TLC).
- **Restormer** (Zamir et al., CVPR 2022, arXiv 2111.09881)
  - Architecture: transformer with transposed (channel) attention (MDTA) and gated FFN.
  - Results: SIDD 40.02 / DND 40.03 dB, "trained only on the SIDD images". 26.12M params and 141 GFLOPs (ablation table).
  - Licenses: code MIT. Weights on Google Drive with no separate license (UNCLEAR, leaning MIT). Data: SIDD.
  - ANE fit: fair. The C×C attention is small, but LayerNorm, GELU and per-head reshapes, plus large activations at full resolution, make it GPU-first.
- **KBNet** (Zhang et al., arXiv 2303.02881)
  - Architecture: kernel-basis attention with per-pixel fused dynamic kernels.
  - Results: SIDD 40.35 dB at 57.8 GMACs (Table 3), the best SIDD number verified here.
  - Licenses: code MIT. Weights on Baidu and OneDrive (UNCLEAR). Data: SIDD and SenseNoise (SenseNoise terms not checked).
  - ANE fit: poor. Dynamic per-pixel kernels need unfold and gather operations.
- **SCUNet** (Zhang et al., arXiv 2203.13278)
  - Architecture: Swin-Conv blocks in a UNet. 17.94M params and 67.1 GFLOPs at 256².
  - Data: trained **purely on synthetic** degradations of clean images: "We did not use the paired noisy/clean data by DND and SIDD during training" (README). The clean images are WED + DIV2K + Flickr2K (paper §5.1–5.2).
  - Licenses: code Apache-2.0. Weights are tainted, because DIV2K is "for academic research purpose only".
  - ANE fit: mixed (Swin windows).
- **SwinIR** (arXiv 2108.10257)
  - Code Apache-2.0. 11.49M params and 787.9 GFLOPs at 256² (SCUNet Table 3).
  - Gaussian denoising only; no real-noise model. Weights trained on DIV2K/Flickr2K-type data, so tainted.
  - ANE fit: poor (shifted windows, very high FLOPs).
- **Uformer** (arXiv 2106.03106)
  - Code MIT. Uformer-B scores SIDD 39.89 / DND 39.98 with 50.88M params and 89.46 GMACs.
  - Weights (UNCLEAR license) trained on SIDD.
  - ANE fit: mixed (window attention).
- **MIRNet-v2** (arXiv 2205.01649)
  - SIDD 39.84 / DND 39.86; 5.9M params and 140 GFLOPs at 256².
  - License: "ACADEMIC PUBLIC LICENSE ... ❌ Commercial Use ... If you would like to use MIRNetv2 in commercial settings, contact us" (https://github.com/swz30/MIRNetv2 LICENSE.md). **Avoid.**
- **Xformer** (arXiv 2303.06440)
  - Real-DN: DND 40.19 (README) and SIDD 39.98 (paper table); 25.23M params and 42.2 GFLOPs.
  - License: the README says "released under the Apache 2.0 license", but the repo has **no LICENSE file** (GitHub API license: none), so **UNCLEAR**.
  - ANE fit: mixed (spatial-window plus channel attention).
- **MambaIR / MambaIRv2** (arXiv 2402.15648, 2411.15269)
  - Code Apache-2.0. Hugging Face weights `cguoh/MambaIR` are tagged `license:apache-2.0`.
  - Real-DN: SIDD 39.89 / DND 40.04 (MambaIR Table 6). Trained on SIDD.
  - ANE / Core ML fit: **poor.** Selective scan requires the CUDA `mamba_ssm` and `causal_conv1d` packages (README), and Core ML has no scan op. It would have to be unrolled into a sequential loop, or rewritten as a chunked parallel scan in MPSGraph or Metal. Defer.
- **PMRID** (Wang et al., ECCV 2020, arXiv 2010.06935; https://github.com/MegEngine/PMRID)
  - Architecture: a UNet with separable 5×5 convs, plus the **k-sigma transform** f(x) = x/k + σ²/k², which makes one network ISO-independent.
  - Performance: 39.76 dB on their 4Scenes benchmark at "3.6G" MACs (Fig. 8). 70.7 ms/MP on a Snapdragon 855 GPU (≈850 ms for 12 MP).
  - Sensor-specific: the noise was calibrated on an OPPO Reno 10x, and the **clean images come from a subset of SID** (§4.2).
  - Licenses: code **and weights** are Apache-2.0 (the checkpoints are files in the repo: `torch_pretrained.ckp`, 4.18 MB). Data: SID, whose dataset terms are **UNCLEAR**.
  - ANE fit: **excellent.**
- **Unprocessing** (Brooks et al., CVPR 2019, arXiv 1811.11127)
  - Technique: invert the ISP to create synthetic raw from sRGB. Trained on MIR Flickr (1M images; per-image Flickr licenses mixed, **UNCLEAR**). DND raw 48.89 dB.
  - Code in google-research (Apache-2.0). Weights not verified.
  - Assessment: adopt the noise-level conditioning; avoid sRGB-derived raws (Buades 2026 notes they "retain the irreversible quality loss of the original 8 bit images").
- **SID** (Chen et al., CVPR 2018, arXiv 1805.01934)
  - Data: 5,094 short-exposure raws from a Sony α7S II (Bayer) and a Fujifilm X-T2 (X-Trans). X-Trans is packed into 9 channels.
  - Code MIT (LICENSE.md). **No dataset license is stated** in the README or on the project page, so **UNCLEAR**.
- **ELD** (arXiv 2003.12751 and 2108.02158)
  - Noise model as in section 4.1. Code MIT; noise-model and calibration code withheld; dataset and weights on Google Drive with no data license, so **UNCLEAR**.
  - SID Sony ×100/×250/×300: 41.83 / 38.85 / 35.94 dB (LED Table 1).
- **LED** (Jin et al., ICCV 2023, arXiv 2308.03448)
  - Pre-trains on virtual cameras, then fine-tunes with "6 noisy-clean pairs" per camera. SID Sony 41.98 / 39.34 / 36.67 dB, vs 41.73 / 39.14 / 37.36 dB for a UNet trained on ~1,800 real pairs (Table 1).
  - Code: "Creative Commons Attribution-NonCommercial 4.0 ... for non-commercial use only" (README and LICENSE), so **Avoid** the code. The idea (few-shot calibration of the denoiser) can be re-implemented from the paper.
- **PNNP** (arXiv 2310.09126): code Apache-2.0. Released weights for Sony A7S2 and IMX686. The LRID dataset it uses is **CC BY-NC 4.0** on Hugging Face (`hansen97/LRID`), so the IMX686 weights are tainted. Adopt the technique.
- **Rethinking Noise Synthesis** (arXiv 2110.04756): code MIT. Dark-frame sampling (section 4.1). Adopt the technique.
- **Joint demosaic + denoise:**
  - Gharbi et al. 2016 (code MIT, https://github.com/mgharbi/demosaicnet; training-data provenance not verified, so UNCLEAR).
  - Adobe Denoise (Gharbi and Sun are credited for the core technology in Adobe's blog).
  - RawNIND joint denoise/demosaic/compression (arXiv 2501.08924).
- **Burst methods (defer to a later "burst merge" feature):**
  - HDR+ (paper; a third-party Halide reimplementation is MIT, https://github.com/timothybrooks/hdr-plus).
  - Night Sight (paper).
  - KPN (arXiv 1712.02327).
  - BPN (arXiv 1912.04421; code MIT, https://github.com/likesum/bpn; data UNCLEAR).
  - Burstormer (arXiv 2304.01194; code MIT; trained on SyntheticBurst/BurstSR, data UNCLEAR).
  - Handheld multi-frame SR (Wronski et al., arXiv 1905.03277; no official code; patent status UNVERIFIED).
- **Self-supervised:**
  - Noise2Noise (arXiv 1803.04189; NVlabs code **CC BY-NC 4.0**, so Avoid).
  - Noise2Void (arXiv 1811.10980; juglab/n2v BSD-3-Clause).
  - Neighbor2Neighbor (arXiv 2101.02824; BSD-3-Clause).
  - AP-BSN (arXiv 2203.11799).
  - Assessment: useful for *training without clean GT* on our own noisy captures, not needed for v1.
- **Notable 2024–2026 work:**
  - YOND (blind raw, arXiv 2506.03645; MIT code; weights trained on DIV2K + SID, so tainted).
  - Sony "noise modeling in one hour" (arXiv 2505.00045; MIT).
  - Buades' learned non-local match-and-filter (arXiv 2604.17453; MIT code, https://github.com/MIA-UIB/nonlocal-matchfilter; weights trained on SID/ELD/SIDD/RawNIND/CRVD mixes, so tainted). Its evidence is important: a **460-image curated clean-raw set plus synthetic PG noise** conditioned on a noise-level map "generalizes effectively to unseen devices" with far fewer parameters.
  - RPG-VST (arXiv 2607.24291).
  - Color-bias removal (arXiv 2607.11090).
  - AIM 2025 Real-World RAW Denoising challenge (5 DSLRs, synthetic-data training; arXiv 2510.06601; dataset terms not checked).
  - MIPI 2024 few-shot raw denoising (arXiv 2406.07006).

### 5.2 Commercial approaches (what is public)

- **Adobe Denoise** (blog, 2023-04-18). Disclosed:
  - joint demosaic+denoise on Bayer and X-Trans raw;
  - "millions of pairs of high-noise and low-noise image patches";
  - "an extensive noise simulation and data augmentation pipeline";
  - "a large data set of 'dark frames' ... to understand and remove pattern noise in the shadows" (lens-cap captures);
  - training "directly from the raw data";
  - includes Raw Details;
  - uses "NVIDIA's TensorCores and the Apple Neural Engine";
  - output is "a new raw file in the Digital Negative (DNG) format", with the manual NR sliders set to zero;
  - "we're even looking into ways to speed up the workflow by not needing to make a new DNG file."
  - Whether later Lightroom versions dropped the DNG requirement could not be verified (HelpX returned 403).
- **DxO** (dxo.com/technology/deepprime, read via proxy). The current generation is **DeepPRIME 3 and DeepPRIME XD3** in PhotoLab 10 and PureRAW 6. They are ML demosaic+denoise for "Bayer and X-Trans sensors". XD3 is "built using a larger neural network". DP3 adds chromatic-aberration correction using DxO Modules. DxO markets "the equivalent of an extra two stops ... with DeepPRIME XD3, it can be three stops". DxO's sample raws may be used only "within the context of a personal assessment of DxO's products", so they are **not** usable as test data.
- **Topaz Photo** (topazlabs.com/topaz-photo): separate "Denoise" (processed images) and "Denoise (RAW)" models, "AI trained on millions of images", with "unlimited local and cloud rendering". Cloud rendering is a contrast to Redlamp's privacy position.
- **darktable 5.x "neural restore"** (GPL, development manual): raw denoise produces a Bayer CFA DNG, or a LinearRaw DNG for X-Trans, with a raw-level strength blend. This is further evidence that the DNG-bake pattern is the industry default and that X-Trans is commonly handled post-demosaic.

### 5.3 Best candidates

- **Best-quality (verified numbers, permissive code):** KBNet (SIDD 40.35) ≈ NAFNet-w64 (40.30) > Restormer (40.02). The gaps are within 0.35 dB on a phone-sRGB benchmark, which does not predict DSLR raw quality. For *raw* quality the decisive factor is the data and noise model (LED Table 1: the same UNet spans 37.0–42.0 dB depending on training data). **Assessment: the best-quality shippable option is our own NAFNet-style raw model trained on our synthetic pipeline, with a Restormer-class "XD" tier on the Mac GPU as a stretch.**
- **Best ANE-friendly:** NAFNet (conv-only, scales from 1.1 to 65 GMACs per the paper), then PMRID (separable convs, 4 MB).

---

## 6. Training data

### 6.1 Dataset verdicts (from each dataset's own terms)

| Dataset | Content | License / terms (source, verbatim key phrase) | Commercial training OK? |
|---|---|---|---|
| **raw.pixls.us** | 2,016 raw files from 69 makers; 1,870 CC0 (925 camera models), 146 CC BY-NC-SA 4.0 (counted via `json/getrepository.php?set=all`) | Upload declaration: "I hereby release it under the cc0 license into the public domain" (https://raw.pixls.us/). Per file: "Creative Commons 0 - Public Domain" or "Attribution, Non-Commercial, ShareAlike 4.0" | **Yes, for the CC0 files only** (filter per file) |
| **RawNIND** | 2,831 raws (562 clean, 2,279 noisy), 11 cameras incl. X-T1/X-T2 X-Trans (668 images), 120 GB | Dataverse doi:10.14428/DVN/DEQCIM: "CC-BY-SA-4.0 ... The license allows for commercial use. If a reuser remixes, adapts, or builds upon the material, he must license the modified material under identical terms." | **Yes, with ShareAlike risk** (weights may be Adapted Material; CC BY-SA 4.0 forbids "Effective Technological Measures" on Adapted Material, which could conflict with App Store DRM). Legal review needed. |
| **NIND** (Wikimedia Commons) | Developed JPEG/PNG ISO series (e.g. ISO3200: 58 files, ISO6400: 108) | Per-file on Commons: mostly "CC0" and "CC BY 4.0", a few "CC BY-SA 2.0/4.0" (Commons API, extmetadata `LicenseShortName`) | **Yes** (per-file; attribution for CC-BY; drop BY-SA). Not raw. |
| **SIDD** | Smartphone raw + sRGB pairs (5 phones) | "The dataset and the associated code repositories are under the MIT License." (https://www.eecs.yorku.ca/~kamel/sidd/, mirrored at abdokamel.github.io/sidd) | **Yes per site** (MIT). Phone sensors only; GT color bias reported (arXiv 2607.11090); noise functions miscalibrated (Zhang 2021). |
| **HDR+ burst** | 3,640 bursts / 28,461 DNGs from Nexus and Pixel phones, 765 GiB | "released under a Creative Commons license (CC-BY-SA)" (links to by-sa/4.0). Also: "our main intention is that the dataset be used for scientific purposes ... subjects ... include the authors' friends and family, so please keep usage in good taste" (https://hdrplusdata.org/dataset.html) | **Yes, with ShareAlike risk** plus a people/privacy caveat |
| **PMRID** | OPPO Reno 10x noise-calibration DNGs + benchmark | Repo LICENSE Apache-2.0; README: "Code and dataset". Data hosted on OneDrive and Kaggle with no separate terms | **UNCLEAR** (probably Apache via repo; confirm) |
| **SID** | Sony α7S II + Fuji X-T2 raws | Code MIT; **no dataset terms stated** (README, project page) | **UNCLEAR, do not use** |
| **ELD** | 4 DSLRs, 10 scenes | Code MIT; dataset "to facilitate future research", no data license | **UNCLEAR, do not use** |
| **DND** | 50 scenes, benchmark (GT withheld; online submission) | "freely available ... for non-commercial purposes such as academic research, teaching, scientific publications, or personal experimentation" (https://noise.visinf.tu-darmstadt.de/) | **No** (evaluation for a commercial product is doubtful too; ask the authors) |
| **PolyU** | Real noisy/mean images | "Any redistribution, use, or modification is done solely for non-commercial purposes" (repo License.txt) | **No** |
| **LRID** | IMX686 low-light raw | HF `hansen97/LRID`: `license: cc-by-nc-4.0` | **No** |
| **MIT-Adobe FiveK** | 5,000 DNGs + retouches | "solely for your own research purposes, and you shall not exercise any of these rights in any manner that is intended for or directed toward commercial advantage" (LicenseAdobe.txt, LicenseAdobeMIT.txt) | **No** |
| **RAISE** | 8,156 raw (Nikon) | "The RAISE dataset is to be used for non-commercial research and educational purposes" (http://loki.disi.unitn.it/RAISE/download.html) | **No** |
| **DIV2K** | 900 sRGB | "made available for academic research purpose only ... copyright belongs to the original owners" (https://data.vision.ee.ethz.ch/cvl/DIV2K/) | **No** |
| **LSDIR** | 85k sRGB | "made available for academic research purpose only" (https://ofsoundof.github.io/lsdir-data/) | **No** |
| **Flickr2K** | 2,650 sRGB from Flickr | Host (cv.snu.ac.kr) unreachable; no terms found | **UNCLEAR, do not use** |
| **RENOIR** | Real low-light pairs | Site unreachable (ani.stat.fsu.edu) | **UNCLEAR, do not use** |
| **Nam (CC) cross-channel** | Real noisy sRGB | Site unreachable | **UNCLEAR, do not use** |
| **Wikimedia Commons raw** | n/a | Commons does not accept raw formats. Allowed extensions include tiff, png, jpg (siteinfo `fileextensions`); no dng/cr2/nef/arw/raf | **N/A** (only developed images, per-file licenses) |
| **Own captures** | Self-shot clean + noisy + dark frames | Owned | **Yes** (best option) |

### 6.2 Synthetic-training route (design)

- **Clean sources:**
  - (1) Own base-ISO captures: tripod, ETTR, 4–8-frame averages for extra-clean GT. Target 1,500–3,000 scenes over ≥20 bodies, including X-Trans III/IV/V, Canon, Nikon, Sony and dual-gain bodies.
  - (2) raw.pixls.us CC0 files, which are mostly "Well-lit, pattern-full, scenery, low ISO" per the upload guidance, after automatic QC (reject files with estimated σ above a threshold, clipped files, and duplicates).
  - (3) RawNIND clean frames, **only if** legal clears ShareAlike.
  - Evidence that this scale is enough: 460 curated clean raws + synthetic PG noise gave a sensor-agnostic denoiser competitive with SOTA (arXiv 2604.17453). PMRID trained its mobile model on a SID subset (§4.2). RawNIND's Bayer models "generalize well when trained exclusively with RawNIND" (2,831 images).
- **Noise synthesis per sample:**
  - pick a calibrated camera and ISO (log-linear jitter per ELD);
  - add shot noise Poisson(x/K)·K;
  - add signal-independent noise by **sampling real dark-frame patches** from that camera's bank, pattern-aligned (Zhang 2021). This covers read noise, banding, FPN and hot pixels;
  - add color bias μ_c and ±1 LSB black-level jitter;
  - optionally add parametric row noise for cameras without dark banks;
  - add a **noise-level map** (σ from the profile) as an extra input channel. Unprocessing shows +0.38 dB from noise conditioning.
  - Normalize with k-sigma (PMRID) so FP16 on the ANE sees unit-scale data.
- **Cross-camera exposure/CFA handling:** crop to RGGB phase (RawNIND Fig. 4), black-subtract, normalize to [0,1], apply white-balance-invariant augmentation, keep camera-RGB (pre-matrix).
- **X-Trans:**
  - v1: demosaic with Redlamp's X-Trans demosaic, then a **linear-RGB model** trained on demosaiced synthetic noisy X-Trans data. Noise is synthesized on the CFA *before* demosaic, so the model learns demosaic-correlated noise (the darktable approach).
  - v2: a raw→raw X-Trans model with 6×6 → 9-channel packing (SID §3.2).
  - The linear-RGB model also serves linear DNG / ProRAW.
- **Volume and compute (Assessment):**
  - Reference point: NAFNet-SIDD-w32 trains on 8 GPUs × batch 4 × 256² patches for 200k iterations (`options/train/SIDD/NAFNet-width32.yml`).
  - A raw w32-class model (4-ch in, 4-ch out, 128² packed patches, ~0.5–1M iterations) needs roughly 100–400 GPU-hours (A100-class) per run, and about 10–20 runs including ablations. That is about 2–8k GPU-hours, or about USD 5–20k at cloud rates.
  - Storage: about 3–6 TB for clean raws plus dark-frame banks.
  - A Mac Studio M1 Ultra is fine for data prep and evaluation, but too slow for training at this scale.

---

## 7. Product integration

### 7.1 Non-destructive stage vs baked DNG

| Aspect | Non-destructive (re-run or cache) | Baked DNG (Adobe, darktable) |
|---|---|---|
| Reproducibility across devices | ANE runs FP16; GPU/CPU may differ, and chips differ, so re-runs are **not bit-identical**. Mitigate with cached output plus a tolerance spec | Bit-exact forever (pixels frozen) |
| Storage | Cache ≈ 48 MB per 24 MP (Bayer fp16), compressible; evictable local cache, **not** in the JSON sidecar | New DNG ≈ 50–150 MB per image, permanent |
| Interactivity | Amount blend is live; model upgrades possible; edits unaffected | Amount fixed at bake; re-bake to change |
| Workflow | One asset; matches Redlamp's recipe model | Two assets; library clutter |

**Recommendation:** non-destructive with cache.
- The recipe stores `denoise.ai = {modelId, modelVersionHash, amount, profileSource}`.
- The engine caches output keyed by (sourceHash, modelVersionHash, computePrecisionClass, profileHash).
- On a cache miss on another device, re-run. Accept differences within the tolerance: ≥ 50 dB PSNR vs reference and ΔE2000 99.9th percentile < 0.5 after the default render, enforced in CI across CPU/GPU/ANE.
- Keep old model versions installable (on-demand download), so old recipes re-render with their original model.
- Offer "Bake to DNG" (CFA DNG for Bayer, Linear DNG for X-Trans) as an export or interop feature.
- A deterministic "reference" mode (GPU FP32 via MPSGraph) exists for archival exports.

### 7.2 Amount and classical interplay

- Amount = linear blend at raw level between the AI output and the input (as darktable does), done in the k-sigma domain so it runs in <16 ms from cache.
- Classical NR sliders stay available after AI to handle residual noise. Default them to 0 when AI is on (Adobe sets them to zero).
- Re-tune sharpening defaults when AI is on.

### 7.3 Tiled inference

- **Domain and tile size:** packed Bayer (H/2 × W/2 × 4). Tile 256×256 packed (= 512×512 sensor pixels), a multiple of 16 for 4 downsamplings.
- **Overlap:** 32 packed pixels (64 sensor px) to start. **Choose empirically:** measure max |tiled − full| on the Mac GPU in FP32 against overlap, and pick the smallest overlap where it is below 1e-3 (normalized). The theoretical receptive field of deep UNets is hundreds of pixels; the effective one is much smaller.
- **Make tiling exact where possible:** replace global pooling (NAFNet SCA) with fixed-window pooling (TLC), so tile and full inference agree.
- **Blending:** raised-cosine weights in the overlap, on a **grid aligned to image coordinates** (not the viewport), so preview tiles equal export tiles.
- **Batching:** submit 4–8 tiles per Core ML prediction to amortize dispatch. Tiles live in the P3 lane, are cancellable per tile, and back off under thermal pressure or Low Power Mode.
- **Budgets (targets to validate with the prototype):**

| Device tier | 1 MP loupe | 24 MP full | Peak memory | Notes |
|---|---|---|---|---|
| Mac M1 (16-core ANE, "11 trillion operations per second", Apple newsroom 2020) | ≤ 300 ms | ≤ 6 s | ≤ 1.5 GB | M1 Ultra: 32-core ANE (Apple newsroom 2022) |
| iPad M-series | ≤ 400 ms | ≤ 8 s | ≤ 1 GB | thermal throttling |
| iPhone 15 Pro, A17 Pro, 8 GB ("Neural Engine is now up to 2x faster", Apple newsroom 2023) | ≤ 600 ms | ≤ 12 s | ≤ 600 MB | backgroundable, Low Power aware |

- **Compute sanity check (Assessment):** a raw w32-class model at ≈16 GMACs per 256² packed tile is ≈ 6 TMAC for a 24 MP frame, which is ~1.1 s at 100% of M1's peak 11 TOPS. At realistic 20–40% utilization that is 3–6 s, so it fits the Mac budget. The iPhone likely needs a w16–w24 variant, or 8-bit weight palettization (to be measured).
- ANE model compilation on first load can take seconds. Pre-warm it when the user opens the Detail panel, or at import of high-ISO files.

### 7.4 Preview strategy

1. On toggle, run the tiles under the 1:1 loupe first, with results in about 0.3 s (target). The split or A/B view compares against the classical-NR render.
2. Fill the remaining tiles in the background. The fit-to-screen view downsamples completed tiles as they arrive and shows a subtle progress overlay.
3. The Amount slider is live on cached tiles.
4. Because tiles are image-aligned, what the user approved in the loupe is exactly what exports.

### 7.5 Core ML / Neural Engine timing prototype (recommended)

- **Primary: NAFNet-SIDD-width32.**
  - Repo: https://github.com/megvii-research/NAFNet (MIT).
  - Weights: official Google Drive file `NAFNet-SIDD-width32.pth` (https://drive.google.com/file/d/1lsByk21Xw-6aW7epCwOQxvm6HYCQZPHZ/view), downloadable with `gdown`. Straightforward, but it is Google Drive (quota prompts possible). A Hugging Face mirror of width64 exists as MLX safetensors (https://huggingface.co/mlx-community/NAFNet-SIDD-width64, labelled MIT; NHWC layout, so keys and layouts need remapping).
  - Steps:
    - Export with the plain-ops LayerNorm2d.
    - Run `coremltools` (BSD-3-Clause) `ct.convert` to an ML Program in FP16, with fixed input shapes of 256² and 512².
    - Time with `MLComputeUnits.cpuAndNeuralEngine` vs `.cpuAndGPU` vs `.all`.
    - Confirm ANE residency with Xcode's Core ML performance report.
    - Also time a **raw variant** (4-ch in, PixelShuffle out, w16/w24/w32) with random weights. Timing does not need trained weights.
- **Secondary baseline: PMRID** (https://github.com/MegEngine/PMRID, `models/torch_pretrained.ckp`, 4.18 MB, Apache-2.0, in-repo download). It is a true raw-domain model and gives the lower bound on ANE latency.

---

## 8. Evaluation harness

**Objective metrics** (only on data whose terms allow our use):
- Raw-domain PSNR/SSIM on:
  - (a) synthetic held-out pairs from our own clean raws, with the noise model applied to held-out cameras;
  - (b) the RawNIND test split (CC-BY-SA; evaluation is not adaptation);
  - (c) SIDD raw validation (MIT);
  - (d) our own tripod pairs (base-ISO multi-frame average as GT).
- sRGB metrics after a **fixed** Redlamp render (fixed white balance, matrix and tone curve):
  - PSNR, SSIM;
  - LPIPS (https://github.com/richzhang/PerceptualSimilarity, BSD-2-Clause);
  - DISTS (https://github.com/dingkeyan93/DISTS, MIT).
- Report per ISO bin, per camera, and separately for X-Trans.
- Add targeted checks:
  - **color bias:** mean ΔE on gray patches in shadows;
  - **texture retention:** dead-leaves / texture-MTF chart;
  - **hallucination:** text, fine regular patterns and moiré targets, where any invented structure is a failure;
  - **banding residual:** row-mean variance in dark flats;
  - **highlight edges:** near clipping.
- Exclude DND, SID, ELD, LRID, PolyU and FiveK unless legal confirms evaluation use. DND's non-commercial terms make even benchmark submission for a commercial product doubtful, so ask the authors.

**Blind A/B on own captures:**
- **Scenes:** ≥60 scenes (indoor low light, night street, sports/indoor action, astro/landscape shadows, portraits/skin, foliage, fabric).
- **Bodies:**
  - Sony (A7 IV, A7S III dual-gain);
  - Canon (R6 II plus an older banding-prone body such as a 5D III or 7D);
  - Nikon (Z6 III / Z8);
  - Fujifilm X-Trans V (X-T5 or X-H2);
  - iPhone ProRAW (linear).
- **ISO:** ISO 3200 / 12800 / 51200 (or near max), each paired with a base-ISO tripod reference.
- **Contestants:**
  - Redlamp classical NR v1 at defaults and at tuned settings;
  - Redlamp AI;
  - Lightroom Denoise (Amount 50 default);
  - DxO DeepPRIME XD3;
  - Topaz Photo Denoise (RAW), local rendering only.
- **Fairness conditions:** (1) vendor defaults; (2) a matched-residual-noise condition, adjusting each tool's amount until the residual σ in a flat patch matches within 10%, then judging detail.
- **Protocol:**
  - 1:1 crops of 1024² plus full-frame views; randomized left/right; pairwise 2AFC plus "no preference";
  - ≥20 photographers plus 5 expert retouchers, calibrated displays, no tool names;
  - analyse with Bradley–Terry scores and 95% bootstrap CIs;
  - target "Redlamp AI not significantly worse than the best competitor" at Phase 3 exit, and "better than Lightroom manual NR" for classical at Phase 2 exit.
- **Legal:** check each competitor's EULA for benchmarking or publication restrictions before publishing results. Keep them internal otherwise.

---

## 9. Shortlist table

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| **Own NAFNet-style raw model** | MIT (NAFNet base) | ours | own + raw.pixls.us CC0 (+ RawNIND?) | NAFNet raw 40.05 vs PMRID 39.76 dB at ~1.1 GMAC (arXiv 2204.04676 T8) | Excellent (conv-only) | **Build (Phase 3 primary)** |
| NAFNet-SIDD w32/w64 | MIT | UNCLEAR (GDrive; mirrors say MIT) | SIDD (MIT per site) | SIDD 40.30 (w64, 65 GMAC) | Excellent | **Prototype; fine-tune only** (phone sRGB domain) |
| PMRID | Apache-2.0 | Apache-2.0 (in repo) | SID clean (UNCLEAR) + OPPO noise | 39.76 dB 4Scenes; 70.7 ms/MP SD855 | Excellent | Fine-tune only; ANE baseline |
| Restormer | MIT | UNCLEAR | SIDD | SIDD 40.02 / DND 40.03 | Fair (GPU-first) | Fine-tune only ("XD" tier candidate) |
| KBNet | MIT | UNCLEAR | SIDD, SenseNoise | SIDD 40.35 @57.8 GMAC | Poor (dynamic kernels) | Research-only benchmark |
| Uformer | MIT | UNCLEAR | SIDD | SIDD 39.89 / DND 39.98 | Mixed | Fine-tune only (low priority) |
| SCUNet | Apache-2.0 | tainted (DIV2K etc.) | synthetic from WED/DIV2K/Flickr2K | qualitative real-world | Mixed | Fine-tune only (idea: degradation synthesis) |
| SwinIR | Apache-2.0 | tainted | DIV2K/Flickr2K | Gaussian only | Poor | Defer |
| Xformer | UNCLEAR (README Apache, no LICENSE file) | UNCLEAR | SIDD | DND 40.19 | Mixed | Research-only until clarified |
| MambaIR / v2 | Apache-2.0 | Apache-2.0 (HF tag) | SIDD (realDN) | SIDD 39.89 / DND 40.04 | Poor (no scan op) | Defer |
| MIRNet-v2 | Academic NC | NC | SIDD | SIDD 39.84 | Fair | **Avoid** |
| LED | CC BY-NC 4.0 | NC | SID/ELD | SID ×100 41.98 with 6 pairs | Fine (UNet) | Avoid code; re-implement idea |
| PNNP | Apache-2.0 | tainted (LRID NC) | ELD/SID/LRID | (TPAMI) | Fine | Adopt technique only |
| ELD / Zhang 2021 / Sony 2025 | MIT | UNCLEAR data | ELD/SID/SIDD | ELD 41.83 SID×100 | n/a | Adopt noise-model techniques |
| Noise Flow | CC BY-NC-SA | NC | SIDD | worse than ELD in LED T1 | n/a | Avoid |

---

## 10. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| NAFNet | MIT, "MIT License Copyright (c) 2022 megvii-model" (github.com/megvii-research/NAFNet/blob/main/LICENSE; also bundles BasicSR Apache-2.0 notice) | Not stated; GDrive/Baidu links in readme.md; HF mirrors mlx-community & qualcomm tagged `license:mit`, so **UNCLEAR** | SIDD: "under the MIT License" (eecs.yorku.ca/~kamel/sidd) | MIT + Apache-2.0 NOTICE for BasicSR-derived code | Architecture shippable; weights fine-tune only / prototype |
| Restormer | MIT (GitHub API `license: MIT`, swz30/Restormer) | Not stated (GDrive), **UNCLEAR** | SIDD (MIT) | MIT notice | Fine-tune only |
| KBNet | MIT (zhangyi-3/KBNet) | Not stated (Baidu/OneDrive), **UNCLEAR** | SIDD, SenseNoise (not checked) | MIT | Research-only |
| SCUNet | Apache-2.0 (cszn/SCUNet) | Not stated; data DIV2K "academic research purpose only" | DIV2K/Flickr2K/WED | Apache NOTICE | Fine-tune only |
| SwinIR | Apache-2.0 (JingyunLiang/SwinIR) | tainted (DIV2K) | DIV2K/Flickr2K | Apache | Defer |
| Uformer | MIT (ZhendongWang6/Uformer) | **UNCLEAR** | SIDD | MIT | Fine-tune only |
| MIRNet-v2 | "ACADEMIC PUBLIC LICENSE ... ❌ Commercial Use" (swz30/MIRNetv2 LICENSE.md) | NC | SIDD | n/a | **Avoid** |
| Xformer | README "released under the Apache 2.0 license"; **no LICENSE file** (gladzhang/Xformer), so **UNCLEAR** | **UNCLEAR** | SIDD, DIV2K etc. | Restormer/BasicSR licenses | Research-only |
| MambaIR/v2 | Apache-2.0 (csguoh/MambaIR) | Apache-2.0 (HF `cguoh/MambaIR` cardData.license) | SIDD for realDN; DIV2K for others | Apache | Defer (Core ML) |
| PMRID | Apache-2.0 (MegEngine/PMRID) | Apache-2.0 (weights are repo files) | SID clean subset (**UNCLEAR**) + own OPPO noise | Apache NOTICE | Fine-tune only |
| SID | MIT (LICENSE.md, "Copyright (c) 2018 Chen Chen, Qifeng Chen, Jia Xu, and Vladlen Koltun") | not checked | SID data: no terms (**UNCLEAR**) | MIT | Reference only |
| ELD | MIT (Vandermode/ELD) | not stated | ELD data: no terms (**UNCLEAR**) | MIT | Technique only |
| LED | "Creative Commons Attribution-NonCommercial 4.0 ... for non-commercial use only" (Srameo/LED README + LICENSE) | NC | SID/ELD | n/a | **Avoid** code |
| PNNP | Apache-2.0 (fenghansen/PNNP) | tainted: LRID "cc-by-nc-4.0" (HF hansen97/LRID) | ELD/SID/LRID | Apache | Technique only |
| Noise-Synthesis (Zhang 2021) | MIT (zhangyi-3/Noise-Synthesis) | not stated (Baidu) | SIDD, ELD | MIT | Technique only |
| Sony noise-in-1h | MIT (SonyResearch/raw_image_denoising) | not stated (GDrive) | ELD/SID/LRID | MIT | Technique only |
| YOND | MIT (fenghansen/YOND_public) | tainted: "crops from ... DIV2K dataset and SID Sony" (README) | DIV2K (NC), SID (UNCLEAR) | MIT | Technique only |
| Nonlocal match-filter (Buades 2026) | MIT (MIA-UIB/nonlocal-matchfilter) | release assets, license not separately stated | SID/ELD/SIDD/RawNIND/Nikon/CRVD (mixed) | MIT | Technique only |
| Noise Flow | CC BY-NC-SA 4.0 (BorealisAI/noise_flow LICENSE) | NC | SIDD | n/a | **Avoid** |
| Noise2Noise | CC BY-NC 4.0 (NVlabs/noise2noise LICENSE) | NC | n/a | n/a | **Avoid** code (idea OK) |
| Noise2Void / Neighbor2Neighbor | BSD-3-Clause (juglab/n2v; TaoHuang2018/Neighbor2Neighbor) | n/a | n/a | BSD notice | Usable if needed |
| demosaicnet (Gharbi 2016) | MIT (mgharbi/demosaicnet) | **UNCLEAR** | not verified | MIT | Reference only |
| Burstormer / BPN | MIT (akshaydudhane16/Burstormer; likesum/bpn) | **UNCLEAR** | SyntheticBurst/BurstSR (**UNCLEAR**) | MIT | Defer |
| BM3D / BM3D-CFA (reference code) | TAU limited license: "non-commercial scope only" (webpages.tuni.fi/foi/GCF-BM3D/legal_notice.html); IPOL version GPL-3.0-or-later | n/a | n/a | **Patent status UNVERIFIED** (FTO) | Clean-room only; not v1 |
| NLM | IPOL GPL (Avoid); paper method | n/a | n/a | EP 1,749,278 (2007) cited by IPOL; likely lapsed, verify US | Clean-room OK after FTO |
| Guided filter | paper method (TPAMI 2013) | n/a | n/a | **Patent status UNVERIFIED** | Clean-room; joint-bilateral fallback |
| Foi PG estimator | TUT limited (non-commercial) (webpages.tuni.fi/foi/sensornoise.html) | n/a | n/a | none known | Clean-room from TIP 2008 |
| coremltools / LPIPS / DISTS (tools) | BSD-3 / BSD-2 / MIT | n/a | n/a | notices (eval-only for LPIPS/DISTS) | Use |

---

## 11. Recommendations and effort (engineer-weeks)

| Item | Decision | Effort |
|---|---|---|
| Noise-profile infra: DNG 51041 reader, profile schema, blind PCA estimator | Build | 2 |
| Calibration tool (capture checklist app + fitter: PTC, Tukey-λ, row/col, dual-gain) + first 10 bodies | Build | 3 (+0.5 day/body capture) |
| Sensor cleanup stage (hot px, banding, color bias, optional dark shading) | Build | 2 |
| NR v1 fast path (luma pyramid + chroma guided, pyramid-level preview, clip mask) | Build | 4–5 |
| NR v1 HQ path (GAT + NLM or DFT-Wiener on fine bands) | Build | 2–3 |
| Slider mapping, tuning, A/B vs Lightroom manual NR | Build | 2–3 |
| **Classical subtotal (Phase 2)** | | **15–18** |
| Core ML/ANE timing prototype (NAFNet w32, PMRID, raw variants sweep) | Do now | 1–1.5 |
| Data: own clean + dark-frame library (20 bodies), raw.pixls.us CC0 curation, legal on RawNIND/HDR+ | Build | 4–5 |
| Noise synthesis + training pipeline (k-sigma, dark-frame sampling, noise map) | Build | 3–4 |
| Training + ablations (Bayer raw→raw; X-Trans linear-RGB) | Train own | 6–8 (+USD 5–20k compute) |
| Engine integration (stage, tiling, cache/versioning, loupe preview, Amount, DNG bake) | Build | 4–5 (tiling framework shared with other AI features) |
| Evaluation harness + blind A/B study | Build | 3 |
| **AI subtotal (Phase 3)** | **Train own on NAFNet-style arch** | **~24–30** |
| Joint demosaic+denoise ("Raw Details" equivalent), burst merge, BM3D-class export mode | Defer (Phase 4+) | n/a |

Roadmap note: start calibration captures and the ANE prototype *during* Phase 2. The classical denoiser and the AI data pipeline share the same noise profiles and dark-frame banks, so Phase 2 work de-risks Phase 3.

---

## 12. Risks and open questions

1. **ShareAlike on weights** (RawNIND, HDR+). Whether trained weights are Adapted Material is legally unsettled. CC BY-SA 4.0 says "You may not ... apply any Effective Technological Measures to, Adapted Material", which could conflict with App Store FairPlay. Mitigation: train v1 on CC0 plus own data only; seek counsel.
2. **SIDD "MIT" statement** rests on the dataset page alone (no LICENSE file checked in a data repo). Get written confirmation before relying on SIDD-trained weights.
3. **Patents:** BM3D, guided filter, HDR+ merge / spatial DFT denoise, handheld SR, and US counterparts of the NLM patent are all UNVERIFIED. An FTO search is needed before Phase 2 ships.
4. **Cross-device reproducibility:** FP16 ANE vs GPU vs CPU. Needs the tolerance spec, the cache, and a reference mode (section 7.1).
5. **FP16 dynamic range in deep shadows:** the fp16 minimum normal is ≈6e-5. Mitigate with k-sigma/VST normalization before the network.
6. **Hallucination and "plastic" texture:** AI can invent texture. Include regular-pattern and text charts in the eval, and give the Amount blend.
7. **Camera coverage:** calibrated profiles take a body in hand. Blind estimation plus the DNG tag must be good enough for the long tail. Sony's "one hour" method (arXiv 2505.00045) may cut calibration cost.
8. **In-camera raw NR** (some bodies at high ISO) and lossy-compressed raws break the white-noise assumption. Blind correlation detection should reduce strength.
9. **X-Trans quality** with the linear-RGB path may lag Adobe/DxO's joint models. v2 raw X-Trans model.
10. **iPhone thermal and memory limits** for 48 MP-class files. Needs measurement.
11. **Adobe roadmap:** Adobe said it is "looking into ways to ... not need[] to make a new DNG file". If shipped, our non-destructive advantage narrows. Not verified whether it has shipped (HelpX blocked).
12. **Open:** should Redlamp read and use ProRAW or Android `NoiseProfile` values as-is, given that they come from vendor ISPs? Recommend yes, with a blind-estimate sanity check.

---

## 13. Test data sources (with licenses)

| Source | What | License | Use |
|---|---|---|---|
| Own captures (Sony A7 IV/A7S III, Canon R6 II + 5D III/7D, Nikon Z6 III/Z8, Fujifilm X-T5/X-H2, iPhone ProRAW) | High-ISO scenes + base-ISO references + calibration frames | Owned (can release CC0) | Train, eval, A/B |
| raw.pixls.us (CC0 subset, 1,870 files / 925 models) | Mostly low-ISO samples | CC0 (per file; exclude 146 BY-NC-SA) | Clean training sources, format coverage |
| RawNIND (doi:10.14428/DVN/DEQCIM) | Paired clean/noisy raw, Bayer + X-Trans | CC BY-SA 4.0 | Eval now; training after legal review |
| NIND (Commons category "Natural Image Noise Dataset") | Developed ISO series | CC0 / CC BY 4.0 (per file) | sRGB eval; attribution |
| SIDD | Phone raw/sRGB pairs | MIT (per site) | Eval; possible training |
| HDR+ burst dataset | Phone raw bursts | CC BY-SA 4.0 (+ "scientific purposes" intention, people) | Future burst work; eval |
| PMRID benchmark | Phone raw pairs | Apache-2.0 repo (**UNCLEAR** for data) | Internal eval after confirmation |
| DND, SID, ELD, LRID, PolyU, FiveK, RAISE, DIV2K, LSDIR, DxO sample raws | n/a | NC / research-only / UNCLEAR / DxO "personal assessment" only | **Do not use** (unless written permission) |

---

## 14. Verification log (primary URLs, fetched 2026-09-29)

- GitHub API license fields and LICENSE files: megvii-research/NAFNet (MIT), swz30/Restormer (MIT), cszn/SCUNet (Apache-2.0), zhangyi-3/KBNet (MIT), JingyunLiang/SwinIR (Apache-2.0), ZhendongWang6/Uformer (MIT), swz30/MIRNetv2 (Academic, NC), gladzhang/Xformer (none), csguoh/MambaIR (Apache-2.0), MegEngine/PMRID (Apache-2.0), cchen156/Learning-to-See-in-the-Dark (MIT), Vandermode/ELD (MIT), Srameo/LED (CC BY-NC 4.0), fenghansen/PNNP (Apache-2.0), zhangyi-3/Noise-Synthesis (MIT), SonyResearch/raw_image_denoising (MIT), fenghansen/YOND_public (MIT), MIA-UIB/nonlocal-matchfilter (MIT), BorealisAI/noise_flow (CC BY-NC-SA 4.0), NVlabs/noise2noise (CC BY-NC 4.0), juglab/n2v (BSD-3), TaoHuang2018/Neighbor2Neighbor (BSD-3), mgharbi/demosaicnet (MIT), akshaydudhane16/Burstormer (MIT), likesum/bpn (MIT), timothybrooks/hdr-plus (MIT), apple/coremltools (BSD-3), richzhang/PerceptualSimilarity (BSD-2), dingkeyan93/DISTS (MIT).
- Hugging Face API: `cguoh/MambaIR` (apache-2.0), `mlx-community/NAFNet-SIDD-width64` (mit), `qualcomm/NAFNet-DeNoise` (mit; 115.98M params; NPU timings), `datasets/hansen97/LRID` (cc-by-nc-4.0).
- Papers (arXiv PDFs parsed): 2204.04676, 2111.09881, 2203.13278, 2303.02881, 2106.03106, 2205.01649, 2303.06440, 2402.15648, 2411.15269, 2108.10257, 2010.06935, 1811.11127, 1805.01934, 2003.12751, 2108.02158, 2308.03448, 2310.09126, 2110.04756, 1908.08453, 1910.11336, 1905.03277, 1912.04421, 2304.01194, 1803.04189, 1811.10980, 2101.02824, 2203.11799, 2501.08924, 2604.17453, 2607.11090, 2607.24291, 2506.03645, 2505.00045, 2510.06601, 2406.07006; HDR+ paper PDF (hdrplusdata.org/hdrplus.pdf). DOIs checked on Crossref: TIP.2007.901238, LNLA.2009.5278395, TIP.2008.2001399, TIP.2013.2283400, TIP.2014.2347204, TIP.2010.2056693, TIP.2012.2202675, TIP.2003.818640, TSP.2002.804091, TPAMI.2012.213, 2980179.2980254, 2980179.2982399, CVPR.2005.38, ISBI.2008.4541250, ICCV.1998.710815, 1276377.1276506, j.sigpro.2009.04.035, ipol.2013.45, CVPR.2017.294, CVPR.2018.00182.
- Dataset terms pages: SIDD, DND, FiveK (LicenseAdobe*.txt), RAISE (download.html), HDR+ (dataset.html), raw.pixls.us (+ JSON), DIV2K, LSDIR, PolyU (License.txt), RawNIND (Dataverse API), Wikimedia Commons (API), LRID (HF).
- Vendor: Adobe blog "Denoise demystified" (2023-04-18); DxO DeepPRIME page (via r.jina.ai proxy; direct fetch 403); Topaz Photo page; Apple newsroom (M1, M1 Ultra, iPhone 15 Pro); Apple ML research "Deploying Transformers on the Apple Neural Engine"; darktable manual (denoise profiled; neural restore); DNG 1.6.0.0 spec (paulbourke.net mirror); ExifTool tag table; Android Camera2 reference.
- **Blocked or unverified:** Google Patents / Justia / Espacenet / USPTO (403/503); Adobe HelpX (403); dxo.com direct (403); RENOIR, Nam CC and Flickr2K hosts unreachable; Kaggle PMRID dataset page (JS-only, not checked).
