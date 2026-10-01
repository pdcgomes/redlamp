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
}

/// The service replies synchronously; this holds what it sent.
private final class ReplyBox: @unchecked Sendable {
    var archive: Data?
    var failure: Data?
}
