import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Exact greys through the develop kernel with no Base Look table. A bitmap's default edit shows
/// the file as it is, so every grey comes back as itself, never black.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct NeutralRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// The lint chart's grey-ramp column 697 decodes to exactly 27/64 in every channel. Through the
    /// tone curve it stays so neutral that its OKLab a and b come out exactly zero, which has no hue
    /// (atan2 gives NaN under fast math), and the pixel rendered black.
    @Test func `an exact grey of 27/64 renders as itself`() throws {
        let grey: Float = 27.0 / 64.0
        let session = try makeBitmap(width: 32, height: 32) { _, _ in Float16(grey) }
        for sharpen in [0.0, 40.0] {
            var recipe = EditRecipe()
            recipe[.sharpenAmount] = sharpen
            let pixels = try render(recipe, session: session)
            let worst = pixels.map { simd_reduce_max(simd_abs($0 - SIMD3(repeating: grey))) }.max() ?? 0
            #expect(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "sharpening \(sharpen)")
            #expect(worst < 0.002, "sharpening \(sharpen): off by \(worst)")
        }
    }

    /// Every grey a half float holds from 2⁻¹⁰ to 1, without sharpening. Each fills a 4×4 block of
    /// an image whose sides are powers of two, so the kernel reads the inside of every block exactly.
    @Test func `every exact grey renders as itself`() throws {
        let greys = (UInt16(0x1400) ... 0x3C00).map { Float16(bitPattern: $0) }
        let columns = 256
        let block = 4
        let rows = 64
        let session = try makeBitmap(width: columns * block, height: rows * block) { x, y in
            greys[min((y / block) * columns + x / block, greys.count - 1)]
        }
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 0
        let pixels = try render(recipe, session: session)
        var wrong: [(grey: Float, rendered: SIMD3<Float>)] = []
        for (index, grey) in greys.enumerated() {
            let x = (index % columns) * block + 1
            let y = (index / columns) * block + 1
            let rendered = pixels[y * columns * block + x]
            let expected = Float(grey)
            if !(simd_reduce_max(simd_abs(rendered - SIMD3(repeating: expected))) <= 0.002 + 0.01 * expected) {
                wrong.append((expected, rendered))
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) greys render wrongly: \(wrong.prefix(8))")
    }

    /// Shadows that Blacks clips to an exact zero are an exact grey too: under a blue shadow grade
    /// they turn blue, as the rest of the shadows do.
    @Test func `clipped black takes the shadows' colour grade`() throws {
        let session = try makeBitmap(width: 32, height: 32) { _, _ in 0.0002 }
        var recipe = EditRecipe()
        recipe[.blacks] = -20
        recipe[.gradeShadowsHue] = 220
        recipe[.gradeShadowsSaturation] = 50
        let pixels = try render(recipe, session: session)
        #expect(pixels.allSatisfy { $0.z > 0 && $0.z > $0.x }, "black renders \(pixels[0])")
    }

    // MARK: - Helpers (as ToneRenderTests')

    private func render(_ recipe: EditRecipe, session: ImageSession) throws -> [SIMD3<Float>] {
        let engine = try RedlampEngine()
        let size = session.orientedSize
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(size.width * size.height)
        for y in 0 ..< size.height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< size.width {
                pixels.append(SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2])))
            }
        }
        return pixels
    }

    /// A bitmap as `BitmapDecoder` leaves it: linear sRGB halves, the same grey in every channel.
    private func makeBitmap(width: Int, height: Int, grey: (Int, Int) -> Float16) throws -> ImageSession {
        var samples = [UInt16](repeating: Float16(1).bitPattern, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = grey(x, y).bitPattern
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 4 + channel] = value
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearSRGBHalf, samples: samples,
            blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic-grey.png"), pixelSize: PixelSize(width: width, height: height),
                isRaw: false, sensorDescription: "PNG",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}
