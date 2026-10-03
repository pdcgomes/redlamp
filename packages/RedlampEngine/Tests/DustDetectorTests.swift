import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Dust detection (RM-02).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DustDetectorTests {
    static let (width, height) = (1024, 768)
    /// Dust on the smooth sky, of several sizes and strengths: centre, Gaussian width (px), darkening.
    static let dust: [(SIMD2<Double>, Double, Double)] = [
        (SIMD2(150, 120), 3, 0.10), (SIMD2(420, 200), 6, 0.06), (SIMD2(700, 140), 10, 0.05),
        (SIMD2(880, 330), 4, 0.08), (SIMD2(260, 360), 8, 0.04),
    ]
    /// The same specks on texture, where they can't be told from it.
    static let hidden: [SIMD2<Double>] = [SIMD2(200, 640), SIMD2(600, 680)]
    static let colouredDot = SIMD2(560.0, 380.0)

    /// A blue sky brightening upwards, a textured band below it, an edge between them, noise.
    func scene() throws -> ImageSession {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        var samples = [UInt16](repeating: 0, count: Self.width * Self.height * 3)
        var state: UInt64 = 12345
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        for y in 0 ..< Self.height {
            for x in 0 ..< Self.width {
                let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                var colour = SIMD3(0.25, 0.35, 0.6) * (1 - 0.3 * Double(y) / Double(Self.height))
                if y >= 560 {
                    colour = SIMD3(0.2, 0.18, 0.1) * (0.6 + 0.8 * random())
                }
                var shade = 1.0
                for (centre, width, depth) in Self.dust {
                    shade *= 1 - depth * exp(-simd_distance_squared(point, centre) / (2 * width * width))
                }
                for centre in Self.hidden {
                    shade *= 1 - 0.08 * exp(-simd_distance_squared(point, centre) / (2 * 5 * 5))
                }
                colour *= shade
                // A red dot: it darkens green and blue only.
                let dot = exp(-simd_distance_squared(point, Self.colouredDot) / (2 * 4 * 4))
                colour.y *= 1 - 0.3 * dot
                colour.z *= 1 - 0.3 * dot
                for channel in 0 ..< 3 {
                    let noisy = colour[channel] + 0.004 * (random() + random() + random() - 1.5)
                    samples[(y * Self.width + x) * 3 + channel] = UInt16(min(max(noisy, 0), 1) * 65535)
                }
            }
        }
        let decoded = DecodedImage(
            width: Self.width, height: Self.height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/dust.dng"), pixelSize: PixelSize(width: Self.width, height: Self.height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    func pixel(_ spot: DetectedSpot) -> SIMD2<Double> {
        SIMD2(spot.center.x * Double(Self.width), spot.center.y * Double(Self.height))
    }

    @Test func `dust on a smooth sky is found, and specks in texture, colour and edges aren't`() throws {
        let engine = try RedlampEngine()
        let session = try scene()
        let found = try engine.findDust(recipe: EditRecipe(), sensitivity: 50, session: session)
        for (centre, width, _) in Self.dust {
            let match = found.first { simd_distance(pixel($0), centre) < max(width, 3) }
            #expect(match != nil, "missed the speck at \(centre)")
            if let match {
                let radius = match.radius * Double(Self.height)
                #expect(radius > width * 1.2 && radius < width * 6, "speck at \(centre): radius \(radius)")
            }
        }
        #expect(!found.contains { simd_distance(pixel($0), Self.colouredDot) < 10 }, "the red dot")
        #expect(!found.contains { pixel($0).y > 540 }, "in or at the edge of the texture: \(found.map(pixel))")
        #expect(found.count <= Self.dust.count + 1, "\(found.count) found: \(found.map(pixel))")
    }

    /// Dust shadows added to the sky of a real photo, as dust on the sensor casts them (each
    /// channel darkened alike), in the photo as shown: (x, y, Gaussian width in pixels, depth).
    static let realDust: [(Double, Double, Double, Double)] = [
        (0.62, 0.25, 8, 0.08), (0.80, 0.27, 12, 0.06), (0.92, 0.24, 16, 0.07), (0.96, 0.31, 10, 0.10),
    ]

    @Test(.enabled(if: EmbeddedLookTests.fixture("IMG_1361") != nil))
    func `dust added to a real sky is found, and nothing else is`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let original = try ImageDecoder.decode(#require(EmbeddedLookTests.fixture("IMG_1361")))
        let channels = original.samples.count / (original.width * original.height)
        let size = SIMD2(Double(original.width), Double(original.height))
        let shown = original.orientedSize
        let specks = Self.realDust.map { x, y, width, depth in
            (sourceCoordinate(SIMD2(x, y), orientation: original.orientation) * size, width, depth)
        }
        var samples = original.samples
        for (centre, width, depth) in specks {
            let reach = Int(width * 4)
            for y in max(Int(centre.y) - reach, 0) ..< min(Int(centre.y) + reach, original.height) {
                for x in max(Int(centre.x) - reach, 0) ..< min(Int(centre.x) + reach, original.width) {
                    let d2 = simd_distance_squared(SIMD2(Double(x) + 0.5, Double(y) + 0.5), centre)
                    let shade = 1 - depth * exp(-d2 / (2 * width * width))
                    for channel in 0 ..< channels {
                        let index = (y * original.width + x) * channels + channel
                        let black = Double(original.blackLevels.first ?? 0)
                        samples[index] = UInt16((black + (Double(samples[index]) - black) * shade).rounded())
                    }
                }
            }
        }
        var dusty = DecodedImage(
            width: original.width, height: original.height, layout: original.layout, samples: samples,
            blackLevels: original.blackLevels, whiteLevel: original.whiteLevel,
            asShotMultipliers: original.asShotMultipliers, cameraToSRGB: original.cameraToSRGB,
            xyzToCamera: original.xyzToCamera, orientation: original.orientation,
            baselineExposure: original.baselineExposure, info: original.info,
        )
        dusty.noiseProfile = original.noiseProfile
        dusty.gainMaps = original.gainMaps
        dusty.dngColor = original.dngColor
        dusty.dngProfile = original.dngProfile
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(dusty)
        let found = try RedlampEngine().findDust(recipe: EditRecipe(), sensitivity: 50, session: session)
        func pixels(_ point: ImagePoint) -> SIMD2<Double> {
            SIMD2(point.x * Double(shown.width), point.y * Double(shown.height))
        }
        for (x, y, width, _) in Self.realDust {
            let centre = pixels(ImagePoint(x: x, y: y))
            #expect(found.contains { simd_distance(pixels($0.center), centre) < max(width, 6) }, "missed \(x), \(y)")
        }
        #expect(found.count <= Self.realDust.count + 1, "\(found.map { (pixels($0.center), $0.strength) })")
    }

    @Test func `Visualize Spots shows the specks in white on black, and the histogram the photo`() throws {
        let engine = try RedlampEngine()
        let session = try scene()
        var request = RenderRequest(recipe: EditRecipe(), targetSize: session.orientedSize, generation: 0)
        let photo = try engine.renderFrame(request, session: session)
        request.visualizeSpots = 50
        let frame = try engine.renderFrame(request, session: session)
        IOSurfaceLock(frame.surface, .readOnly, nil)
        defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
        func value(_ x: Int, _ y: Int) -> Float {
            let row = (IOSurfaceGetBaseAddress(frame.surface) + y * IOSurfaceGetBytesPerRow(frame.surface))
                .assumingMemoryBound(to: Float16.self)
            return Float(row[x * 4 + 1])
        }
        #expect(value(150, 120) > 0.5, "the speck: \(value(150, 120))")
        #expect(value(330, 60) < 0.05, "plain sky: \(value(330, 60))")
        #expect(frame.histogram == photo.histogram)
    }

    @Test func `dust already covered by a spot isn't found again`() throws {
        let engine = try RedlampEngine()
        let session = try scene()
        var recipe = EditRecipe()
        let (centre, _, _) = Self.dust[1]
        recipe.spots = [RetouchSpot(
            center: ImagePoint(x: centre.x / Double(Self.width), y: centre.y / Double(Self.height)),
            source: ImagePoint(x: centre.x / Double(Self.width), y: (centre.y + 60) / Double(Self.height)),
            radius: 20 / Double(Self.height),
        )]
        let found = try engine.findDust(recipe: recipe, sensitivity: 50, session: session)
        #expect(!found.contains { simd_distance(pixel($0), centre) < 12 })
        #expect(found.count >= Self.dust.count - 1)
    }
}
