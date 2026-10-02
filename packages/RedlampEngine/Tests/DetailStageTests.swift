import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Flat synthetic sensors with exact Poisson–Gaussian noise, through the real session builder.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DetailStageTests {
    static let noise = NoiseModel(a: SIMD3(repeating: 4e-4), b: SIMD3(repeating: 2e-6))
    static let level: Float = 0.25

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    static let calibrating = ProcessInfo.processInfo.environment["REDLAMP_CALIBRATE_NOISE"] == "1"

    /// The measured detail noise per scale must match `NoiseCalibration`, which is what the
    /// thresholds are scaled by. Slow (minutes), so it runs on request, after a demosaic or pyramid
    /// change: `TEST_RUNNER_REDLAMP_CALIBRATE_NOISE=1`. It prints the table to paste.
    @Test(.enabled(if: calibrating), arguments: [SensorKind.bayer, .xTrans, .linear])
    func `calibration matches the pipeline`(sensor: SensorKind) throws {
        let session = try makeSession(sensor, width: 2048, height: 1536)
        for level in 0 ... 2 {
            let measured = try measureScaleNoise(session, level: level)
            let table = NoiseCalibration.sigmas(sensor: sensor, level: level)
            let formatted = measured.map { String(format: "(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) }
            print("calibration \(sensor) level \(level): [\(formatted.joined(separator: ", "))]")
            for scale in 0 ..< DenoiseSettings.scaleCount {
                for axis in 0 ..< 3 {
                    let ratio = measured[scale][axis] / table[scale][axis]
                    #expect(abs(ratio - 1) < 0.15, "\(sensor) level \(level) scale \(scale) axis \(axis): \(ratio)")
                }
            }
        }
    }

    @Test func `noise reduction removes noise and keeps the level`() throws {
        let session = try makeSession(.bayer, width: 1024, height: 768)
        var recipe = Self.unsharpened
        recipe[.noiseLuminance] = 60
        recipe[.noiseColor] = 50
        let before = try statistics(of: readLevel(session, level: 0))
        let after = try statistics(of: processed(session, recipe: recipe))
        for channel in 0 ..< 3 {
            #expect(abs(after.mean[channel] / before.mean[channel] - 1) < 0.01, "mean \(channel)")
            #expect(after.deviation[channel] < before.deviation[channel] * 0.4, "deviation \(channel)")
        }
    }

    @Test func `zero thresholds reproduce the pyramid`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384)
        let source = try readLevel(session, level: 0)
        var nearlyOff = Self.unsharpened
        // Keeps the stage running with thresholds that remove nothing.
        nearlyOff[.noiseLuminance] = 0.001
        nearlyOff[.noiseColor] = 0
        let passed = try processed(session, recipe: nearlyOff)
        var worst: Float = 0
        for index in stride(from: 0, to: source.count, by: 7) {
            worst = max(worst, simd_abs(source[index] - passed[index]).max())
        }
        #expect(worst < 2e-3)
    }

    /// Tiles denoise with enough margin that seams can't show: small tiles must give the same
    /// still as one tile covering everything.
    @Test(.enabled(if: !EngineSmokeTests.fixtures.isEmpty))
    func `tiled stills match untiled`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { SupportedFormats.isRaw($0) })
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 80
        recipe[.noiseColor] = 60
        recipe[.grainAmount] = 30
        recipe[.texture] = 40
        recipe[.clarity] = 30
        let request = StillRequest(recipe: recipe, maxLongEdge: 1500)
        var renders: [Data] = []
        for tile in [256, 4096] {
            let engine = try RedlampEngine(stillTile: tile)
            _ = try await engine.open(url)
            let image = try await engine.renderStill(request)
            try renders.append(#require(image.dataProvider?.data) as Data)
        }
        #expect(renders[0].count == renders[1].count)
        var worst = 0
        var differing = 0
        for (a, b) in zip(renders[0], renders[1]) where a != b {
            worst = max(worst, abs(Int(a) - Int(b)))
            differing += 1
        }
        #expect(worst <= 1, "largest difference \(worst) in \(differing) bytes")
    }

    // MARK: - Sharpening

    /// Noise reduction and sharpening both off.
    static let untouched: EditRecipe = {
        var recipe = EditRecipe()
        recipe[.noiseColor] = 0
        recipe[.sharpenAmount] = 0
        return recipe
    }()

    static let unsharpened: EditRecipe = {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 0
        return recipe
    }()

    @Test func `sharpening overshoots an edge and keeps the level`() throws {
        let session = try makeSession(.bayer, width: 512, height: 256, noiseScale: 0) { x, _ in x < 256 ? 0.1 : 0.4 }
        var recipe = Self.untouched
        recipe[.sharpenAmount] = 100
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        let row = 128 * 512
        // The dark side of the step gets darker and the bright side brighter; flat areas far
        // from it don't change. (Extremes, because demosaicing already ripples at a hard step.)
        let dark = { (pixels: [SIMD3<Float>]) in (250 ... 255).map { pixels[row + $0].y }.min()! }
        let bright = { (pixels: [SIMD3<Float>]) in (256 ... 261).map { pixels[row + $0].y }.max()! }
        #expect(dark(after) < dark(before) * 0.97)
        #expect(bright(after) > bright(before) * 1.02)
        #expect(abs(after[row + 100].y / before[row + 100].y - 1) < 0.002)
        let mean = { (pixels: [SIMD3<Float>]) in pixels.reduce(SIMD3<Float>.zero, +).y / Float(pixels.count) }
        #expect(abs(mean(after) / mean(before) - 1) < 0.01)
    }

    @Test func `the stage is skipped when nothing needs it`() throws {
        let session = try makeSession(.bayer, width: 256, height: 256)
        let stage = DetailStage(device: device, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        let output = try stage.process(
            Self.untouched, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        )
        #expect(output == nil)
        #expect(!DetailStage.isActive(Self.untouched))
    }

    // MARK: - Texture and Clarity

    /// A neutral scene whose log luminance is a vertical-stripe sinusoid of `period` pixels.
    private func stripes(period: Double) throws -> ImageSession {
        try makeSession(.bayer, width: 768, height: 256, noiseScale: 0) { x, _ in
            Float(0.2 * pow(2, 0.5 * sin(2 * .pi * Double(x) / period)))
        }
    }

    /// The stripes' amplitude in stops, away from the borders.
    private func amplitude(_ pixels: [SIMD3<Float>]) -> Float {
        let logs = (128 ..< 640).map { log2(pixels[128 * 768 + $0].y) }
        let mean = logs.reduce(0, +) / Float(logs.count)
        return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
    }

    private func gain(_ session: ImageSession, _ recipe: EditRecipe) throws -> Float {
        try amplitude(processed(session, recipe: recipe)) / amplitude(readLevel(session, level: 0))
    }

    @Test func `texture works on medium detail`() throws {
        var more = Self.untouched
        more[.texture] = 100
        var less = Self.untouched
        less[.texture] = -100
        let medium = try stripes(period: 6)
        #expect(try gain(medium, more) > 1.2)
        #expect(try gain(medium, less) < 0.85)
        #expect(try abs(gain(stripes(period: 128), more) - 1) < 0.05)
    }

    @Test func `clarity works on larger detail`() throws {
        var recipe = Self.untouched
        recipe[.clarity] = 100
        #expect(try gain(stripes(period: 48), recipe) > 1.1)
    }

    // MARK: - Masks

    /// A mask covering the left 45% of the photo, fading out by 55%.
    func leftHalf(_ parameter: ParameterID, _ value: Double) -> MaskLayer {
        let gradient = LinearMask(start: ImagePoint(x: 0.45, y: 0.5), end: ImagePoint(x: 0.55, y: 0.5))
        return MaskLayer(
            name: "Left",
            components: [MaskComponent(shape: .linear(gradient))],
            adjustments: [parameter: value],
        )
    }

    private func amplitude(_ pixels: [SIMD3<Float>], columns: Range<Int>) -> Float {
        let logs = columns.map { log2(pixels[128 * 768 + $0].y) }
        let mean = logs.reduce(0, +) / Float(logs.count)
        return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
    }

    @Test func `a mask's texture only works inside it`() throws {
        let session = try stripes(period: 6)
        var recipe = Self.untouched
        recipe.masks = [leftHalf(.localTexture, 100)]
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        let inside = amplitude(after, columns: 64 ..< 300) / amplitude(before, columns: 64 ..< 300)
        let outside = amplitude(after, columns: 468 ..< 704) / amplitude(before, columns: 468 ..< 704)
        #expect(inside > 1.2, "inside \(inside)")
        #expect(abs(outside - 1) < 0.02, "outside \(outside)")
    }

    @Test func `a mask's noise reduction only works inside it`() throws {
        let session = try makeSession(.bayer, width: 768, height: 256)
        var recipe = Self.untouched
        recipe.masks = [leftHalf(.localNoise, 100)]
        let after = try processed(session, recipe: recipe)
        let deviation = { (columns: Range<Int>) -> Float in
            let values = (32 ..< 224).flatMap { y in columns.map { after[y * 768 + $0].y } }
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let inside = deviation(32 ..< 300)
        let outside = deviation(468 ..< 736)
        #expect(inside < outside * 0.6, "inside \(inside), outside \(outside)")
    }

    // MARK: - Sensor cleanup

    @Test func `hot pixels are repaired`() throws {
        var random = SeededRandom(seed: 3)
        let hot = (0 ..< 40).map { _ in
            SIMD2(8 + Int(random.uniform() * 1000), 8 + Int(random.uniform() * 740))
        }
        let session = try makeSession(.bayer, width: 1024, height: 768, spikes: hot.map { ($0, 0.9) })
        #expect(session.repairedPixels == hot.count)
        let pixels = try readLevel(session, level: 0)
        for point in hot {
            let value = pixels[point.y * 1024 + point.x]
            #expect(value.max() < Self.level * 1.5, "\(point): \(value)")
        }
    }

    @Test func `clean noise and real highlights are left alone`() throws {
        #expect(try makeSession(.bayer, width: 1024, height: 768).repairedPixels == 0)
        #expect(try makeSession(.xTrans, width: 1024, height: 768).repairedPixels == 0)
        // A small highlight lights its neighbours too.
        let highlight = (-1 ... 1).flatMap { dy in (-1 ... 1).map { dx in (SIMD2(500 + dx, 400 + dy), Float(0.9)) } }
        #expect(try makeSession(.bayer, width: 1024, height: 768, spikes: highlight).repairedPixels == 0)
    }

    // MARK: - Highlights

    /// Bayer RGGB colour at a photosite.
    private static func bayerColor(_ x: Int, _ y: Int) -> Int {
        [0, 1, 1, 2][(y % 2) * 2 + x % 2]
    }

    @Test func `a clipped channel is rebuilt from its neighbours`() throws {
        // A reddish highlight (R:G:B = 1.25:1:0.8) whose red goes past the sensor's clip.
        let ratios: [Float] = [1.25, 1, 0.8]
        let session = try makeSession(.bayer, width: 512, height: 384, noiseScale: 0) { x, y in
            let r2 = Float((x - 256) * (x - 256) + (y - 192) * (y - 192))
            let level = 0.95 * exp(-r2 / (2 * 60 * 60))
            return min(ratios[Self.bayerColor(x, y)] * level, 1)
        }
        let centre = try readLevel(session, level: 0)[192 * 512 + 256]
        #expect(abs(centre.x / (1.25 * 0.95) - 1) < 0.05, "red \(centre.x)")
        #expect(abs(centre.x / centre.y / 1.25 - 1) < 0.05, "red to green \(centre.x / centre.y)")
    }

    @Test func `fully clipped areas stay neutral`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384, noiseScale: 0, asShot: SIMD3(2, 1, 1.5)) {
            x, y in
            let r2 = Float((x - 256) * (x - 256) + (y - 192) * (y - 192))
            return min(2 * exp(-r2 / (2 * 40 * 40)), 1)
        }
        let centre = try readLevel(session, level: 0)[192 * 512 + 256]
        let neutral = HighlightModel.clipFraction * 2
        #expect(abs(centre.x / neutral - 1) < 0.01 && abs(centre.y / neutral - 1) < 0.01, "\(centre)")
        #expect(abs(centre.z / neutral - 1) < 0.01, "\(centre)")
    }

    // MARK: - Gain maps

    @Test func `gain maps scale the mosaic before demosaicing`() throws {
        // Gains 1 at the left edge to 2 at the right, on every photosite.
        let ramp = GainMap(
            top: 0, left: 0, bottom: 256, right: 512, plane: 0, planes: 1, rowPitch: 1, columnPitch: 1,
            pointsV: 1, pointsH: 2, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [1, 2],
        )
        let session = try makeSession(.bayer, width: 512, height: 256, noiseScale: 0, gainMaps: [ramp])
        let pixels = try readLevel(session, level: 0)
        for x in [128, 384] {
            let expected = Self.level * (1 + Float(x) / 512)
            #expect(abs(pixels[128 * 512 + x].y / expected - 1) < 0.02, "x \(x): \(pixels[128 * 512 + x].y)")
        }
    }

    @Test func `the noise gain follows each channel's maps`() {
        // One map per Bayer site, as phones write them: R x2, greens x1.5 and x1.7, B x3.
        let maps = zip([(0, 0), (0, 1), (1, 0), (1, 1)], [Float(2), 1.5, 1.7, 3]).map { site, gain in
            GainMap(
                top: site.0, left: site.1, bottom: 64, right: 96, plane: 0, planes: 1, rowPitch: 2, columnPitch: 2,
                pointsV: 1, pointsH: 1, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1,
                gains: [gain],
            )
        }
        let field = NoiseGain.field(
            maps,
            width: 96,
            height: 64,
            pattern: CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2]),
        )
        #expect(field.width == 64 && field.height == 43)
        for gain in field.gains {
            #expect(abs(gain.x - 2) < 1e-5 && abs(gain.y - 1.6) < 1e-5 && abs(gain.z - 3) < 1e-5, "\(gain)")
        }
        let none = NoiseGain.field([], width: 96, height: 64, pattern: nil)
        #expect(none.gains == [SIMD4(1, 1, 1, 1)])
    }

    /// Lens shading amplifies the sensor noise with the signal; noise reduction must remove as
    /// much of it where the gain is high as where there is none.
    @Test func `noise reduction keeps up with gain-mapped noise`() throws {
        let (width, height) = (1024, 512)
        let right = GainMap(
            top: 0, left: width / 2, bottom: height, right: width, plane: 0, planes: 1, rowPitch: 1, columnPitch: 1,
            pointsV: 1, pointsH: 1, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [3],
        )
        let session = try makeSession(.bayer, width: width, height: height, gainMaps: [right])
        var recipe = Self.unsharpened
        recipe[.noiseLuminance] = 40
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        func remaining(_ columns: Range<Int>) -> Float {
            let rows = 32 ..< height - 32
            let pick = { (pixels: [SIMD3<Float>]) in rows.flatMap { y in columns.map { pixels[y * width + $0] } } }
            return statistics(of: pick(after)).deviation.y / statistics(of: pick(before)).deviation.y
        }
        let plain = remaining(32 ..< width / 2 - 64)
        let shaded = remaining(width / 2 + 64 ..< width - 32)
        #expect(plain < 0.6)
        #expect(abs(shaded / plain - 1) < 0.15, "noise left: \(plain) plain, \(shaded) behind a 3x gain")
    }

    // MARK: - Banding

    @Test func `banding offsets are subtracted before demosaicing`() throws {
        let (width, height) = (256, 256)
        let offsets = (0 ..< height).map { Float(($0 * 7919) % 13) - 6 }
        let banded = { (_: Int, y: Int) in Self.level + offsets[y] / (16383 - 512) }
        func rowSpread(_ session: ImageSession) throws -> Float {
            let pixels = try readLevel(session, level: 0)
            let means = (8 ..< height - 8).map { y in
                (8 ..< width - 8).reduce(Float(0)) { $0 + pixels[y * width + $1].y } / Float(width - 16)
            }
            return (means.max() ?? 0) - (means.min() ?? 0)
        }
        let plain = try rowSpread(makeSession(.bayer, width: width, height: height, noiseScale: 0, signal: banded))
        let corrected = try rowSpread(makeSession(
            .bayer, width: width, height: height, noiseScale: 0,
            banding: BandingCorrection(rows: offsets, columns: []), signal: banded,
        ))
        #expect(corrected < 0.2 * plain, "row spread \(corrected), was \(plain)")
    }

    // MARK: - Helpers

    /// `signal` is the scene per photosite (`level` by default), `noiseScale` scales the
    /// noise, and `spikes` overrides single photosites with a normalised value.
    func makeSession(
        _ sensor: SensorKind,
        width: Int,
        height: Int,
        noiseScale: Float = 1,
        asShot: SIMD3<Double> = SIMD3(1, 1, 1),
        gainMaps: [GainMap] = [],
        banding: BandingCorrection? = nil,
        profile: NoiseModel = DetailStageTests.noise,
        spikes: [(SIMD2<Int>, Float)] = [],
        signal: (Int, Int) -> Float = { _, _ in DetailStageTests.level },
    ) throws -> ImageSession {
        let layout: DecodedImage.Layout
        let channels: Int
        switch sensor {
        case .bayer:
            layout = .mosaic(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2]))
            channels = 1
        case .xTrans:
            layout = .mosaic(CFAPattern(width: 6, height: 6, colors: [
                1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1,
                1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1,
            ]))
            channels = 1
        case .linear, .bitmap:
            layout = .linearRGB
            channels = 3
        }
        let black: Float = 512
        let white: Float = 16383
        var random = SeededRandom(seed: 7)
        func raw(_ value: Float) -> UInt16 {
            UInt16(min(max(black + value * (white - black), 0), 65535).rounded())
        }
        var samples = (0 ..< width * height * channels).map { index in
            let value = signal((index / channels) % width, (index / channels) / width)
            let sigma = (Self.noise.a.x * value + Self.noise.b.x).squareRoot() * noiseScale
            return raw(value + sigma * random.gaussian())
        }
        for (point, value) in spikes {
            samples[(point.y * width + point.x) * channels] = raw(value)
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: layout, samples: samples,
            blackLevels: [Float](repeating: black, count: channels == 1 ? 4 : 3), whiteLevel: white,
            asShotMultipliers: asShot, cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = profile
        decoded.gainMaps = gainMaps
        decoded.banding = banding
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// One pyramid level read back as camera RGB.
    func readLevel(_ session: ImageSession, level: Int) throws -> [SIMD3<Float>] {
        let width = max(1, session.pyramid.width >> level)
        let height = max(1, session.pyramid.height >> level)
        return try readBack(session.pyramid, level: level, width: width, height: height)
    }

    func readBack(_ texture: any MTLTexture, level: Int, width: Int, height: Int) throws -> [SIMD3<Float>] {
        let rowBytes = width * 8
        let buffer = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0 ..< width * height).map { index in
            SIMD3(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
        }
    }

    /// The whole image through the detail stage at full resolution.
    func processed(_ session: ImageSession, recipe: EditRecipe) throws -> [SIMD3<Float>] {
        let stage = DetailStage(device: device, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        let size = session.orientedSize
        let output = try #require(try stage.process(
            recipe, session: session, region: .full, outputSize: size, commands: commands,
        ))
        commands.commit()
        commands.waitUntilCompleted()
        return try readBack(output.texture, level: 0, width: size.width, height: size.height)
    }

    func statistics(of pixels: [SIMD3<Float>]) -> (mean: SIMD3<Float>, deviation: SIMD3<Float>) {
        let count = Float(pixels.count)
        let mean = pixels.reduce(SIMD3<Float>.zero, +) / count
        let variance = pixels.reduce(SIMD3<Float>.zero) { $0 + ($1 - mean) * ($1 - mean) } / count
        return (mean, variance.squareRoot())
    }

    /// Stabilises and decomposes one level on the CPU, as the kernels do, and measures each
    /// scale's detail noise away from the borders.
    private func measureScaleNoise(_ session: ImageSession, level: Int) throws -> [SIMD3<Float>] {
        let width = max(1, session.pyramid.width >> level)
        let height = max(1, session.pyramid.height >> level)
        let a = session.noise.a
        let b = session.noise.b
        var current = try readLevel(session, level: level).map { value in
            let f = 2 * ((a * value + b).squareRoot() - b.squareRoot()) / a
            return SIMD3(
                (f.x + f.y + f.z) * 0.57735027,
                (f.x - f.z) * 0.70710678,
                (f.x - 2 * f.y + f.z) * 0.40824829,
            )
        }
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var sigmas: [SIMD3<Float>] = []
        for scale in 0 ..< DenoiseSettings.scaleCount {
            let step = 1 << scale
            var rows = current
            for y in 0 ..< height {
                for x in 0 ..< width {
                    var sum = SIMD3<Float>.zero
                    for i in -2 ... 2 {
                        let column = min(max(x + i * step, 0), width - 1)
                        sum += weights[i + 2] * current[y * width + column]
                    }
                    rows[y * width + x] = sum
                }
            }
            var coarse = rows
            var squares = SIMD3<Float>.zero
            var count: Float = 0
            let border = 2 * (step * 2 - 1) + 4
            for y in 0 ..< height {
                for x in 0 ..< width {
                    var sum = SIMD3<Float>.zero
                    for i in -2 ... 2 {
                        let row = min(max(y + i * step, 0), height - 1)
                        sum += weights[i + 2] * rows[row * width + x]
                    }
                    coarse[y * width + x] = sum
                    if x >= border, x < width - border, y >= border, y < height - border {
                        let detail = current[y * width + x] - sum
                        squares += detail * detail
                        count += 1
                    }
                }
            }
            sigmas.append((squares / count).squareRoot())
            current = coarse
        }
        return sigmas
    }
}

/// xorshift64* with Box–Muller, so tests are reproducible.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * uniform())
    }
}
