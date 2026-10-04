import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd
import Testing
@testable import RedlampEngine

/// Process 11's ladder of linear luminance (`Ladder`), on synthetic sensors through the real
/// session builder.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DetailLadderTests {
    let base: DetailStageTests

    init() throws {
        base = try DetailStageTests()
    }

    /// A scene with detail at every scale the ladder spans.
    static func scene(_ x: Int, _ y: Int) -> Float {
        let (x, y) = (Double(x), Double(y))
        return Float(0.2 + 0.08 * sin(x / 1.7) * cos(y / 2.3) + 0.06 * sin(x / 9 + y / 13) + 0.05 * cos(y / 31))
    }

    @Test func `the bands and residual add up to the luminance`() throws {
        let session = try base.makeSession(.bayer, width: 256, height: 192, signal: Self.scene)
        let (bands, residual) = try ladder(session, level: 0)
        let luma = DetailStage.luma(session)
        let source = try base.readLevel(session, level: 0)
        var worst: Float = 0
        for (index, rgb) in source.enumerated() {
            let y = max(simd_dot(rgb, SIMD3(luma.x, luma.y, luma.z)), 0)
            let sum = residual[index] + bands[index].sum()
            worst = max(worst, abs(sum - y))
        }
        // Half floats round each band and the residual to about 1e-4 at this level.
        #expect(worst < 5e-4, "largest difference \(worst)")
    }

    @Test func `each band is the B3 spline's detail at its scale`() throws {
        let (width, height) = (160, 128)
        let session = try base.makeSession(.bayer, width: width, height: height, signal: Self.scene)
        let (bands, residual) = try ladder(session, level: 0)
        let luma = DetailStage.luma(session)
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var current = try base.readLevel(session, level: 0).map { max(simd_dot($0, SIMD3(luma.x, luma.y, luma.z)), 0) }
        for scale in 0 ..< Ladder.scaleCount {
            let step = 1 << scale
            var rows = current
            for y in 0 ..< height {
                for x in 0 ..< width {
                    rows[y * width + x] = (-2 ... 2).reduce(0) { sum, i in
                        sum + weights[i + 2] * current[y * width + min(max(x + i * step, 0), width - 1)]
                    }
                }
            }
            var coarse = rows
            var worst: Float = 0
            for y in 0 ..< height {
                for x in 0 ..< width {
                    coarse[y * width + x] = (-2 ... 2).reduce(0) { sum, i in
                        sum + weights[i + 2] * rows[min(max(y + i * step, 0), height - 1) * width + x]
                    }
                    let expected = current[y * width + x] - coarse[y * width + x]
                    worst = max(worst, abs(bands[y * width + x][scale] - expected))
                }
            }
            #expect(worst < 1e-3, "scale \(scale): largest difference \(worst)")
            current = coarse
        }
        let worst = zip(current, residual).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-3, "residual: largest difference \(worst)")
    }

    @Test func `a region's ladder is the whole frame's away from its edges`() throws {
        let (width, height) = (256, 192)
        let session = try base.makeSession(.bayer, width: width, height: height, signal: Self.scene)
        let whole = try ladder(session, level: 0)
        let origin = SIMD2(70, 50)
        let size = SIMD2(120, 100)
        let region = try ladder(session, level: 0, origin: origin, size: size)
        var worst: Float = 0
        for y in Ladder.reach ..< size.y - Ladder.reach {
            for x in Ladder.reach ..< size.x - Ladder.reach {
                let inRegion = region.bands[y * size.x + x]
                let inWhole = whole.bands[(y + origin.y) * width + x + origin.x]
                worst = max(worst, simd_abs(inRegion - inWhole).max())
            }
        }
        #expect(worst < 1e-4, "largest difference \(worst)")
    }

    /// The measured noise in each band per unit of the luminance's noise must match
    /// `NoiseCalibration.ladderSigmas`, which the separator's thresholds are scaled by. Slow, so it
    /// runs with the noise calibration: `TEST_RUNNER_REDLAMP_CALIBRATE_NOISE=1`. It prints the
    /// table to paste.
    @Test(.enabled(if: DetailStageTests.calibrating), arguments: [SensorKind.bayer, .xTrans, .linear])
    func `ladder calibration matches the pipeline`(sensor: SensorKind) throws {
        let session = try base.makeSession(sensor, width: 2048, height: 1536)
        let luma = DetailStage.luma(session)
        let weights = SIMD3(luma.x, luma.y, luma.z)
        for level in 0 ... 2 {
            let (bands, _) = try ladder(session, level: level)
            let pixels = try base.readLevel(session, level: level)
            let mean = pixels.reduce(SIMD3<Float>.zero, +) / Float(pixels.count)
            let variance = session.noise.a * simd_max(mean, .zero) + session.noise.b
            let lumaNoise = simd_dot(weights * weights, variance).squareRoot()
            let width = session.pyramid.width >> level
            let height = session.pyramid.height >> level
            let border = 2 * Ladder.reach
            var squares = SIMD4<Float>.zero
            var sums = SIMD4<Float>.zero
            var count: Float = 0
            for y in border ..< height - border {
                for x in border ..< width - border {
                    let band = bands[y * width + x]
                    squares += band * band
                    sums += band
                    count += 1
                }
            }
            let averages = sums / count
            let measured = (squares / count - averages * averages).squareRoot() / lumaNoise
            let table = NoiseCalibration.ladderSigmas(sensor: sensor, level: level)
            print(String(
                format: "ladder calibration \(sensor) level \(level): SIMD4(%.4f, %.4f, %.4f, %.4f)",
                measured.x, measured.y, measured.z, measured.w,
            ))
            for scale in 0 ..< Ladder.scaleCount {
                let ratio = measured[scale] / table[scale]
                #expect(abs(ratio - 1) < 0.15, "\(sensor) level \(level) band \(scale): \(ratio)")
            }
        }
    }

    // MARK: - Helpers

    /// The ladder of the pyramid's luminance over a work area, read back.
    func ladder(
        _ session: ImageSession,
        level: Int,
        origin: SIMD2<Int> = .zero,
        size: SIMD2<Int>? = nil,
    ) throws -> (bands: [SIMD4<Float>], residual: [Float]) {
        let levelSize = SIMD2(session.pyramid.width >> level, session.pyramid.height >> level)
        let work = DetailStage.WorkArea(level: level, origin: origin, size: size ?? levelSize)
        let stage = DetailStage(device: base.device, kernels: base.kernels)
        let commands = try #require(base.queue.makeCommandBuffer())
        let ladder = try stage.makeLadder(work, denoised: false)
        let encoder = try #require(commands.makeComputeCommandEncoder())
        try stage.encodeLadder(
            session: session, source: ladder.source(session, work: work), work: work, into: ladder, encoder: encoder,
        )
        encoder.endEncoding()
        let bands = try halves(ladder.bands, channels: 4, commands: commands)
        let residual = try halves(ladder.residual, channels: 1, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        let count = work.size.x * work.size.y
        let read = bands()
        return (
            (0 ..< count).map { SIMD4(read[$0 * 4], read[$0 * 4 + 1], read[$0 * 4 + 2], read[$0 * 4 + 3]) },
            residual(),
        )
    }

    func halves(_ texture: any MTLTexture, channels: Int, commands: any MTLCommandBuffer) throws -> () -> [Float] {
        let rowBytes = texture.width * channels * 2
        let buffer = try #require(base.device.makeBuffer(
            length: rowBytes * texture.height,
            options: .storageModeShared,
        ))
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height,
        )
        blit.endEncoding()
        let count = texture.width * texture.height * channels
        return {
            let values = buffer.contents().assumingMemoryBound(to: Float16.self)
            return (0 ..< count).map { Float(values[$0]) }
        }
    }
}
