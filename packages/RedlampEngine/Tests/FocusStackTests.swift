import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Focus stacking's engine pieces, from frame decoding to fusion.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct FocusStackTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A stacking frame is exactly a session's full-resolution level: same normalisation, hot-pixel
    /// repair, highlight reconstruction and demosaic, without mipmaps or analysis.
    @Test(.enabled(if: !EngineSmokeTests.fixtures.isEmpty))
    func `a demosaiced frame matches the session's first level`() throws {
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        for url in EngineSmokeTests.fixtures where SupportedFormats.isRaw(url) {
            let decoded = try ImageDecoder.decode(url)
            let frame = try builder.demosaic(decoded)
            let session = try builder.build(decoded)
            #expect(frame.balance == session.balanceMultipliers, "\(url.lastPathComponent)")
            let a = try halves(frame.texture, level: 0)
            let b = try halves(session.pyramid, level: 0)
            #expect(a == b, "\(url.lastPathComponent): frame differs from the session's level 0")
        }
    }

    // MARK: - Alignment

    @Test func `similarity composition and inverse`() {
        let p = Similarity(a: 1.03, b: 0.02, tx: 5, ty: -3)
        let q = Similarity(a: 0.98, b: -0.01, tx: -2, ty: 7)
        let (x, y) = q.composed(after: p).apply(100, 50)
        let (px, py) = p.apply(100, 50)
        let (qx, qy) = q.apply(px, py)
        #expect(abs(x - qx) < 1e-3 && abs(y - qy) < 1e-3)
        let (ix, iy) = p.inverse.apply(px, py)
        #expect(abs(ix - 100) < 1e-3 && abs(iy - 50) < 1e-3)
    }

    /// A textured scene as a continuous function, so any transform of it can be rendered exactly.
    struct Scene {
        struct Blob {
            var x: Float
            var y: Float
            var sigma: Float
            var amplitude: Float
        }

        var blobs: [Blob] = []

        init(seed: UInt64, width: Float, height: Float) {
            var state = seed
            func next() -> Float {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(state >> 40) / Float(1 << 24)
            }
            for _ in 0 ..< 60 {
                blobs.append(Blob(
                    x: next() * width,
                    y: next() * height,
                    sigma: 3 + 25 * next(),
                    amplitude: next() - 0.3,
                ))
            }
        }

        func value(_ x: Float, _ y: Float) -> Float {
            var sum: Float = 0.5 + 0.05 * sin(x / 7) * cos(y / 11)
            for blob in blobs {
                let d2 = (x - blob.x) * (x - blob.x) + (y - blob.y) * (y - blob.y)
                sum += blob.amplitude * exp(-d2 / (2 * blob.sigma * blob.sigma))
            }
            return sum
        }

        /// The scene seen through `transform` (reference to frame coordinates), blurred by a box of
        /// `blur` pixels and scaled by `gain`.
        func render(width: Int, height: Int, transform: Similarity = .identity, blur: Int = 0, gain: Float = 1)
            -> LumaImage {
            let inverse = transform.inverse
            var sharp = [Float](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let (sx, sy) = inverse.apply(Float(x), Float(y))
                    sharp[y * width + x] = value(sx, sy)
                }
            }
            var pixels = sharp
            for y in 0 ..< height {
                for x in 0 ..< width {
                    var sum: Float = 0
                    var count: Float = 0
                    for dy in -blur ... blur {
                        for dx in -blur ... blur {
                            let (sx, sy) = (min(max(x + dx, 0), width - 1), min(max(y + dy, 0), height - 1))
                            sum += sharp[sy * width + sx]
                            count += 1
                        }
                    }
                    pixels[y * width + x] = gain * sum / count
                }
            }
            return LumaImage(width: width, height: height, pixels: pixels)
        }
    }

    /// Focus breathing (2% scale), a slight rotation and a shift are recovered to a few hundredths
    /// of a pixel, although the frame is blurrier and brighter than the template.
    @Test func `ECC recovers a known similarity despite blur and gain`() {
        let (width, height) = (640, 480)
        let scene = Scene(seed: 5, width: Float(width), height: Float(height))
        let truth = Similarity(a: 1.02 * cos(0.004), b: 1.02 * sin(0.004), tx: 3.3, ty: -2.1)
        let template = scene.render(width: width, height: height)
        let frame = scene.render(width: width, height: height, transform: truth, blur: 1, gain: 1.15)
        let start = Date()
        let result = ECCAligner.align(template: template, image: frame)
        print(String(format: "ECC at 640 x 480: %.0f ms", Date().timeIntervalSince(start) * 1000))
        var worst: Float = 0
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            let (ex, ey) = truth.apply(Float(x), Float(y))
            let (rx, ry) = result.transform.apply(Float(x), Float(y))
            worst = max(worst, hypot(ex - rx, ey - ry))
        }
        #expect(worst < 0.05, "worst corner error \(worst) px, correlation \(result.correlation)")
        #expect(result.correlation > 0.95)
    }

    /// Six frames with growing focus breathing (0 to 4% magnification) and small shifts: the
    /// magnified end becomes the reference, and every frame's transform to it is recovered.
    @Test func `the aligner picks the narrowest view and recovers each frame`() {
        let (width, height) = (480, 360)
        let scene = Scene(seed: 9, width: Float(width), height: Float(height))
        let truths = (0 ..< 6).map { index in
            let scale = 1 + 0.008 * Float(index)
            return Similarity(
                a: scale,
                b: 0.0005 * Float(index),
                tx: 1.5 * Float(index % 2) - 0.4,
                ty: 0.7 * Float(index),
            )
        }
        // Exposure flicker: frame i is 2% brighter than frame i - 1.
        let exposures = (0 ..< 6).map { 0.6 * (1 + 0.02 * Float($0)) }
        let frames = truths.enumerated().map { index, truth in
            let image = scene.render(
                width: width, height: height, transform: truth, blur: index % 3, gain: exposures[index],
            )
            return FrameAnalysis(
                width: width, height: height, rgb: image.pixels.map { SIMD3(repeating: max($0, 0)) }, factor: 1,
            )
        }
        let alignment = StackAligner.align(frames)
        #expect(alignment.reference == 5)
        // truth_i maps scene to frame i; reference pixels to frame i is truth_i after truth_ref^-1.
        let toScene = truths[alignment.reference].inverse
        var worst: Float = 0
        for (index, truth) in truths.enumerated() {
            let expected = truth.composed(after: toScene)
            for (x, y) in [(40, 40), (width - 40, 40), (40, height - 40), (width - 40, height - 40)] {
                let (ex, ey) = expected.apply(Float(x), Float(y))
                let (rx, ry) = alignment.transforms[index].apply(Float(x), Float(y))
                worst = max(worst, hypot(ex - rx, ey - ry))
            }
        }
        #expect(worst < 0.08, "worst error \(worst) px; correlations \(alignment.correlations)")
        for index in truths.indices {
            let expected = exposures[alignment.reference] / exposures[index]
            #expect(abs(alignment.gains[index].y / expected - 1) < 0.01, "gain \(index): \(alignment.gains[index])")
        }
    }

    /// Warping a frame by its true transform reproduces the reference, up to interpolation.
    @Test func `the GPU warp resamples a frame into the reference`() throws {
        let (width, height) = (320, 240)
        let scene = Scene(seed: 3, width: Float(width), height: Float(height))
        let truth = Similarity(a: 0.97, b: 0.003, tx: 4.2, ty: -1.7)
        let reference = scene.render(width: width, height: height)
        let frame = scene.render(width: width, height: height, transform: truth)
        let source = try texture(frame)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        try stacker.encodeWarp(source, transform: truth, gain: SIMD3(repeating: 1), into: output, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        pixels.withUnsafeMutableBytes {
            output.getBytes(
                $0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            )
        }
        var worst: Float = 0
        for y in 20 ..< height - 20 {
            for x in 20 ..< width - 20 {
                let value = pixels[y * width + x]
                #expect(value.w == 1)
                worst = max(worst, abs(value.x - reference[x, y]))
            }
        }
        #expect(worst < 0.01, "worst difference \(worst)")
    }

    /// A grey `.rgba32Float` texture of a luma image, readable by the kernels.
    func texture(_ image: LumaImage) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: image.width, height: image.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let rgba = image.pixels.map { SIMD4<Float>($0, $0, $0, 1) }
        rgba.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: image.width * 16,
            )
        }
        return texture
    }

    /// The raw half-float bits of one level, for exact comparison.
    func halves(_ texture: any MTLTexture, level: Int) throws -> [UInt16] {
        let width = max(1, texture.width >> level)
        let height = max(1, texture.height >> level)
        let rowBytes = width * 8
        let buffer = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pointer = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
    }
}
