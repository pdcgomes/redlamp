# TON-39: how Redlamp reproduces a grey scale

A museum imaging department tried Redlamp on raw target shots from Canon, Leica, Hasselblad and Sony cameras, exposed by an incident meter, white-balanced on the target and rendered with Redlamp Neutral (9 October 2026, by email). Its exports came out slightly underexposed, and the grey scale's L* wasn't linear against the target's values. This note measures that on a chart raw, explains it from the rendering, and states what TON-39 (a scene-referred mode) and CAM-28 (exposure tied to the camera's metering) have to change.

## Method

`research/tone-reproduction/greyscale.py` renders each shot in `research/tone-reproduction/charts.json` with the `redlamp` CLI as 16-bit sRGB TIFFs and measures each grey patch's mean L*:

1. Temperature and Tint are searched until the middle-grey patch is neutral.
2. Exposure 0, with Redlamp Neutral and Redlamp Color.
3. Exposure set so the middle-grey patch reads its reference L* under Neutral, so that what's left is the tone curve's shape.
4. Where the shot put an 18% grey, in stops below the sensor's clip: the middle-grey patch's scene value, recovered through the tone curve's exact inverse and scaled from its reference to 18%.
5. The model: `Develop.metal`'s tone curve with each look's contrast, as `DevelopParameters` applies it, at that grey position.

Its only shot so far is the CC0 Sigma fp DNG from the look-development set (raw.pixls.us): a ColorChecker Passport, not metered (ISO 3200, f/1.0, 1/50 s, under reddish light). The chart's own reference values aren't known; BabelColor's averages for charts made before November 2014 stand in for them. The department's files, when they arrive, are metered and come with their target's values.

## Result

Sigma fp, ColorChecker Passport's grey row, white balance 5610 K and tint +7 on Neutral 5; this shot put an 18% grey 3.85 stops below clip.

| | Black 2 | Neutral 3.5 | Neutral 5 | Neutral 6.5 | Neutral 8 | White 9.5 |
|---|---|---|---|---|---|---|
| Reference L* | 20.5 | 35.7 | 50.9 | 66.8 | 81.3 | 96.5 |
| Neutral, Exposure 0 | 12.5 | 25.6 | 42.0 | 57.5 | 69.7 | 79.2 |
| Neutral, model | 10.5 | 25.7 | 42.0 | 57.9 | 70.0 | 79.9 |
| Color, Exposure 0 | 7.0 | 19.9 | 37.9 | 56.2 | 70.8 | 81.8 |
| Color, model | 5.5 | 20.0 | 37.9 | 56.6 | 71.1 | 82.7 |
| Neutral, Exposure +0.53 (middle grey anchored) | 17.3 | 32.7 | 50.9 | 66.7 | 78.1 | 86.3 |

- **The model predicts the renders.** From Neutral 3.5 to White it is within 0.9 L* of what was measured; Black reads 2 L* lighter than modelled, as flare in a real shot's shadows does.
- **With middle grey anchored, the curve still bends the scale.** White reads 86.3 against 96.5, Neutral 8 78.1 against 81.3 and Black 17.3 against 20.5, while Neutral 5 and 6.5 are within 0.1. That is the curve's shoulder and toe. No exposure makes it linear, so a reproduction mode has to replace the curve (TON-39), not adjust it.
- **Exposure depends on the camera.** Redlamp scales the sensor's clip to 1 and applies one curve to every camera. A DNG's BaselineExposure is added; other raws get none. Cameras put a metered 18% grey roughly 3.3 to 3.7 stops below clip, by their ISO calibration, and the model puts Neutral 5 at 51.4 L* for 3.3 stops and 44.6 for 3.7. The camera bench finds Redlamp's default up to 1.7 stops darker than the Canon 5D Mark IV's own JPEG and 2.2 stops darker than the R6 Mark III's. This shot's 3.85 stops is its own exposure, not the Sigma fp's calibration, since it wasn't metered.
- **Redlamp's middle grey isn't the scene's.** The curve renders scene 0.18 at L* 64.3, and L* 50 at scene 0.112. Exposure anchored so a metered grey lands at 0.18 would brighten every non-DNG render by about a stop unless the curve is re-centred. CAM-28's design decides whether anchoring applies only in TON-39's mode or to every render, behind a new process version.

## What TON-39 and CAM-28 need

- A rendering with no curve and no look: output equal to scene light up to the white point, so a metered 18% grey reads L* 49.5 and each patch its own L*, with clipping shown honestly.
- Exposure tied to each camera's metering: a per-camera baseline measured by Redlamp (never Adobe's data), or a target's grey patch set to its reference L* and kept per camera. The readout's exposure in stops (UX-32) waits on this, so that 0.0 means the metered grey.
- Reference output spaces for masters (EDT-26), and readouts that stay when the pointer moves to a slider (UX-40).
- The department's metered files, with their targets' values, to measure the four cameras here and to test the mode as it's built.
