import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// What the sandboxed decode service relies on: decoding from a file's bytes gives what decoding
/// the file gives, and a decoded image survives the trip across the process boundary.
struct DecodeServiceTests {
    private func expectSame(_ a: DecodedImage, _ b: DecodedImage, _ name: String) {
        #expect(a.width == b.width && a.height == b.height, "\(name) size")
        #expect(a.samples == b.samples, "\(name) samples")
        #expect(a.info == b.info, "\(name) info")
        #expect(a.blackLevels == b.blackLevels && a.whiteLevel == b.whiteLevel, "\(name) levels")
        #expect(a.asShotMultipliers == b.asShotMultipliers && a.cameraToSRGB == b.cameraToSRGB, "\(name) colour")
        #expect(a.xyzToCamera == b.xyzToCamera && a.orientation == b.orientation, "\(name) matrix, orientation")
        #expect(a.baselineExposure == b.baselineExposure, "\(name) baseline exposure")
        #expect(a.noiseProfile == b.noiseProfile && a.gainMaps == b.gainMaps, "\(name) DNG tags")
        #expect(a.dngColor == b.dngColor && a.banding == b.banding, "\(name) calibration, banding")
        #expect(a.dngProfile == b.dngProfile, "\(name) camera profile")
        #expect(a.lensCorrection == b.lensCorrection, "\(name) lens correction")
        #expect(String(describing: a.layout) == String(describing: b.layout), "\(name) layout")
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty), arguments: DecodeRegressionTests.fixtures)
    func `decoding the bytes matches decoding the file`(url: URL) throws {
        let fromFile = try ImageDecoder.decode(url)
        let fromBytes = try ImageDecoder.decode(Data(contentsOf: url), url: url)
        expectSame(fromBytes, fromFile, url.lastPathComponent)
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty), arguments: DecodeRegressionTests.fixtures)
    func `an archived image comes back whole`(url: URL) throws {
        let decoded = try ImageDecoder.decode(url)
        try expectSame(DecodedImage(archive: decoded.archived()), decoded, url.lastPathComponent)
    }

    @Test func `the service reports a file it can't read as the engine error`() throws {
        let junk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).CR3")
        let reply = ReplyBox()
        DecodeService().decode(Data(repeating: 7, count: 4096), path: junk.path) { archive, failure in
            reply.archive = archive
            reply.failure = failure
        }
        #expect(reply.archive == nil)
        let error = try JSONDecoder().decode(EngineError.self, from: #require(reply.failure))
        #expect(!error.localizedDescription.isEmpty)
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty))
    func `a decoder whose service can't start fails the photo instead of decoding in the app`() throws {
        let url = try #require(DecodeRegressionTests.fixtures.first)
        // A test bundles no decode service, like an app that lost its own.
        for client in [DecodeServiceClient(), DecodeServiceClient(serviceName: "app.redlamp.mac.no-such-decoder")] {
            #expect(throws: EngineError.decoderUnavailable, "\(client.serviceName)") { _ = try client.decode(url) }
        }
    }

    @Test func `a damaged archive is an error, not a crash`() {
        #expect(throws: EngineError.self) { _ = try DecodedImage(archive: Data([1, 2, 3])) }
        #expect(throws: (any Error).self) { _ = try DecodedImage(archive: Data(repeating: 0xFF, count: 64)) }
    }

    @Test func `a reply whose levels, matrices or orientation the app couldn't use is an error`() throws {
        #expect(try DecodedImage(archive: image(orientation: 6, pixelSize: PixelSize(width: 2, height: 4)).archived())
            .orientation == 6)
        let identity = Self.identity
        let cases: [(String, DecodedImage)] = [
            ("a colour matrix of eight values", image(cameraToSRGB: Array(identity.dropLast()))),
            ("a camera matrix of six values", image(xyzToCamera: Array(identity.prefix(6)))),
            ("a black level short of the pattern", image(blackLevels: [0, 0, 0])),
            ("an orientation the app doesn't know", image(orientation: 7)),
            ("a pixel size that isn't the oriented image's", image(orientation: 6)),
            ("an unusable lens correction in the photo's info", image(infoLens: LensCorrection(
                source: .dng, center: SIMD2(0.5, 0.5), radii: [], distortion: [], vignetting: [1],
            ))),
        ]
        for (name, image) in cases {
            #expect(throws: EngineError.self, "\(name)") { try DecodedImage(archive: image.archived()) }
        }
        let notNumbers: [(String, DecodedImage)] = [
            ("a colour matrix with a NaN", image(cameraToSRGB: [.nan] + identity.dropFirst())),
            ("a camera matrix with an infinity", image(xyzToCamera: [.infinity] + identity.dropFirst())),
            ("a black level that isn't a number", image(blackLevels: [0, .nan, 0, 0])),
            ("a white level that isn't a number", image(whiteLevel: .nan)),
            ("a white balance multiplier that isn't a number", image(multipliers: SIMD3(1, .nan, 1))),
            ("an infinite baseline exposure", image(baselineExposure: .infinity)),
        ]
        for (name, image) in notNumbers {
            #expect(throws: (any Error).self, "\(name) never crosses") { try DecodedImage(archive: image.archived()) }
        }
    }

    @Test func `a reply whose lens, colour, profile, noise or banding tables the app couldn't use is an error`() throws {
        let whole = image(
            xyzToCamera: Self.identity, lens: Self.lens, color: DNGColorCalibration(
                calibrations: [Self.calibration], analogBalance: [1, 1, 1],
            ),
            profile: DNGProfile(
                name: nil, copyright: nil, embedPolicy: nil, cameraModel: nil, hueSatMaps: [Self.map],
                lookTable: Self.map, toneCurve: [SIMD2(0, 0), SIMD2(1, 1)], baselineExposureOffset: 0,
            ),
            noise: NoiseModel(a: SIMD3(1e-4, 1e-4, 1e-4), b: SIMD3(1e-6, 1e-6, 1e-6)),
            banding: BandingCorrection(rows: [0, 0], columns: [0, 0, 0, 0]),
        )
        #expect(try DecodedImage(archive: whole.archived()).lensCorrection == Self.lens)
        func damaged(_ change: (inout DecodedImage) -> Void) -> DecodedImage {
            var image = whole
            change(&image)
            return image
        }
        func withLens(_ change: (inout LensCorrection) -> Void) -> DecodedImage {
            damaged { image in change(&image.lensCorrection!) }
        }
        func withColor(_ change: (inout DNGColorCalibration) -> Void) -> DecodedImage {
            damaged { image in change(&image.dngColor!) }
        }
        func withProfile(_ change: (inout DNGProfile) -> Void) -> DecodedImage {
            damaged { image in change(&image.dngProfile!) }
        }
        let (calibration, map) = (Self.calibration, Self.map)
        let cases: [(String, DecodedImage)] = [
            ("a lens table without radii", withLens { $0.radii = [] }),
            ("lens radii that go back", withLens { $0.radii = [0, 1, 0.5] }),
            ("a distortion table short of the radii", withLens { $0.distortion.removeLast() }),
            ("a vignetting table short of the radii", withLens { $0.vignetting.removeLast() }),
            ("no DNG calibration", withColor { $0.calibrations = [] }),
            ("three DNG calibrations", withColor { $0.calibrations = Array(repeating: calibration, count: 3) }),
            ("a DNG colour matrix of eight values", withColor { $0.calibrations[0].colorMatrix.removeLast() }),
            (
                "a DNG camera calibration of eight values",
                withColor { $0.calibrations[0].cameraCalibration.removeLast() },
            ),
            ("two analog balances", withColor { $0.analogBalance = [1, 1] }),
            ("a hue/sat map short of its size", withProfile { $0.hueSatMaps[0].entries.removeLast() }),
            ("three hue/sat maps", withProfile { $0.hueSatMaps = [map, map, map] }),
            ("a look table smaller than its size", withProfile { $0.lookTable?.hues = 360 }),
            ("a tone curve of one point", withProfile { $0.toneCurve = [SIMD2(0, 0)] }),
        ]
        for (name, image) in cases {
            #expect(throws: EngineError.self, "\(name)") { try DecodedImage(archive: image.archived()) }
        }
        let notNumbers: [(String, DecodedImage)] = [
            ("a vignetting gain that isn't a number", withLens { $0.vignetting[1] = .nan }),
            ("a lens centre that isn't a number", withLens { $0.center.x = .nan }),
            ("a DNG forward matrix with a NaN", withColor { $0.calibrations[0].forwardMatrix?[4] = .nan }),
            ("a DNG illuminant that isn't a temperature", withColor { $0.calibrations[0].temperature = .nan }),
            ("an infinite profile exposure offset", withProfile { $0.baselineExposureOffset = .infinity }),
            ("a noise profile that isn't a number", damaged { $0.noiseProfile?.b.y = .nan }),
            ("a banding offset that isn't a number", damaged { $0.banding?.columns[2] = .infinity }),
        ]
        for (name, image) in notNumbers {
            #expect(throws: (any Error).self, "\(name) never crosses") { try DecodedImage(archive: image.archived()) }
        }
    }

    private static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    private static let lens = LensCorrection(
        source: .dng, center: SIMD2(0.5, 0.5), radii: [0, 0.5, 1],
        distortion: [SIMD3<Double>](repeating: SIMD3(1, 1, 1), count: 3), vignetting: [1, 1.1, 1.3],
    )
    private static let calibration = DNGColorCalibration.Calibration(
        temperature: 6504, colorMatrix: identity, cameraCalibration: identity, forwardMatrix: identity,
    )
    private static let map = DNGProfile.HSVMap(
        hues: 1, saturations: 2, values: 1, entries: [0, 1, 1, 0, 1, 1], srgbValues: false,
    )!

    /// A 4 x 2 RGGB mosaic with one gain map, as the decode service would send it.
    private func image(
        layout: DecodedImage.Layout = .mosaic(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])),
        samples: Int = 8, gainMap: GainMap? = nil, blackLevels: [Float] = [0, 0, 0, 0], whiteLevel: Float = 1000,
        multipliers: SIMD3<Double> = SIMD3(1, 1, 1), cameraToSRGB: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1],
        xyzToCamera: [Double]? = nil, orientation: Int = 0, baselineExposure: Double = 0,
        pixelSize: PixelSize = PixelSize(width: 4, height: 2), lens: LensCorrection? = nil,
        color: DNGColorCalibration? = nil, profile: DNGProfile? = nil, noise: NoiseModel? = nil,
        banding: BandingCorrection? = nil, infoLens: LensCorrection? = nil,
    ) -> DecodedImage {
        var info = ImageInfo(
            url: URL(fileURLWithPath: "/map.dng"), pixelSize: pixelSize, isRaw: true, sensorDescription: "synthetic",
        )
        info.lensCorrection = infoLens
        var image = DecodedImage(
            width: 4, height: 2, layout: layout, samples: (0 ..< samples).map { UInt16($0) },
            blackLevels: blackLevels, whiteLevel: whiteLevel, asShotMultipliers: multipliers,
            cameraToSRGB: cameraToSRGB, xyzToCamera: xyzToCamera, orientation: orientation,
            baselineExposure: baselineExposure, info: info,
        )
        image.gainMaps = gainMap.map { [$0] } ?? []
        image.lensCorrection = lens
        image.dngColor = color
        image.dngProfile = profile
        image.noiseProfile = noise
        image.banding = banding
        return image
    }

    private static let gainMap = GainMap(
        top: 0, left: 0, bottom: 2, right: 4, plane: 0, planes: 1, rowPitch: 1, columnPitch: 1,
        pointsV: 1, pointsH: 2, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [1, 2],
    )

    @Test func `an archive is checked as the app receives it`() throws {
        let valid = try DecodedImage(archive: image(gainMap: Self.gainMap).archived())
        #expect(valid.gainMaps == [Self.gainMap])

        var invalid = Self.gainMap
        invalid.top = 3
        #expect(throws: EngineError.self, "a gain map the parser would refuse") {
            try DecodedImage(archive: image(gainMap: invalid).archived())
        }
        let many = image(gainMap: Self.gainMap)
        var tooMany = many
        tooMany.gainMaps = Array(repeating: Self.gainMap, count: 65)
        #expect(throws: EngineError.self, "more maps than a photo can have") {
            try DecodedImage(archive: tooMany.archived())
        }
        #expect(throws: EngineError.self, "a sample missing") {
            try DecodedImage(archive: image(samples: 7).archived())
        }
        #expect(throws: EngineError.self, "a pixel's channels short") {
            try DecodedImage(archive: image(layout: .linearRGB).archived())
        }
        let pattern = try JSONDecoder().decode(
            CFAPattern.self,
            from: Data(#"{"width":2,"height":2,"colors":[0]}"#.utf8),
        )
        #expect(throws: EngineError.self, "a colour filter pattern that doesn't cover itself") {
            try DecodedImage(archive: image(layout: .mosaic(pattern)).archived())
        }
    }

    /// A call that waits for the service on the main thread would hang the app on a file the
    /// service is stuck on.
    @Test(.enabled(if: !DecodeServiceTests.isSandboxed))
    func `a Debug build stops on a call to the service from the main thread`() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = DecodeServiceClient(serviceName: "app.redlamp.mac.missing")
                    .captures(of: [URL(fileURLWithPath: "/nowhere/IMG_0001.ARW")], concurrently: false)
            }
        }
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = try? DecodeServiceClient(serviceName: "app.redlamp.mac.missing")
                    .decode(URL(fileURLWithPath: "/dev/null"))
            }
        }
        await #expect(processExitsWith: .success) {
            _ = await Task.detached {
                DecodeServiceClient(serviceName: "app.redlamp.mac.missing")
                    .captures(of: [URL(fileURLWithPath: "/nowhere/IMG_0001.ARW")], concurrently: false)
            }.value
        }
    }

    /// Whether this process runs in a sandbox, where XCTest runs no exit tests (an agent's shell
    /// in Cursor is one).
    static let isSandboxed: Bool = {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let check = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(check, to: Check.self)(getpid(), nil, 0) != 0
    }()
}

extension DecodeServiceTests {
    @Test func `a camera preview the app can't use is refused`() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue,
        ))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let pixels = try #require(PreviewPixels(image))
        #expect(pixels.colorSpace == CGColorSpace.displayP3 as String && pixels.iccProfile == nil)
        #expect(pixels.image(maxLongEdge: 8)?.colorSpace?.name == CGColorSpace.displayP3)

        var short = pixels
        short.bytes.removeLast()
        var unknown = pixels
        unknown.colorSpace = "not a colour space"
        var grey = pixels
        grey.colorSpace = CGColorSpace.linearGray as String
        var empty = pixels
        empty.width = 0
        for damaged in [short, unknown, grey, empty] {
            #expect(damaged.image(maxLongEdge: 8) == nil)
        }
        #expect(pixels.image(maxLongEdge: 7) == nil)
    }
}

/// The service replies synchronously; this holds what it sent.
private final class ReplyBox: @unchecked Sendable {
    var archive: Data?
    var failure: Data?
}
