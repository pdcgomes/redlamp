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

    @Test func `masking keeps sharpening off flat noise`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384)
        var sharpened = Self.untouched
        sharpened[.sharpenAmount] = 100
        var masked = sharpened
        masked[.sharpenMasking] = 100
        let before = try statistics(of: readLevel(session, level: 0)).deviation.y
        let open = try statistics(of: processed(session, recipe: sharpened)).deviation.y
        let protected = try statistics(of: processed(session, recipe: masked)).deviation.y
        #expect(open > before * 1.05)
        #expect(abs(protected / before - 1) < 0.01)
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

    // MARK: - Helpers

    /// `signal` is the scene per photosite (`level` by default), `noiseScale` scales the
    /// noise, and `spikes` overrides single photosites with a normalised value.
    private func makeSession(
        _ sensor: SensorKind,
        width: Int,
        height: Int,
        noiseScale: Float = 1,
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
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = Self.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// One pyramid level read back as camera RGB.
    private func readLevel(_ session: ImageSession, level: Int) throws -> [SIMD3<Float>] {
        let width = max(1, session.pyramid.width >> level)
        let height = max(1, session.pyramid.height >> level)
        return try readBack(session.pyramid, level: level, width: width, height: height)
    }

    private func readBack(_ texture: any MTLTexture, level: Int, width: Int, height: Int) throws -> [SIMD3<Float>] {
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
    private func processed(_ session: ImageSession, recipe: EditRecipe) throws -> [SIMD3<Float>] {
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

    private func statistics(of pixels: [SIMD3<Float>]) -> (mean: SIMD3<Float>, deviation: SIMD3<Float>) {
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
