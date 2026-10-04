import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes
import Testing
@testable import RedlampUI

extension StubEngine: RawFileInspecting {
    /// Files whose names start with "z8" are a Nikon Z 8's; other raws an A7 III's.
    func identify(_ url: URL) -> RawFileIdentity? {
        guard SupportedFormats.isRaw(url) else { return nil }
        let nikon = url.lastPathComponent.hasPrefix("z8")
        return RawFileIdentity(
            make: nikon ? "Nikon" : "Sony", model: nikon ? "Z 8" : "ILCE-7M3", normalizedMake: nikon ? "Nikon" : "Sony",
            normalizedModel: nikon ? "Z 8" : "ILCE-7M3", format: url.pathExtension.uppercased(),
            decoder: nikon ? "nikon_load_raw" : "sony_arw2_load_raw", bitsPerSample: 14,
            imageSize: PixelSize(width: 600, height: 400), iso: 100, previews: [PixelSize(width: 600, height: 400)],
        )
    }

    func cameraPreview(of _: URL, maxLongEdge _: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )
        context?.setFillColor(gray: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        return context?.makeImage()
    }

    var rawDecoderVersion: String {
        "LibRaw test"
    }
}

/// A relay that keeps what it's sent.
final class RecordingRelay: CameraBenchSending, @unchecked Sendable {
    var sent: [Data] = []

    func send(_ report: Data) async throws -> CameraBenchReceipt {
        sent.append(report)
        return CameraBenchReceipt(id: "submission-1", dryRun: true)
    }

    func summary() async -> CameraBenchSummary? {
        nil
    }
}

/// The Camera Bench window's model (CAM-15): photos grouped by camera mode, tested, and turned into
/// the report it would send, measurements only.
@MainActor
struct CameraBenchModelTests {
    let folder: URL
    let relay = RecordingRelay()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW", "z8-0001.NEF", "z8-0002.NEF", "holiday.jpg"] {
            try Data([0]).write(to: folder.appending(path: name))
        }
    }

    func model() -> CameraBenchModel {
        CameraBenchModel(
            makeBench: { CameraBench(engine: StubEngine()) }, relay: relay, currentFolder: { nil },
            version: (redlamp: "0.0-test", commit: nil),
        )
    }

    func tested() async throws -> CameraBenchModel {
        let model = model()
        model.test([folder])
        let deadline = Date().addingTimeInterval(20)
        while model.phase != .results, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.phase == .results)
        return model
    }

    @Test func `raws in a folder are grouped by camera mode and tested`() async throws {
        let model = try await tested()
        #expect(model.modes.map(\.mode.camera).sorted() == ["Nikon Z 8", "Sony ILCE-7M3"])
        #expect(model.modes.map(\.photos.count).sorted() == [2, 3])
        #expect(model.modes.allSatisfy { !$0.checks.isEmpty })
    }

    @Test func `the report holds measurements and answers, never file names or paths`() async throws {
        let model = try await tested()
        let sony = try #require(model.modes.first { $0.mode.camera == "Sony ILCE-7M3" })
        model.answers[sony.id] = .same
        model.notes[sony.id] = "  Daylight.  "
        let json = model.reportJSON
        #expect(!json.contains("DSC00001") && !json.contains("z8-0001") && !json.contains(folder.path))
        let report = try JSONDecoder().decode(CameraBenchReport.self, from: Data(json.utf8))
        #expect(report.photos.count == 5)
        #expect(report.answers == [CameraBenchAnswer(mode: sony.id, choice: .same, note: "Daylight.")])
        #expect(report.contributor.flatMap(UUID.init(uuidString:)) != nil)
        #expect(report.environment.decoder == "LibRaw test")
    }

    @Test func `send goes to the relay, exactly as shown`() async throws {
        let model = try await tested()
        let shown = model.reportJSON
        model.send()
        let deadline = Date().addingTimeInterval(5)
        while model.sending == .sending, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sending == .sent(id: "submission-1", dryRun: true))
        #expect(relay.sent.map { String(decoding: $0, as: UTF8.self) } == [shown])
    }

    @Test func `a mode with problems can be reported, without file names`() async throws {
        let model = try await tested()
        let mode = try #require(model.modes.first { $0.verdict >= .warn })
        let url = try #require(model.problemURL(mode))
        #expect(url.absoluteString.contains("issues/new"))
        #expect(!url.absoluteString.contains("DSC0000"))
    }

    @Test func `what a mode still needs leaves out what its photos cover`() async throws {
        let model = try await tested()
        let mode = try #require(model.modes.first)
        #expect(!model.stillNeeded(mode).contains(.baseISO))
        #expect(model.stillNeeded(mode).contains(.highISO))
    }
}
