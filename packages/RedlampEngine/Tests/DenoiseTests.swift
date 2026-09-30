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
struct DenoiseTests {
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
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 60
        recipe[.noiseColor] = 50
        let before = try statistics(of: readLevel(session, level: 0))
        let after = try statistics(of: denoised(session, recipe: recipe))
        for channel in 0 ..< 3 {
            #expect(abs(after.mean[channel] / before.mean[channel] - 1) < 0.01, "mean \(channel)")
            #expect(after.deviation[channel] < before.deviation[channel] * 0.4, "deviation \(channel)")
        }
    }

    @Test func `zero thresholds reproduce the pyramid`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384)
        let source = try readLevel(session, level: 0)
        var nearlyOff = EditRecipe()
        // Keeps the stage running with thresholds that remove nothing.
        nearlyOff[.noiseLuminance] = 0.001
        nearlyOff[.noiseColor] = 0
        let passed = try denoised(session, recipe: nearlyOff)
        var worst: Float = 0
        for index in stride(from: 0, to: source.count, by: 7) {
            worst = max(worst, simd_abs(source[index] - passed[index]).max())
        }
        #expect(worst < 2e-3)
    }

    // MARK: - Helpers

    private func makeSession(_ sensor: SensorKind, width: Int, height: Int) throws -> ImageSession {
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
        let sigma = (Self.noise.a.x * Self.level + Self.noise.b.x).squareRoot()
        let samples = (0 ..< width * height * channels).map { _ in
            let value = Self.level + sigma * random.gaussian()
            return UInt16(min(max(black + value * (white - black), 0), 65535).rounded())
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

    /// The whole image through the denoise stage at full resolution.
    private func denoised(_ session: ImageSession, recipe: EditRecipe) throws -> [SIMD3<Float>] {
        let denoiser = Denoiser(device: device, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        let size = session.orientedSize
        let output = try #require(try denoiser.denoise(
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
