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

    @Test func `a damaged archive is an error, not a crash`() {
        #expect(throws: EngineError.self) { _ = try DecodedImage(archive: Data([1, 2, 3])) }
        #expect(throws: (any Error).self) { _ = try DecodedImage(archive: Data(repeating: 0xFF, count: 64)) }
    }

    /// A 4 x 2 RGGB mosaic with one gain map, as the decode service would send it.
    private func image(
        layout: DecodedImage.Layout = .mosaic(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])),
        samples: Int = 8, gainMap: GainMap? = nil,
    ) -> DecodedImage {
        var image = DecodedImage(
            width: 4, height: 2, layout: layout, samples: (0 ..< samples).map { UInt16($0) },
            blackLevels: [0, 0, 0, 0], whiteLevel: 1000, asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/map.dng"), pixelSize: PixelSize(width: 4, height: 2), isRaw: true,
                sensorDescription: "synthetic",
            ),
        )
        image.gainMaps = gainMap.map { [$0] } ?? []
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
}

/// The service replies synchronously; this holds what it sent.
private final class ReplyBox: @unchecked Sendable {
    var archive: Data?
    var failure: Data?
}
