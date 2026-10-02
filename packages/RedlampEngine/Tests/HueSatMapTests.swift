import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Camera profiles' HueSatMaps (TON-09, process 4), against a CPU port of the DNG SDK's
/// `RefBaselineHueSatMap`.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct HueSatMapTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// Saturated, pale and dark colours in camera RGB (the camera matrix is sRGB's).
    static let patches: [SIMD3<Float>] = [
        SIMD3(0.5, 0.1, 0.1), SIMD3(0.18, 0.45, 0.15), SIMD3(0.08, 0.1, 0.5), SIMD3(0.5, 0.45, 0.1),
        SIMD3(0.1, 0.4, 0.45), SIMD3(0.4, 0.1, 0.45), SIMD3(0.45, 0.3, 0.25), SIMD3(0.3, 0.32, 0.35),
        SIMD3(0.05, 0.03, 0.02), SIMD3(0.6, 0.55, 0.5), SIMD3(0.2, 0.25, 0.1), SIMD3(0.35, 0.2, 0.3),
    ]
    static let patchSize = 8

    /// Turns hue by up to 30° and scales saturation by 0.6...1.4 around the hue circle, more for
    /// saturated colours; value scales with saturation and, in 3D maps, with value.
    static func map(values: Int, srgb: Bool) throws -> DNGProfile.HSVMap {
        let (hues, saturations) = (12, 5)
        var entries: [Float] = []
        for v in 0 ..< values {
            for h in 0 ..< hues {
                for s in 0 ..< saturations {
                    let angle = 2 * Float.pi * Float(h) / Float(hues)
                    let saturation = Float(s) / Float(saturations - 1)
                    let value = values > 1 ? Float(v) / Float(values - 1) : 0
                    entries += [
                        30 * sin(angle) * saturation, 1 + 0.4 * cos(angle) * saturation,
                        1 - 0.15 * saturation + 0.1 * value,
                    ]
                }
            }
        }
        return try #require(DNGProfile.HSVMap(
            hues: hues, saturations: saturations, values: values, entries: entries, srgbValues: srgb,
        ))
    }

    static func profile(_ map: DNGProfile.HSVMap) -> DNGProfile {
        DNGProfile(
            name: "Test", copyright: nil, embedPolicy: 0, cameraModel: nil, hueSatMaps: [map], lookTable: nil,
            toneCurve: nil, baselineExposureOffset: 0,
        )
    }

    // MARK: - The DNG SDK's math

    static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let v = c.max(), gap = v - c.min()
        guard gap > 0 else { return SIMD3(0, 0, v) }
        var h: Float
        if c.x == v {
            h = (c.y - c.z) / gap
            if h < 0 {
                h += 6
            }
        } else if c.y == v {
            h = 2 + (c.z - c.x) / gap
        } else {
            h = 4 + (c.x - c.y) / gap
        }
        return SIMD3(h, gap / v, v)
    }

    static func rgb(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        var h = hsv.x
        let (s, v) = (hsv.y, hsv.z)
        guard s > 0 else { return SIMD3(repeating: v) }
        if h < 0 {
            h += 6
        }
        if h >= 6 {
            h -= 6
        }
        let i = Int(h), f = h - Float(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    static func srgbEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func srgbDecode(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// `RefBaselineHueSatMap` for one linear ProPhoto colour.
    static func reference(_ color: SIMD3<Float>, _ map: DNGProfile.HSVMap) -> SIMD3<Float> {
        var hsv = Self.hsv(color)
        let encoded = map.srgbValues ? srgbEncode(hsv.z) : hsv.z
        func entry(_ v: Int, _ h: Int, _ s: Int) -> SIMD3<Float> {
            let index = ((v * map.hues + h) * map.saturations + s) * 3
            return SIMD3(map.entries[index], map.entries[index + 1], map.entries[index + 2])
        }
        let hScaled = map.hues < 2 ? 0 : hsv.x * Float(map.hues) / 6
        let sScaled = hsv.y * Float(map.saturations - 1)
        var h0 = Int(hScaled)
        let s0 = min(Int(sScaled), map.saturations - 2)
        var h1 = h0 + 1
        if h0 >= map.hues - 1 {
            h0 = map.hues - 1
            h1 = 0
        }
        let hf = hScaled - Float(h0), sf = sScaled - Float(s0)
        func bilinear(_ v: Int) -> SIMD3<Float> {
            let low = entry(v, h0, s0) * (1 - hf) + entry(v, h1, s0) * hf
            let high = entry(v, h0, s0 + 1) * (1 - hf) + entry(v, h1, s0 + 1) * hf
            return low * (1 - sf) + high * sf
        }
        var shift = bilinear(0)
        if map.values > 1 {
            let vScaled = min(max(encoded, 0), 1) * Float(map.values - 1)
            let v0 = min(Int(vScaled), map.values - 2)
            let vf = vScaled - Float(v0)
            shift = bilinear(v0) * (1 - vf) + bilinear(v0 + 1) * vf
        }
        hsv.x += shift.x * 6 / 360
        hsv.y = min(hsv.y * shift.y, 1)
        hsv.z = map.srgbValues ? srgbDecode(encoded * shift.z) : hsv.z * shift.z
        return Self.rgb(hsv)
    }

    // MARK: - Rendering

    func session(_ colors: [SIMD3<Float>], profile: DNGProfile?) throws -> ImageSession {
        let size = Self.patchSize
        let (width, height) = (size * colors.count, size)
        let white: Float = 65535
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    let value = min(max(colors[x / size][channel], 0), 1)
                    samples[(y * width + x) * 3 + channel] = UInt16((value * white).rounded())
                }
            }
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/patches.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.dngProfile = profile
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// Each patch's centre, as linear output.
    func render(_ session: ImageSession, process: Int) throws -> [SIMD3<Float>] {
        var recipe = EditRecipe()
        recipe.processVersion = process
        let size = session.orientedSize
        let frame = try RedlampEngine().renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let row = (IOSurfaceGetBaseAddress(surface) + Self.patchSize / 2 * IOSurfaceGetBytesPerRow(surface))
            .assumingMemoryBound(to: Float16.self)
        return (0 ..< size.width / Self.patchSize).map { patch in
            let x = patch * Self.patchSize + Self.patchSize / 2
            return SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
        }
    }

    static func worst(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        zip(a, b).map { simd_abs($0 - $1).max() }.max() ?? 0
    }

    // MARK: - Tests

    @Test(arguments: [(1, false), (4, true)])
    func `process 4 corrects colour as the DNG SDK does`(values: Int, srgb: Bool) throws {
        let map = try Self.map(values: values, srgb: srgb)
        let profiled = try session(Self.patches, profile: Self.profile(map))
        let toWorking = profiled.cameraToWorking
        let toProPhoto = HueSatMaps.workingToProPhoto
        let expected = Self.patches.map { camera in
            let pro = toProPhoto * (toWorking * camera)
            return toWorking.inverse * (toProPhoto.inverse * Self.reference(pro, map))
        }
        // The corrected colours must fit in a raw file to be the reference.
        #expect(expected.allSatisfy { $0.min() >= 0 && $0.max() <= 1 }, "\(expected)")
        let rendered = try render(profiled, process: 4)
        let reference = try render(session(expected, profile: nil), process: 3)
        #expect(Self.worst(rendered, reference) < 2e-3, "\(rendered) vs \(reference)")
        let plain = try render(session(Self.patches, profile: nil), process: 4)
        #expect(Self.worst(rendered, plain) > 0.02, "the map should change the colours")
    }

    @Test func `an identity map changes nothing`() throws {
        let entries = [Float]((0 ..< 12 * 5).map { _ in [Float(0), 1, 1] }.joined())
        let map = try #require(DNGProfile.HSVMap(
            hues: 12,
            saturations: 5,
            values: 1,
            entries: entries,
            srgbValues: false,
        ))
        let profiled = try render(session(Self.patches, profile: Self.profile(map)), process: 4)
        let plain = try render(session(Self.patches, profile: nil), process: 4)
        #expect(Self.worst(profiled, plain) < 1e-3)
    }

    @Test func `edits from before process 4 ignore the map`() throws {
        let map = try Self.map(values: 1, srgb: false)
        let profiled = try render(session(Self.patches, profile: Self.profile(map)), process: 3)
        let plain = try render(session(Self.patches, profile: nil), process: 3)
        #expect(Self.worst(profiled, plain) == 0)
    }

    @Test(.enabled(if: EngineSmokeTests.fixtures.contains { $0.lastPathComponent.hasPrefix("PXL_") }))
    func `the Pixel's Adobe Standard map turns hues a little and keeps greys`() throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent.hasPrefix("PXL_") })
        let decoded = try ImageDecoder.decode(url)
        let profile = try #require(decoded.dngProfile)
        let maps = try #require(HueSatMaps(profile: profile, device: device))
        #expect(maps.cool !== maps.warm)
        for map in profile.hueSatMaps {
            // The first saturation column is grey, which stays as it is.
            for hue in 0 ..< map.hues {
                let index = hue * map.saturations * 3
                #expect(abs(map.entries[index + 1] - 1) < 0.02 && abs(map.entries[index + 2] - 1) < 0.02, "hue \(hue)")
            }
            let shifts = stride(from: 0, to: map.entries.count, by: 3).map { map.entries[$0] }
            #expect(shifts.allSatisfy { abs($0) <= 10 }, "hue shifts up to \(shifts.map(abs).max() ?? 0)°")
        }
    }
}
