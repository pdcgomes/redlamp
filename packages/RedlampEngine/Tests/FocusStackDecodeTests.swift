import Foundation
import RedlampEngineAPI
import RedlampServices
import Synchronization
import Testing
@testable import RedlampEngine

/// Decodes in-process, recording each file, and fails the ones it is told to.
private final class RecordingDecoder: ImageDecoding {
    let failing: Set<String>
    let decoded = Mutex<[String]>([])

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    func decode(_ url: URL) throws -> DecodedImage {
        decoded.withLock { $0.append(url.lastPathComponent) }
        guard !failing.contains(url.lastPathComponent) else {
            throw EngineError.decodeFailed("\(url.lastPathComponent) is damaged")
        }
        return try InProcessDecoder().decode(url)
    }
}

extension FocusStackTests {
    /// A stack document over `count` synthetic frames in a new folder.
    private func stackDocument(frames count: Int, in folder: URL) throws -> (URL, [URL]) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (width, height) = (240, 160)
        let frames = syntheticStack(frames: count, width: width, height: height) { x, _ in
            x < width / 2 ? 0 : Float(count - 1)
        }
        let urls = try frames.enumerated().map { index, frame in
            let url = folder.appendingPathComponent("frame\(index).png")
            try writePNG(frame, to: url)
            return url
        }
        let documentURL = folder.appendingPathComponent("stack.redlampstack")
        try FocusStackDocument(frames: urls, at: documentURL).write(to: documentURL)
        return (documentURL, urls)
    }

    @Test func `every frame of a stack decodes through the engine's decoder`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (documentURL, urls) = try stackDocument(frames: 3, in: folder)
        var document = try FocusStackDocument.read(documentURL)
        document.retouch = [
            FocusStackStroke(source: .frame("frame2.png"), radius: 0.1, hardness: 1, points: [SIMD2(0.25, 0.5)]),
        ]
        try document.write(to: documentURL)
        let decoder = RecordingDecoder()
        let engine = try RedlampEngine(
            stillTile: 2048,
            stackCache: folder.appendingPathComponent("cache"),
            decoder: decoder,
        )

        _ = try await engine.open(documentURL)
        let decoded = decoder.decoded.withLock { $0 }
        for url in urls {
            #expect(decoded.count { $0 == url.lastPathComponent } >= 2, "\(url.lastPathComponent), merged twice")
        }
        #expect(decoded.count { $0 == "frame2.png" } == 3, "and once more for its stroke")
    }

    @Test func `a frame that doesn't decode is left out of the stack and reported`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (documentURL, _) = try stackDocument(frames: 4, in: folder)
        let cache = folder.appendingPathComponent("cache")
        let engine = try RedlampEngine(
            stillTile: 2048, stackCache: cache, decoder: RecordingDecoder(failing: ["frame1.png"]),
        )

        let info = try await engine.open(documentURL)
        #expect(info.url == documentURL)
        let stack = try engine.stacks.stack(at: documentURL)
        let failed = try #require(stack.report.failedFrames)
        #expect(failed.map(\.index) == [1])
        #expect(failed[0].reason.contains("frame1.png is damaged"))
        #expect(stack.report.frames == 4 && stack.report.reference != 1)
        #expect(stack.alignment.reference == stack.report.reference)
        #expect(stack.alignment.transforms.count == 4 && stack.alignment.transforms[1] == .identity)
        #expect(stack.depth.allSatisfy { $0 >= 0 && $0 <= 3 })
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        #expect(cached.isEmpty, "a merge missing a frame is tried again next time")
    }

    @Test func `a stack with fewer than two frames that decode fails`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (documentURL, _) = try stackDocument(frames: 3, in: folder)
        let engine = try RedlampEngine(
            stillTile: 2048, stackCache: folder.appendingPathComponent("cache"),
            decoder: RecordingDecoder(failing: ["frame0.png", "frame2.png"]),
        )
        await #expect(throws: EngineError.self) { try await engine.open(documentURL) }
    }
}
