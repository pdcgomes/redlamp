import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Heal and Clone (RM-01).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct RetouchTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    static let width = 384
    static let height = 192
    static let blemish = SIMD2(100.0, 96.0)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// Fine texture over light that brightens to the right, with a dark blemish when asked.
    func scene(blemished: Bool) throws -> ImageSession {
        let (width, height) = (Self.width, Self.height)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (fx, fy) = (Double(x) + 0.5, Double(y) + 0.5)
                var value = (0.2 + 0.4 * fx / Double(width)) * (1 + 0.15 * sin(fx / 3) * sin(fy / 3))
                if blemished, simd_distance(SIMD2(fx, fy), Self.blemish) < 8 {
                    value = 0.02
                }
                let colour = SIMD3(value, value * 0.9, value * 0.8)
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(colour[channel], 0), 1) * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/retouch.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// The rendered frame's green channel.
    func render(_ session: ImageSession, _ recipe: EditRecipe, engine: RedlampEngine) throws -> [Float] {
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
        )
        IOSurfaceLock(frame.surface, .readOnly, nil)
        defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(frame.surface)
        var values = [Float](repeating: 0, count: Self.width * Self.height)
        for y in 0 ..< Self.height {
            let row = (IOSurfaceGetBaseAddress(frame.surface) + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< Self.width {
                values[y * Self.width + x] = Float(row[x * 4 + 1])
            }
        }
        return values
    }

    /// Mean and standard deviation within `radius` of `centre`.
    func statistics(_ image: [Float], around centre: SIMD2<Double>, radius: Double) -> (mean: Float, deviation: Float) {
        var values: [Float] = []
        for y in 0 ..< Self.height {
            for x in 0 ..< Self.width where simd_distance(SIMD2(Double(x) + 0.5, Double(y) + 0.5), centre) < radius {
                values.append(image[y * Self.width + x])
            }
        }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        return (mean, variance.squareRoot())
    }

    func spot(_ mode: RetouchSpot.Mode) -> RetouchSpot {
        let height = Double(Self.height), width = Double(Self.width)
        return RetouchSpot(
            mode: mode,
            center: ImagePoint(x: Self.blemish.x / width, y: Self.blemish.y / height),
            source: ImagePoint(x: 200 / width, y: Self.blemish.y / height),
            radius: 16 / height,
        )
    }

    @Test func `Heal replaces a blemish with texture matched to the light around it`() throws {
        let engine = try RedlampEngine()
        let clean = try render(scene(blemished: false), EditRecipe(), engine: engine)
        let blemished = try scene(blemished: true)
        var recipe = EditRecipe()
        recipe.spots = [spot(.heal)]
        let healed = try render(blemished, recipe, engine: engine)
        let expected = statistics(clean, around: Self.blemish, radius: 8)
        let result = statistics(healed, around: Self.blemish, radius: 8)
        #expect(abs(result.mean - expected.mean) < expected.mean * 0.04, "mean \(expected.mean) → \(result.mean)")
        let ratio = result.deviation / expected.deviation
        #expect(ratio > 0.6 && ratio < 1.5, "texture \(expected.deviation) → \(result.deviation)")
        // Outside the circle only the coarse levels local tone reads see the repair.
        let untouched = try render(blemished, EditRecipe(), engine: engine)
        for (x, y) in [(60, 96), (100, 60), (140, 140), (300, 20)] {
            let (after, before) = (healed[y * Self.width + x], untouched[y * Self.width + x])
            #expect(abs(after - before) < before * 0.003, "at \(x), \(y): \(before) → \(after)")
        }
    }

    @Test func `Clone copies the source as it is`() throws {
        let engine = try RedlampEngine()
        let clean = try render(scene(blemished: false), EditRecipe(), engine: engine)
        var recipe = EditRecipe()
        recipe.spots = [spot(.clone)]
        let cloned = try render(scene(blemished: true), recipe, engine: engine)
        let source = statistics(clean, around: SIMD2(200, Self.blemish.y), radius: 8)
        let result = statistics(cloned, around: Self.blemish, radius: 8)
        #expect(abs(result.mean - source.mean) < source.mean * 0.02, "source \(source.mean), clone \(result.mean)")
    }

    @Test func `spots apply in order, and Opacity mixes with the photo`() throws {
        let engine = try RedlampEngine()
        let blemished = try scene(blemished: true)
        let before = try statistics(render(blemished, EditRecipe(), engine: engine), around: Self.blemish, radius: 6)
        var half = EditRecipe()
        var spot = spot(.clone)
        spot.opacity = 50
        half.spots = [spot]
        spot.opacity = 100
        var full = EditRecipe()
        full.spots = [spot]
        let halfway = try statistics(render(blemished, half, engine: engine), around: Self.blemish, radius: 6)
        let replaced = try statistics(render(blemished, full, engine: engine), around: Self.blemish, radius: 6)
        #expect(halfway.mean > before.mean && halfway.mean < replaced.mean)
        // A second spot cloning the first one's circle elsewhere copies the repair, not the blemish.
        let elsewhere = SIMD2(300.0, Self.blemish.y)
        var chained = full
        chained.spots.append(RetouchSpot(
            mode: .clone,
            center: ImagePoint(x: elsewhere.x / Double(Self.width), y: elsewhere.y / Double(Self.height)),
            source: spot.center,
            radius: spot.radius,
        ))
        let copy = try statistics(render(blemished, chained, engine: engine), around: elsewhere, radius: 6)
        #expect(abs(copy.mean - replaced.mean) < replaced.mean * 0.01, "repair \(replaced.mean), copy \(copy.mean)")
    }

    @Test func `the source search keeps to the spot's texture and passes over other blemishes`() throws {
        // Random texture (grass) on the left, flat (water) on the right; a blemish in the spot and
        // another where the nearest good source would be. Unrelated textures differ more than
        // a texture and a flat area do, so a plain difference would pick the water.
        let (width, height) = (200, 120)
        var values = [Float](repeating: -1, count: width * height)
        var state: UInt32 = 12345
        for y in 0 ..< height {
            for x in 0 ..< 100 {
                state = state &* 1_664_525 &+ 1_013_904_223
                values[y * width + x] = Float(state >> 8) / Float(1 << 24) * 0.5 - 0.25
            }
        }
        let spot = SIMD2<Float>(80.5, 60.5), decoy = SIMD2<Float>(60.5, 60.5)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let at = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                if simd_distance(at, spot) < 5 || simd_distance(at, decoy) < 5 {
                    values[y * width + x] = -3
                }
            }
        }
        let image = RetouchSource.Image(width: width, height: height, values: values)
        for heal in [true, false] {
            let found = try #require(RetouchSource.search(image, center: spot, radius: 8, matchBrightness: heal))
            #expect(simd_distance(found, spot) >= 8 * RetouchSource.separation, "\(found) overlaps the spot")
            #expect(found.x + 8 * RetouchSource.rim < 100, "\(found) reaches the flat side")
            #expect(simd_distance(found, decoy) > 8 + 5, "\(found) takes the other blemish")
        }
        #expect(RetouchSource.search(image, center: SIMD2(-5, 60), radius: 8, matchBrightness: true) == nil)
    }

    @Test func `Clone's source keeps to the spot's brightness and Heal's clears the spot`() throws {
        let engine = try RedlampEngine()
        let session = try scene(blemished: true)
        for mode in RetouchSpot.Mode.allCases {
            var spot = spot(mode)
            spot.source = spot.center
            let result = try engine.findRetouchSource(for: spot, recipe: EditRecipe(), session: session)
            let found = try #require(result)
            let offset = SIMD2(
                (found.x - spot.center.x) * Double(Self.width), (found.y - spot.center.y) * Double(Self.height),
            )
            let radius = spot.radius * Double(Self.height)
            #expect(simd_length(offset) >= radius * 2, "\(mode): \(offset) from the spot")
            #expect(found.x > 0 && found.x < 1 && found.y > 0 && found.y < 1)
            if mode == .clone {
                // The light brightens to the right, so a clone keeps to the spot's column.
                #expect(abs(offset.x) < radius, "clone moved \(offset.x) across the gradient")
            }
        }
    }

    @Test func `spots land on the same content whatever the orientation`() throws {
        let spot = RetouchSpot(
            center: ImagePoint(x: 0.25, y: 0.75), source: ImagePoint(x: 0.5, y: 0.5), radius: 0.1,
        )
        // A portrait shown from a landscape sensor (EXIF 6): oriented (x, y) is sensor (y, 1 - x).
        let placement = try #require(RetouchStage.placement(spot, orientation: 6, width: 400, height: 300))
        #expect(placement.center == SIMD2(300, 225))
        #expect(placement.source == SIMD2(200, 150))
        #expect(placement.radius == 40, "a tenth of the portrait's height, the sensor's width")
        #expect(placement.origin == SIMD2(259, 184) && placement.size == SIMD2(41 + 41, 82))
        let outside = RetouchSpot(center: ImagePoint(x: 3, y: 3), source: ImagePoint(x: 0.5, y: 0.5), radius: 0.1)
        #expect(RetouchStage.placement(outside, orientation: 1, width: 400, height: 300) == nil)
    }
}
