import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Lens profiles in the develop kernel (LNS-01): distortion, colour fringes and vignetting as
/// `GeometryMap` and `LensCorrection` describe them.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LensProfileRenderTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    static let (width, height) = (384, 256)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    /// A barrel correction with red recorded a little wider and blue a little narrower than
    /// green, and corners a stop dark.
    static let lens = LensCorrection(
        source: .sony, center: SIMD2(0.52, 0.48), radii: [0, 0.4, 0.8, 1.2],
        distortion: [
            SIMD3(repeating: 1), SIMD3(1.003, 0.99, 0.997), SIMD3(1.004, 0.97, 0.995), SIMD3(1.006, 0.94, 0.99),
        ],
        vignetting: [1, 1.15, 1.6, 2.2],
    )

    /// Smooth enough that bilinear sampling and the analytic value agree.
    static func pattern(_ point: SIMD2<Double>) -> SIMD3<Double> {
        let wave = sin(2 * .pi * 2.5 * point.x) * cos(2 * .pi * 1.5 * point.y)
        return SIMD3(0.25 + 0.1 * wave, 0.22 - 0.08 * wave, 0.2 + 0.06 * sin(2 * .pi * 3 * point.y))
    }

    func session(lens: LensCorrection?, color: (Int, Int) -> SIMD3<Double>) throws -> ImageSession {
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
                url: URL(fileURLWithPath: "/lens.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.lensCorrection = lens
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    func render(_ session: ImageSession, _ recipe: EditRecipe) throws -> [SIMD3<Float>] {
        let size = session.orientedSize
        let frame = try RedlampEngine().renderFrame(
            RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        return (0 ..< size.height).flatMap { y in
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            return (0 ..< size.width)
                .map { x in SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2])) }
        }
    }

    @Test func `the kernel corrects distortion, fringes and vignetting as the geometry says`() throws {
        let profiled = try session(lens: Self.lens) { x, y in
            Self.pattern(SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height)))
        }
        let size = PixelSize(width: Self.width, height: Self.height)
        let map = GeometryMap(recipe: EditRecipe(), imageSize: size, lens: Self.lens)
        let profile = try #require(map.lensProfile)
        let scale = profile.offsetScale(imageSize: size)
        // The corrected photo, resampled on the CPU: each channel from where the lens put it, lit
        // by the gain at the radius green was recorded at.
        let expected = try session(lens: nil) { x, y in
            let output = SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height))
            let offset = output - profile.center
            let scales = profile.interpolate(profile.distortion, at: simd_length(offset * scale))
            let green = profile.center + offset * scales.y
            let gain = profile.interpolate(profile.vignetting, at: simd_length((green - profile.center) * scale))
            return gain * SIMD3(
                Self.pattern(profile.center + offset * scales.x).x, Self.pattern(green).y,
                Self.pattern(profile.center + offset * scales.z).z,
            )
        }
        let rendered = try render(profiled, EditRecipe())
        let reference = try render(expected, EditRecipe())
        var off = EditRecipe()
        off[.lensProfile] = 0
        let plain = try render(profiled, off)
        // Away from the border, where clamping at the photo's edge differs. The corners' gain of
        // 2.2 magnifies sampling differences most there.
        var (worst, error, correction): (Float, Float, Float) = (0, 0, 0)
        for y in 8 ..< Self.height - 8 {
            for x in 8 ..< Self.width - 8 {
                let index = y * Self.width + x
                let difference = simd_abs(rendered[index] - reference[index]).max()
                worst = max(worst, difference)
                error += difference
                correction += simd_abs(rendered[index] - plain[index]).max()
            }
        }
        let count = Float((Self.width - 16) * (Self.height - 16))
        #expect(worst < 8e-3 && error / count < 1.5e-3, "largest difference \(worst), mean \(error / count)")
        #expect(correction / count > 0.05, "the correction shows: \(correction / count)")

        let unprofiled = try render(session(lens: nil) { x, y in
            Self.pattern(SIMD2((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height)))
        }, off)
        #expect(zip(plain, unprofiled).allSatisfy { simd_abs($0 - $1).max() == 0 }, "turned off, nothing changes")
    }

    /// A barrel correction that pushes the corners out by about 10%, with no vignetting.
    static let barrel = LensCorrection(
        source: .fujifilm, center: SIMD2(0.5, 0.5), radii: [0, 0.5, 1, 1.2],
        distortion: [SIMD3(repeating: 1), SIMD3(repeating: 0.97), SIMD3(repeating: 0.91), SIMD3(repeating: 0.88)],
        vignetting: [],
    )

    /// AI masks are read at the photo point behind each pixel, so the renders their models see show
    /// each subject there, whatever the photo's lens correction (#516). Corrected, they put a Subject
    /// mask off its person, with a halo on one side.
    @Test func `the renders AI masks are made from show each subject where masks are read`() async throws {
        let spot = SIMD2(0.85, 0.8)
        let scale = SIMD2(Double(Self.width), Double(Self.height))
        let centre = spot * scale
        let photo = try session(lens: Self.barrel) { x, y in
            let offset = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
            return SIMD3(repeating: 0.03 + 0.5 * exp(-simd_length_squared(offset) / 72))
        }
        let corrected = try #require(
            GeometryMap(recipe: EditRecipe(), imageSize: photo.orientedSize, lens: Self.barrel).outputPoint(spot),
        )
        #expect(simd_distance(corrected * scale, centre) > 5, "the edit's correction moves the spot")
        let engine = try RedlampEngine()
        let analysis = try await engine.analysisImage(for: photo).image
        let matte = try await engine.matteImage(for: photo)
        for (name, image) in [("analysis", analysis), ("matte", matte)] {
            #expect(image.width == Self.width && image.height == Self.height, "\(name)")
            let found = Self.brightCentre(image)
            #expect(simd_distance(found, centre) < 0.75, "\(name): the spot at \(found), not \(centre)")
        }
    }

    /// The centre of what stands above an image's ground, weighted by how far it stands, in pixels.
    static func brightCentre(_ image: CGImage) -> SIMD2<Double> {
        let bytes = BaseLookTests.pixels(image)
        let green = stride(from: 1, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        let ground = green.sorted()[green.count / 2] + 8
        var (sum, total) = (SIMD2<Double>.zero, 0.0)
        for (index, value) in green.enumerated() where value > ground {
            sum += (value - ground) * SIMD2(Double(index % image.width) + 0.5, Double(index / image.width) + 0.5)
            total += value - ground
        }
        return sum / max(total, 1)
    }

    /// A lens profile of an adapted lens made on the photo's own body, for its frame, as an LCP file.
    static let adaptedProfile = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
     xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile"><photoshop:CameraProfiles><rdf:Seq><rdf:li>
    <rdf:Description stCamera:Make="SONY" stCamera:Model="ILCE-7M3" stCamera:Lens="Helios 44-2 58mm f/2"
     stCamera:ProfileName="Mine (Helios 44-2)" stCamera:CameraRawProfile="True" stCamera:ImageWidth="384"
     stCamera:ImageLength="256" stCamera:FocalLength="58" stCamera:ApertureValue="2">
    <stCamera:PerspectiveModel><rdf:Description stCamera:FocalLengthX="1.4" stCamera:FocalLengthY="1.4"
     stCamera:RadialDistortParam1="-0.1"><stCamera:VignetteModel><rdf:Description stCamera:FocalLengthX="1.4"
     stCamera:FocalLengthY="1.4" stCamera:VignetteModelParam1="-0.5"/></stCamera:VignetteModel></rdf:Description>
    </stCamera:PerspectiveModel></rdf:Description></rdf:li></rdf:Seq></photoshop:CameraProfiles></rdf:Description>
    </rdf:RDF></x:xmpmeta>
    """

    @Test func `a profile an edit names replaces the photo's own correction under Custom, and renders`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lens-choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.adaptedProfile.utf8).write(to: folder.appending(path: "Helios.lcp"))
        let (width, height) = (Self.width, Self.height)
        var info = ImageInfo(
            url: URL(fileURLWithPath: "/adapted.arw"), pixelSize: PixelSize(width: width, height: height),
            isRaw: true, sensorDescription: "synthetic", make: "Sony", model: "ILCE-7M3", lens: "Lens 0",
        )
        info.focalLength = 58
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB,
            samples: (0 ..< width * height * 3).map { UInt16(truncatingIfNeeded: ($0 * 7919) % 65535) },
            blackLevels: [0, 0, 0], whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: info,
        )
        decoded.lensCorrection = Self.lens
        let session = try SessionBuilder(
            device: device, queue: queue, kernels: kernels, lensProfiles: LCPProfileLibrary(directory: folder),
        ).build(decoded)
        var recipe = EditRecipe()
        #expect(session.lensCorrection(for: recipe) == Self.lens)
        recipe.lensProfileChoice = LensProfileChoice(setup: .auto, name: "Mine (Helios 44-2)", fileName: "Helios.lcp")
        #expect(session.lensCorrection(for: recipe) == Self.lens, "under Auto the file's own correction comes first")
        recipe.lensProfileChoice?.setup = .custom
        let named = try #require(session.lensCorrection(for: recipe))
        #expect(named.source == .profile && named.profileFileName == "Helios.lcp")
        #expect(try render(session, recipe) != render(session, EditRecipe()))
        recipe.lensProfileChoice?.fileName = "Gone.lcp"
        #expect(session.lensCorrection(for: recipe) == Self.lens, "a profile not on this Mac leaves the photo's own")
    }

    /// The camera samples whose corrections process 16 reads (LNS-02).
    static let process16Samples = CameraGoldenTests.cameras.filter {
        ["Panasonic_DC-S5M2.RW2", "OM-System_OM-1-Mark-II.orf"].contains($0.lastPathComponent)
    }

    @Test(
        .enabled(if: EngineSmokeTests.canRender && !process16Samples.isEmpty),
        .serialized,
        arguments: process16Samples,
    )
    func `a process 15 edit of a Panasonic or OM System raw renders without its correction`(sample: URL) async throws {
        let engine = try RedlampEngine()
        let info = try await engine.open(sample)
        #expect(info.lensCorrection?.source.process == 16)
        func render(process: Int, profile: Bool) async throws -> Data {
            var recipe = EditRecipe()
            recipe.processVersion = process
            recipe[.lensProfile] = profile ? 1 : 0
            let image = try await engine.renderStill(StillRequest(
                recipe: recipe, maxLongEdge: 384, colorSpace: .sRGB, bitsPerComponent: 16, purpose: .export,
            ))
            return try #require(image.dataProvider?.data) as Data
        }
        #expect(try await render(process: 15, profile: true) == render(process: 15, profile: false))
        #expect(try await render(process: 16, profile: true) != render(process: 16, profile: false))
    }
}
