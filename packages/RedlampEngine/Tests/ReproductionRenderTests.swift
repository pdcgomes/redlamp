import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Redlamp Reproduction (TON-39) has no tone curve, so every tone up to white renders at its scene
/// value. Through the real engine on synthetic photos, whose values are the scene's.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ReproductionRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A ColorChecker's grey row as luminances: Black 2 to White 9.5 by BabelColor's L*.
    static let greyRow: [Float] = [20.5, 35.7, 50.9, 66.8, 81.3, 96.5].map(luminance(lstar:))
    static let block = 32

    static func luminance(lstar: Float) -> Float {
        lstar > 8 ? pow((lstar + 16) / 116, 3) : lstar / 903.3
    }

    /// Redlamp Reproduction with an anchor of 0: the synthetic raws hold the scene's own values.
    static func reproduction(amount: Double = 100, anchor: Double? = 0) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.baseLook = BuiltInBaseLook.reproduction.reference.withAmount(amount)
        recipe.exposureAnchor = anchor.map { ExposureAnchor(stops: $0, source: .target, camera: nil) }
        return recipe
    }

    /// The colour's hue on the RGB hexagon, in degrees, which keeping each channel's place between
    /// the smallest and largest keeps.
    static func hue(_ c: SIMD3<Float>) -> Float {
        let hi = c.max()
        let lo = c.min()
        guard hi - lo > 1e-6 else { return 0 }
        let sector: Float = if hi == c.x {
            (c.y - c.z) / (hi - lo)
        } else if hi == c.y {
            2 + (c.z - c.x) / (hi - lo)
        } else {
            4 + (c.x - c.y) / (hi - lo)
        }
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Each patch's middle pixel.
    func patches(_ pixels: [SIMD3<Float>], count: Int) -> [SIMD3<Float>] {
        (0 ..< count).map { pixels[(Self.block / 2) * count * Self.block + $0 * Self.block + Self.block / 2] }
    }

    /// The engine's half-float stages hold a value to about 0.25% at the defaults (0.06 to 0.18%
    /// without sharpening and noise reduction), under 0.1 L*.
    @Test func `a raw grey scale renders at its scene values`() throws {
        let row = Self.greyRow
        let session = try makeRaw(width: Self.block * row.count, height: Self.block) { x, _ in
            SIMD3(repeating: row[x / Self.block])
        }
        let rendered = try patches(render(Self.reproduction(), session: session), count: row.count)
        for (value, pixel) in zip(row, rendered) {
            let error = simd_reduce_max(simd_abs(pixel - SIMD3(repeating: value)))
            #expect(error <= 0.0001 + 0.003 * value, "scene \(value) renders \(pixel)")
        }
    }

    @Test func `above white each channel clips, keeping the hue`() throws {
        let session = try makeRaw(width: Self.block, height: Self.block) { _, _ in SIMD3(0.5, 0.3, 0.12) }
        var recipe = Self.reproduction()
        let within = try patches(render(recipe, session: session), count: 1)[0]
        recipe[.exposure] = 2
        let above = try patches(render(recipe, session: session), count: 1)[0]
        #expect(within.max() < 0.9 && 4 * within.max() > 1.5, "the colour is below white, four times it far above")
        #expect(abs(above.max() - 1) < 0.002, "its brightest channel clips at white: \(above)")
        #expect(
            abs(above.min() - 4 * within.min()) < 0.002,
            "its darkest channel keeps its light: \(above) from \(within)",
        )
        #expect(abs(Self.hue(above) - Self.hue(within)) < 0.5, "hue \(Self.hue(above))° from \(Self.hue(within))°")
    }

    @Test func `its Amount mixes the curve in: 0 is Redlamp Color, 100 or more has none`() throws {
        let row = Self.greyRow
        let session = try makeRaw(width: Self.block * row.count, height: Self.block) { x, _ in
            SIMD3(repeating: row[x / Self.block])
        }
        let color = try render(EditRecipe(), session: session)
        let none = try render(Self.reproduction(amount: 0), session: session)
        let worst = zip(color, none).map { simd_reduce_max(simd_abs($0 - $1)) }.max() ?? 1
        #expect(worst <= 1e-6, "Amount 0 differs from Redlamp Color by \(worst)")
        let half = try patches(render(Self.reproduction(amount: 50), session: session), count: row.count)
        let full = try render(Self.reproduction(), session: session)
        for ((curved, straight), mixed) in zip(
            zip(patches(color, count: row.count), patches(full, count: row.count)),
            half,
        ) {
            #expect(
                simd_reduce_max(simd_abs(mixed - (curved + straight) / 2)) < 0.002,
                "\(mixed) between \(curved) and \(straight)",
            )
        }
        let double = try render(Self.reproduction(amount: 200), session: session)
        #expect(double == full, "Amount 200 renders as 100")
    }

    @Test func `without an anchor a grey the typical camera meters renders at 18%`() throws {
        let metered = Float(0.18 * pow(2, -ExposureAnchor.typicalStops))
        let session = try makeRaw(width: Self.block, height: Self.block) { _, _ in SIMD3(repeating: metered) }
        let rendered = try patches(render(Self.reproduction(anchor: nil), session: session), count: 1)[0]
        #expect(simd_reduce_max(simd_abs(rendered - SIMD3(repeating: 0.18))) < 0.0006, "renders \(rendered)")
    }

    @Test func `the anchor takes BaselineExposure's place only under the look`() throws {
        let row = Self.greyRow
        func session(baseline: Double) throws -> ImageSession {
            try makeRaw(width: Self.block * row.count, height: Self.block, baselineExposure: baseline) { x, _ in
                SIMD3(repeating: row[x / Self.block])
            }
        }
        let dng = try session(baseline: 0.5)
        var lifted = EditRecipe()
        lifted[.exposure] = 0.5
        #expect(
            try render(EditRecipe(), session: dng) == render(lifted, session: session(baseline: 0)),
            "Redlamp Color adds it",
        )
        let rendered = try patches(render(Self.reproduction(), session: dng), count: row.count)
        for (value, pixel) in zip(row, rendered) {
            #expect(abs(pixel.y - value) <= 0.0001 + 0.003 * value, "scene \(value) renders \(pixel) without it")
        }
    }

    @Test func `Auto measures the light at the exposure the look renders with`() throws {
        let session = try makeRaw(width: 64, height: 64, baselineExposure: 0.5) { x, y in
            SIMD3(repeating: (x + y) % 2 == 0 ? 0.02 : 0.08)
        }
        let color = ImageAnalysis.autoTone(session: session, recipe: EditRecipe())[.exposure]
        let matched = ImageAnalysis.autoTone(session: session, recipe: Self.reproduction(anchor: 0.5))[.exposure]
        let brighter = ImageAnalysis.autoTone(session: session, recipe: Self.reproduction(anchor: 1.5))[.exposure]
        #expect(color != nil && matched == color, "an anchor equal to BaselineExposure measures the same")
        #expect(
            (brighter ?? 0) < (color ?? 0),
            "a stop more anchor asks for less Exposure: \(brighter ?? 0) from \(color ?? 0)",
        )
    }

    @Test func `a bitmap renders as the file, and Exposure scales its own light`() throws {
        let greys: [Float] = [0.02, 0.1, 0.18, 0.4, 0.9]
        let session = try makeBitmap(width: Self.block * greys.count, height: Self.block) { x, _ in
            Float16(greys[x / Self.block])
        }
        var recipe = Self.reproduction()
        recipe[.sharpenAmount] = 0
        let rendered = try patches(render(recipe, session: session), count: greys.count)
        for (grey, pixel) in zip(greys, rendered) {
            #expect(
                simd_reduce_max(simd_abs(pixel - SIMD3(repeating: grey))) <= 0.0002 + 0.0015 * grey,
                "\(grey) renders \(pixel)",
            )
        }
        recipe[.exposure] = 1
        let brighter = try patches(render(recipe, session: session), count: greys.count)
        for (grey, pixel) in zip(greys, brighter) {
            let expected = min(2 * grey, 1)
            #expect(
                simd_reduce_max(simd_abs(pixel - SIMD3(repeating: expected))) <= 0.0002 + 0.0015 * expected,
                "\(grey) at +1 EV renders \(pixel)",
            )
        }
        var color = EditRecipe()
        color[.sharpenAmount] = 0
        var none = Self.reproduction(amount: 0)
        none[.sharpenAmount] = 0
        #expect(
            try render(none, session: session) == render(color, session: session),
            "Amount 0 renders as Redlamp Color",
        )
    }

    // MARK: - Helpers (as ToneRenderTests' and NeutralRenderTests')

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

    /// A linear raw whose camera RGB is linear sRGB, balanced as shot.
    private func makeRaw(
        width: Int, height: Int, baselineExposure: Double = 0, color: (Int, Int) -> SIMD3<Float>,
    ) throws -> ImageSession {
        let black: Float = 512
        let white: Float = 16383
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = color(x, y)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16((black + value[channel] * (white - black))
                        .rounded())
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples,
            blackLevels: [black, black, black], whiteLevel: white,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: baselineExposure,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic-reproduction.dng"),
                pixelSize: PixelSize(width: width, height: height), isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
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
                url: URL(fileURLWithPath: "/synthetic-reproduction.png"),
                pixelSize: PixelSize(width: width, height: height), isRaw: false, sensorDescription: "PNG",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}
