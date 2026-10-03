import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// DNG ProfileGainTableMap (process 5), Apple ProRAW's local tone mapping.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct GainTableMapTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    static let (width, height) = (256, 128)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// Two columns of tables a quarter and three quarters across: the left one doubles dark
    /// pixels and leaves bright ones, the right one halves everything.
    static let map = DNGProfile.GainTableMap(
        rows: 1, columns: 2, spacing: SIMD2(0.5, 1), origin: SIMD2(0.25, 0.5), points: 3,
        weights: [0.2, 0.4, 0.1, 0, 0.3], gamma: 1, gains: [2, 1.5, 1, 0.5, 0.5, 0.5],
    )!

    static func camera(_ x: Int, _ y: Int) -> SIMD3<Double> {
        SIMD3(0.1 + 0.6 * Double(y) / Double(height), 0.3, 0.05 + 0.4 * Double(x) / Double(width))
    }

    /// The specification's gain for a camera colour (the camera matrix is sRGB's) at a position.
    static func gain(_ camera: SIMD3<Double>, at u: Double) -> Double {
        let scene = ColorMatrices.sRGBToRec2020 * camera
        let toProPhoto = RGBPrimaries.proPhoto.fromXYZ * DNGColorCalibration.bradfordD50ToD65.inverse
            * ColorMatrices.rec2020ToXYZ
        let pro = toProPhoto * scene
        let w = map.weights.map(Double.init)
        let channels: Double = w[0] * pro.x + w[1] * pro.y + w[2] * pro.z
        let extremes: Double = w[3] * pro.min() + w[4] * pro.max()
        let input = min(max(channels + extremes, 0), 1)
        func table(_ column: Int) -> Double {
            let index = min(input * Double(map.points), Double(map.points - 1))
            let (i, f) = (min(Int(index), map.points - 2), index - Double(min(Int(index), map.points - 2)))
            let gains = map.gains[column * map.points ..< (column + 1) * map.points].map(Double.init)
            return gains[i] * (1 - f) + gains[i + 1] * f
        }
        let t = min(max((u - map.origin.x) / map.spacing.x, 0), 1)
        return table(0) * (1 - t) + table(1) * t
    }

    func session(map: DNGProfile.GainTableMap?, color: (Int, Int) -> SIMD3<Double>) throws -> ImageSession {
        let (width, height) = (Self.width, Self.height)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = color(x, y)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(value[channel], 0), 1) * 65535)
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/gain.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        // A straight tone curve, so the photo has an embedded look for the map to come with.
        decoded.dngProfile = DNGProfile(
            name: "Test", copyright: nil, embedPolicy: nil, cameraModel: nil, hueSatMaps: [], lookTable: nil,
            toneCurve: [SIMD2(0, 0), SIMD2(1, 1)], baselineExposureOffset: 0, gainTableMap: map,
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// A lens-shading gain map (DNG opcode GainMap) with a top below its bottom, as a decoded image
    /// built by hand could hold one the parser would refuse.
    static let invalidGainMap = GainMap(
        top: 200, left: 0, bottom: 100, right: 256, plane: 0, planes: 3, rowPitch: 1, columnPitch: 1,
        pointsV: 1, pointsH: 2, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [1, 2],
    )

    @Test func `an invalid lens-shading map fails the photo, and scales no noise`() throws {
        let field = NoiseGain.field([Self.invalidGainMap], width: 256, height: 128, pattern: nil)
        #expect(field.width == 1 && field.height == 1 && field.gains == [SIMD4(1, 1, 1, 1)])

        var decoded = DecodedImage(
            width: 4, height: 2, layout: .linearRGB, samples: [UInt16](repeating: 100, count: 24),
            blackLevels: [0, 0, 0], whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/map.dng"), pixelSize: PixelSize(width: 4, height: 2), isRaw: true,
                sensorDescription: "synthetic",
            ),
        )
        decoded.gainMaps = [Self.invalidGainMap]
        #expect(throws: EngineError.self) {
            try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
        }
    }

    func render(_ session: ImageSession, process: Int, embedded: Bool = true) throws -> [SIMD3<Float>] {
        var recipe = EditRecipe()
        recipe.processVersion = process
        if embedded, let look = session.embeddedLook {
            recipe.baseLook = look.reference
        }
        let engine = try RedlampEngine()
        session.embeddedLook.map(engine.registerBaseLook)
        let size = session.orientedSize
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        IOSurfaceLock(frame.surface, .readOnly, nil)
        defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(frame.surface)
        let base = IOSurfaceGetBaseAddress(frame.surface)
        return (0 ..< size.height).flatMap { y in
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            return (0 ..< size.width)
                .map { x in SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2])) }
        }
    }

    @Test func `the gain table map gains each pixel as the DNG specification says`() throws {
        let mapped = try session(map: Self.map, color: Self.camera)
        let expected = try session(map: nil) { x, y in
            let camera = Self.camera(x, y)
            return camera * Self.gain(camera, at: (Double(x) + 0.5) / Double(Self.width))
        }
        let rendered = try render(mapped, process: 5)
        let reference = try render(expected, process: 5)
        let worst = zip(rendered, reference).map { simd_abs($0 - $1).max() }.max() ?? 0
        #expect(worst < 4e-3, "largest difference \(worst)")
        let plain = try render(session(map: nil, color: Self.camera), process: 5)
        #expect(zip(rendered, plain).map { simd_abs($0 - $1).max() }.max() ?? 0 > 0.05, "the map should show")
    }

    @Test func `the map comes with the embedded look only, and not before process 5`() throws {
        let mapped = try session(map: Self.map, color: Self.camera)
        let plain = try session(map: nil, color: Self.camera)
        #expect(try zip(render(mapped, process: 4), render(plain, process: 4)).allSatisfy { $0 == $1 })
        let redlamp = try zip(render(mapped, process: 5, embedded: false), render(plain, process: 5, embedded: false))
        #expect(redlamp.allSatisfy { $0 == $1 }, "Redlamp's own looks render without it")
    }
}
