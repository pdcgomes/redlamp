import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
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
    func scene(blemished: Bool, darkened: (Double, Double) -> Bool = { _, _ in false }) throws -> ImageSession {
        let (width, height) = (Self.width, Self.height)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (fx, fy) = (Double(x) + 0.5, Double(y) + 0.5)
                var value = (0.2 + 0.4 * fx / Double(width)) * (1 + 0.15 * sin(fx / 3) * sin(fy / 3))
                if blemished && simd_distance(SIMD2(fx, fy), Self.blemish) < 8 || darkened(fx, fy) {
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

    @Test func `a brushed Heal removes a scratch, matching the light along it`() throws {
        // A dark scratch along the gradient: the light it should take changes along its length.
        let engine = try RedlampEngine()
        let clean = try render(scene(blemished: false), EditRecipe(), engine: engine)
        let (width, height) = (Double(Self.width), Double(Self.height))
        let scratched = try scene(blemished: false) { x, y in abs(y - 150) < 1.5 && x > 120 && x < 300 }
        var recipe = EditRecipe()
        recipe.spots = [RetouchSpot(
            center: ImagePoint(x: 115 / width, y: 150 / height),
            source: ImagePoint(x: 155 / width, y: 120 / height),
            stroke: [ImagePoint(x: 190 / width, y: 0)],
            radius: 6 / height,
        )]
        let healed = try render(scratched, recipe, engine: engine)
        // Over two periods of the texture along the scratch, which the source has at another phase.
        func mean(_ image: [Float], from x0: Int) -> Float {
            let values = (x0 ..< x0 + 38).flatMap { x in (149 ... 150).map { image[$0 * Self.width + x] } }
            return values.reduce(0, +) / Float(values.count)
        }
        for x in stride(from: 125, to: 260, by: 40) {
            let expected = mean(clean, from: x), result = mean(healed, from: x)
            #expect(abs(result - expected) < expected * 0.04, "from \(x): \(expected) → \(result)")
        }
        // The source is brighter, being further along the gradient: a clone shows it.
        recipe.spots[0].mode = .clone
        let cloned = try render(scratched, recipe, engine: engine)
        #expect(mean(cloned, from: 165) > mean(clean, from: 165) * 1.06)
    }

    @Test func `a stroke's outline runs a radius from it, all the way round`() {
        let placement = RetouchStage.Placement(
            points: [SIMD2(100, 100), SIMD2(200, 100), SIMD2(200, 160)], offset: SIMD2(0, 50), radius: 10,
            origin: .zero, size: SIMD2(400, 400),
        )
        let outline = RetouchStage.outline(placement)
        #expect(outline.points.count > 100 && outline.points.count <= RetouchStage.maximumOutline)
        func distance(_ point: SIMD2<Float>) -> Float {
            zip(placement.points, placement.points.dropFirst()).map { a, b in
                let t = min(max(simd_dot(point - a, b - a) / simd_length_squared(b - a), 0), 1)
                return simd_distance(point, a + (b - a) * t)
            }.min() ?? 0
        }
        for point in outline.points {
            #expect(abs(distance(point) - 10) < 0.2, "\(point) is \(distance(point)) from the stroke")
        }
        // Both sides of each segment, and both ends.
        #expect(outline.points.contains { $0.y < 95 } && outline.points.contains { $0.y > 105 && $0.x < 190 })
        #expect(outline.points.contains { $0.x < 92 } && outline.points.contains { $0.y > 168 })
    }

    @Test func `a stroke's source is clear of the stroke`() throws {
        let (width, height) = (240, 160)
        var values = [Float](repeating: 0, count: width * height)
        var state: UInt32 = 99
        for index in values.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            values[index] = Float(state >> 8) / Float(1 << 24) * 0.5 - 0.25
        }
        let image = RetouchSource.Image(width: width, height: height, values: values)
        let stroke = [SIMD2<Float>(40, 0), SIMD2(40, 20)]
        let found = try #require(RetouchSource.search(
            image, center: SIMD2(100.5, 70.5), radius: 8, stroke: stroke, matchBrightness: true,
        ))
        let offset = found - SIMD2(100.5, 70.5)
        let points = [SIMD2<Float>(0, 0)] + stroke
        // The moved stroke keeps more than two radii from the stroke, sampled along both.
        var dense: [SIMD2<Float>] = []
        for index in points.indices.dropFirst() {
            for step in 0 ... 20 {
                dense.append(points[index - 1] + (points[index] - points[index - 1]) * Float(step) / 20)
            }
        }
        let nearest = dense.flatMap { a in dense.map { b in simd_distance(a + offset, b) } }.min() ?? 0
        #expect(nearest >= 8 * 2, "the source comes within \(nearest) of the stroke")
    }

    @Test func `Remove fills a blemish from the texture around it`() throws {
        let engine = try RedlampEngine()
        let clean = try render(scene(blemished: false), EditRecipe(), engine: engine)
        var recipe = EditRecipe()
        var spot = spot(.remove)
        spot.source = spot.center
        recipe.spots = [spot]
        #expect(!spot.isEmpty)
        let removed = try render(scene(blemished: true), recipe, engine: engine)
        let expected = statistics(clean, around: Self.blemish, radius: 8)
        let result = statistics(removed, around: Self.blemish, radius: 8)
        #expect(abs(result.mean - expected.mean) < expected.mean * 0.06, "mean \(expected.mean) → \(result.mean)")
        let ratio = result.deviation / expected.deviation
        #expect(ratio > 0.5 && ratio < 1.6, "texture \(expected.deviation) → \(result.deviation)")
    }

    @Test func `Remove continues an edge running through the hole`() throws {
        // Bright above, dark below, with an object sitting on the line between them.
        let (width, height) = (Self.width, Self.height)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        var state: UInt64 = 7
        for y in 0 ..< height {
            for x in 0 ..< width {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = 0.03 * (Double(state >> 11) / Double(1 << 53) - 0.5)
                var value = (y < 96 ? 0.6 : 0.15) * (1 + noise)
                if simd_distance(SIMD2(Double(x) + 0.5, Double(y) + 0.5), SIMD2(192, 96)) < 10 {
                    value = 0.02
                }
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16(min(max(value, 0), 1) * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/edge.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
        let engine = try RedlampEngine()
        var recipe = EditRecipe()
        let centre = ImagePoint(x: 192 / Double(width), y: 96 / Double(height))
        recipe.spots = [RetouchSpot(mode: .remove, center: centre, source: centre, radius: 18 / Double(height))]
        let before = try render(session, EditRecipe(), engine: engine)
        let after = try render(session, recipe, engine: engine)
        let bright = before[80 * width + 150], dark = before[112 * width + 150]
        for x in [186, 192, 198] {
            #expect(
                abs(after[88 * width + x] - bright) < bright * 0.1,
                "above the line at \(x): \(after[88 * width + x])",
            )
            #expect(
                abs(after[104 * width + x] - dark) < dark * 0.25,
                "below the line at \(x): \(after[104 * width + x])",
            )
        }
    }

    /// A picked object's mask: a rectangle over the blemish, as a model would cut it out.
    static func region() throws -> AIMask {
        let (width, height) = (192, 96)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5) * 2
                if abs(point.x - blemish.x) < 9, abs(point.y - blemish.y) < 9 {
                    pixels[y * width + x] = 255
                }
            }
        }
        let png = try #require(GrayMask(width: width, height: height, pixels: pixels).pngData())
        return AIMask(
            kind: .objects, provider: "test", revision: 1, analysisHash: "",
            center: ImagePoint(x: blemish.x / Double(Self.width), y: blemish.y / Double(Self.height)),
            bitmap: MaskBitmap(png: png, width: width, height: height),
        )
    }

    @Test func `a picked object's shape is removed, grown by the spot's radius`() throws {
        let engine = try RedlampEngine()
        let clean = try render(scene(blemished: false), EditRecipe(), engine: engine)
        let region = try Self.region()
        var recipe = EditRecipe()
        recipe.spots = [RetouchSpot(
            mode: .remove, center: region.center, source: region.center, region: region,
            radius: 3 / Double(Self.height),
        )]
        let removed = try render(scene(blemished: true), recipe, engine: engine)
        let expected = statistics(clean, around: Self.blemish, radius: 8)
        let result = statistics(removed, around: Self.blemish, radius: 8)
        #expect(abs(result.mean - expected.mean) < expected.mean * 0.06, "mean \(expected.mean) → \(result.mean)")
        // Outside the grown shape nothing changes but what the coarse levels see.
        let untouched = try render(scene(blemished: true), EditRecipe(), engine: engine)
        for (x, y) in [(70, 96), (130, 96), (100, 60), (100, 130)] {
            let (after, before) = (removed[y * Self.width + x], untouched[y * Self.width + x])
            #expect(abs(after - before) < before * 0.003, "at \(x), \(y): \(before) → \(after)")
        }
        #expect(recipe.maskBitmaps.contains(region.bitmap), "its mask is saved with the edit")
    }

    @Test func `a Remove spot is filled once, however the spots after it change`() throws {
        let session = try scene(blemished: true)
        let stage = RetouchStage(device: device, kernels: kernels, queue: queue)
        var spot = spot(.remove)
        spot.source = spot.center
        var recipe = EditRecipe()
        recipe.spots = [spot]
        func build() throws {
            let commands = try #require(queue.makeCommandBuffer())
            _ = try stage.session(for: recipe, base: session, commands: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        try build()
        #expect(stage.fillsComputed == 1)
        recipe.spots.append(RetouchSpot(
            center: ImagePoint(x: 0.8, y: 0.5), source: ImagePoint(x: 0.9, y: 0.5), radius: 0.03,
        ))
        try build()
        #expect(stage.fillsComputed == 1, "the heal spot after it doesn't refill it")
        recipe.spots[0].center.x += 0.01
        try build()
        #expect(stage.fillsComputed == 2)
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
