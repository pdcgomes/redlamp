# Process version references

An edit records the process version it was made with (`EditRecipe.processVersion`) and must render the same way forever; new rendering ships behind a new process version. `ProcessStabilityTests` (in `packages/RedlampEngine/Tests`) checks that every version from 1 to the current one still renders as it did when it shipped.

## What's here

- `process-<N>/<fixture>.json`: process N's reference for one fixture. The fixture is developed with one heavy edit at process N (`ProcessStabilityTests.edit`) and measured twice: the whole photo exported at 384 pixels on the long side, in 24 × 16 patches, and a 384 × 256 window from the middle of the photo at full resolution, as the editor shows it at 1:1, in 12 × 8 patches. For every patch, `lab` is its mean colour in CIELAB and `detail` the RMS difference in L* between neighbouring pixels, which grain, noise reduction, sharpening and Texture change.
- `process-<N>/<fixture>.retouch.json`: the same for a second edit, `retouch` (`ProcessStabilityTests.retouchEdit`): a brush mask, luminance and colour range masks, an AI sky mask, a Heal circle and a brushed Clone spot, a crop turned 3.5° with vertical and horizontal Transform, and black and white with the mixer. The AI mask is the sky matte the iPhone file embeds, kept here as `IMG_1361.sky.png`, so no model is needed. Spots belong to the removal work: if it changes how existing spots render, that is a process-version question, not a re-recording.
- `DSC_0750.png`: the bitmap fixture, the Nikon Z 6 sample (`DSC_0750.NEF`, CC0, from raw.pixls.us) developed by macOS at 1280 pixels in sRGB, with the sample's metadata. It is kept here so it never changes. It is a PNG because JPEG decoders differ between Macs: GitHub's runners decoded the JPEG it replaced to different pixels (up to 3 levels apart in 8% of them), while a PNG decodes to the same pixels everywhere. Its pixels are the JPEG's as the Mac that recorded the references decoded it, so the references were unchanged by the switch.

The raw fixtures are four of the CC0 files `mise run fixtures` downloads into `tests/fixtures/raw`: the Sony ILCE-7M3, Fujifilm X-T3, iPhone 12 Pro (ProRAW) and Pixel 4a samples. Between them and the bitmap, every process version's change shows in at least one fixture. Without the raw files, or without a Metal GPU, the test skips, as the camera goldens do.

## Recording a new process version

Record the new version's references in the change that adds the version:

```bash
TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1 xcodebuild test -workspace Redlamp.xcworkspace \
    -scheme RedlampEngine -destination 'platform=macOS,arch=arm64' \
    -only-testing:RedlampEngineTests/ProcessStabilityTests
```

Recording writes only the references that are missing and never overwrites one. Without the switch, a version without references fails the test.

Changing the heavy edit, the fixtures or the measurements needs every version's references again. Record them all from a commit where the test passes, and commit the change and the references together.

## When the test fails

The failure names the process, the fixture and the view (whole frame or 1:1 window), with the colour and detail differences and the limits. It means a change altered how existing edits render: put the new rendering behind a new process version instead. Never re-record an existing version to make the test pass.

On one machine, rendering is deterministic: repeated renders measure the same to the last digit, so the limits leave room only for another GPU's rounding. If the test fails on another Mac with no change to the engine, measure the differences there and widen the limits in `ProcessStabilityTests`, with the measurement in its comment, rather than re-recording. First check that the fixture decodes to the same pixels there: if it doesn't, the fixture is at fault, not the GPU.
