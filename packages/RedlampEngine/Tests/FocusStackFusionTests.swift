import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

extension FocusStackTests {
    /// Building a Laplacian pyramid and collapsing it returns the image: pyrDown and the
    /// upsampling in both directions agree.
    @Test func `a Laplacian pyramid collapses back to its image`() throws {
        let (width, height) = (203, 151)
        let image = Scene(seed: 4, width: Float(width), height: Float(height), detail: 0.05)
            .render(width: width, height: height)
        let input = try texture(image)
        var sizes = [(width, height)]
        for _ in 0 ..< 4 {
            try sizes.append(((#require(sizes.last?.0) + 1) / 2, (#require(sizes.last?.1) + 1) / 2))
        }
        func make(_ size: (Int, Int)) throws -> any MTLTexture {
            try texture(LumaImage(width: size.0, height: size.1, pixels: .init(repeating: 0, count: size.0 * size.1)))
        }
        let gaussians = try [input] + sizes.dropFirst().map(make)
        let details = try sizes.dropLast().map(make)
        let outputs = try sizes.dropLast().map(make)
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        func run(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            encoder.dispatchGrid(width: textures.last!.width, height: textures.last!.height, pipeline: pipeline)
        }
        for level in 0 ..< 4 {
            run(kernels.stackPyramidDown, [gaussians[level], gaussians[level + 1]])
        }
        for level in 0 ..< 4 {
            run(kernels.stackLaplacian, [gaussians[level], gaussians[level + 1], details[level]])
        }
        var current = gaussians[4]
        for level in (0 ..< 4).reversed() {
            run(kernels.stackCollapse, [current, details[level], outputs[level]])
            current = outputs[level]
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let restored = read(outputs[0])
        let worst = zip(restored, image.pixels).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-4, "worst \(worst)")
    }

    /// Five frames of a two-plane scene, focused from near to far: every strategy's result is
    /// closer to the all-sharp scene than the best single frame.
    @Test func `fusion beats the best single frame on a synthetic stack`() throws {
        let (width, height) = (640, 480)
        let depth = { (x: Int, y: Int) -> Float in (x < width / 2) == (y < height / 2) ? 1 : 3 }
        let frames = syntheticStack(frames: 5, width: width, height: height, depth: depth)
        let sharp = Scene(seed: 21, width: Float(width), height: Float(height), detail: 0.08)
            .render(width: width, height: height)
        func psnr(_ values: [Float]) -> Double {
            var sum: Double = 0
            var count = 0
            for y in 16 ..< height - 16 {
                for x in 16 ..< width - 16 {
                    let d = Double(values[y * width + x] - sharp[x, y])
                    sum += d * d
                    count += 1
                }
            }
            return 10 * log10(1 / (sum / Double(count)))
        }
        let bestSingle = try #require(frames.map { psnr($0.pixels) }.max())
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        let textures = try frames.map(texture)
        for strategy in FocusStackStrategy.allCases {
            let result = try stacker
                .merge(frameCount: 5, settings: StackMergeSettings(strategy: strategy)) { textures[$0] }
            let fused = try read(copyToShared(result.fused))
            let score = psnr(fused)
            print(String(format: "%@: %.2f dB (best single frame %.2f dB)", strategy.rawValue, score, bestSingle))
            #expect(score > bestSingle + 3, "\(strategy): \(score) dB against \(bestSingle) dB")
        }
    }

    /// Frames that darken through the stack (focus breathing changes exposure) over a flat, noisy
    /// scene: nothing is sharp, so no frame should win the depth solve by being brighter.
    @Test func `brightness differences don't decide the depth`() throws {
        let (width, height) = (320, 240)
        var state: UInt64 = 11
        func noise() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        let frames = (0 ..< 5).map { index in
            let gain = 1 - 0.06 * Float(index)
            return LumaImage(width: width, height: height, pixels: (0 ..< width * height).map { _ in
                gain * (0.3 + 0.02 * noise())
            })
        }
        let textures = try frames.map(texture)
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        let result = try stacker.merge(frameCount: 5, settings: StackMergeSettings(strategy: .smooth)) { textures[$0] }
        let brightest = Float(result.depth.depth.count { $0 < 0.5 }) / Float(result.depth.depth.count)
        #expect(brightest < 0.5, "\(brightest) of the depth map chose the brightest frame")
    }

    @Test func `unknown depth is filled from its surroundings`() {
        // Known: frame 0 in the left quarter, frame 4 in the right quarter; the middle is unknown.
        let (width, height) = (40, 10)
        let known = (0 ..< width * height).map { $0 % width < 10 || $0 % width >= 30 }
        let values = (0 ..< width * height).map { $0 % width < 10 ? Float(0) : 4 }
        let filled = StackDepthSolver.fill(values, known: known, width: width, height: height, empty: 2)
        let row = Array(filled[5 * width ..< 6 * width])
        #expect(row[0 ..< 10].allSatisfy { $0 == 0 } && row[30...].allSatisfy { $0 == 4 })
        #expect(zip(row[10 ..< 29], row[11 ..< 30]).allSatisfy { $0 <= $1 + 1e-4 }, "\(row)")
        #expect(row[12] < 2 && row[27] > 2)
        let nothing = StackDepthSolver.fill(
            values,
            known: known.map { _ in false },
            width: width,
            height: height,
            empty: 2,
        )
        #expect(nothing.allSatisfy { $0 == 2 })
    }

    /// The red channel of a float texture.
    func read(_ texture: any MTLTexture) -> [Float] {
        var pixels = [SIMD4<Float>](repeating: .zero, count: texture.width * texture.height)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: texture.width * 16,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
            )
        }
        return pixels.map(\.x)
    }

    /// A shared `.rgba32Float` copy of a private texture.
    func copyToShared(_ source: any MTLTexture) throws -> any MTLTexture {
        let destination = try texture(LumaImage(
            width: source.width, height: source.height, pixels: .init(
                repeating: 0,
                count: source.width * source.height,
            ),
        ))
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.stackFinish)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(source, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.dispatchGrid(width: source.width, height: source.height, pipeline: kernels.stackFinish)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return destination
    }
}
