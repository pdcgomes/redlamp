import Foundation
import RedlampEngineAPI
import RedlampServices
import Synchronization
import Testing
@testable import RedlampEngine

/// Decodes in-process, recording each file, and fails the ones it is told to.
private final class RecordingDecoder: ImageDecoding {
    let failing: Set<String>
    let isAvailable: Bool
    let decoded = Mutex<[String]>([])

    init(failing: Set<String> = [], isAvailable: Bool = true) {
        self.failing = failing
        self.isAvailable = isAvailable
    }

    func decode(_ url: URL) throws -> DecodedImage {
        decoded.withLock { $0.append(url.lastPathComponent) }
        guard isAvailable else { throw EngineError.decoderUnavailable }
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

    @Test func `a merge missing frames is indexed by the stack's frames`() {
        let decoded = DecodedImage(
            width: 1, height: 1, layout: .linearRGB, samples: [0, 0, 0], blackLevels: [0, 0, 0],
            whiteLevel: 65535, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/stack.redlampstack"), pixelSize: PixelSize(width: 1, height: 1),
                isRaw: false, sensorDescription: "synthetic",
            ),
        )
        let transforms = [Similarity(tx: 1), Similarity(tx: 2), Similarity(tx: 3)]
        let one = SIMD3<Float>(repeating: 1)
        let gains = [0.9 * one, one, 1.1 * one]
        let merged = MergedStack(
            decoded: decoded,
            report: FocusStackReport(
                frames: 3, reference: 1, width: 1, height: 1, maximumScaleChange: 0, minimumCorrelation: 0.8,
                confidentDepthFraction: 1, timings: [:],
            ),
            depth: [0, 0.5, 1, 1.5, 2], depthWidth: 5, depthHeight: 1, crop: PixelRect(x: 0, y: 0, width: 1, height: 1),
            frameWidth: 1, frameHeight: 1, referenceURL: URL(fileURLWithPath: "/frame2.png"),
            alignment: StackAlignment(reference: 1, transforms: transforms, gains: gains, correlations: [0.9, 1, 0.8]),
        )

        let stack = merged.spread(over: [0, 2, 3], of: 5, failed: [
            FocusStackReport.FailedFrame(index: 4, reason: "frame4 is damaged"),
            FocusStackReport.FailedFrame(index: 1, reason: "frame1 is damaged"),
        ])
        #expect(stack.depth == [0, 1, 2, 2.5, 3])
        #expect(stack.report.frames == 5 && stack.report.reference == 2)
        #expect(stack.report.failedFrames?.map(\.index) == [1, 4])
        #expect(stack.alignment.reference == 2)
        #expect(stack.alignment.transforms == [transforms[0], .identity, transforms[1], transforms[2], .identity])
        #expect(stack.alignment.gains == [gains[0], one, gains[1], gains[2], one])
        #expect(stack.alignment.correlations == [0.9, 0, 1, 0.8, 0])
    }

    @Test func `a stroke from a frame that didn't decode leaves the stack as it is`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (documentURL, _) = try stackDocument(frames: 4, in: folder)
        let engine = try RedlampEngine(
            stillTile: 2048, stackCache: folder.appendingPathComponent("cache"),
            decoder: RecordingDecoder(failing: ["frame1.png"]),
        )
        let unretouched = try engine.stacks.stack(at: documentURL)

        var document = try FocusStackDocument.read(documentURL)
        document.retouch = [
            FocusStackStroke(source: .frame("frame1.png"), radius: 0.2, hardness: 1, points: [SIMD2(0.75, 0.5)]),
        ]
        try document.write(to: documentURL)
        let stack = try engine.stacks.stack(at: documentURL)
        #expect(stack.report.failedFrames?.map(\.index) == [1])
        #expect(stack.decoded.samples == unretouched.decoded.samples)
    }

    @Test func `a decoder that isn't available fails the stack at once, not frame by frame`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (documentURL, _) = try stackDocument(frames: 6, in: folder)
        let decoder = RecordingDecoder(isAvailable: false)
        let engine = try RedlampEngine(
            stillTile: 2048, stackCache: folder.appendingPathComponent("cache"), decoder: decoder,
        )
        await #expect(throws: EngineError.decoderUnavailable) { try await engine.open(documentURL) }
        #expect(
            decoder.decoded.withLock(\.count) <= FocusStackCache.decodesAhead + 1,
            "one merge's decodes ahead, not a merge for each frame",
        )
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
