import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

@MainActor
struct StackWorkspaceTests {
    /// A one-pixel grey image.
    private static func grey(_ value: UInt8) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data([value]) as CFData))
        return try #require(CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
    }

    @Test func `a frame left out because it couldn't be read is never a brush's source`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = ["a.png", "b.png", "c.png"].map { folder.appending(path: $0) }
        let documentURL = folder.appending(path: "stack.redlampstack")
        try FocusStackDocument(frames: frames, at: documentURL).write(to: documentURL)
        let engine = StubEngine()
        // Depth 140 of 255 is frame 1.1 of 0 ... 2: b, which didn't decode; c is the nearest that did.
        engine.focusStackPreview = try FocusStackPreview(
            image: Self.grey(0), depth: Self.grey(140),
            report: FocusStackReport(
                frames: 3, reference: 0, width: 1, height: 1, maximumScaleChange: 0, minimumCorrelation: 0.8,
                confidentDepthFraction: 1, timings: [:],
                failedFrames: [FocusStackReport.FailedFrame(index: 1, reason: "b.png is damaged")],
            ),
        )
        let model = StackWorkspaceModel(documentURL: documentURL, engine: engine)
        await model.merge()
        #expect(model.unreadable == [frames[1]])

        model.isRetouching = true
        model.brushSource = .frame(frames[1])
        await model.addStroke([CGPoint(x: 0.5, y: 0.5)])
        #expect(model.strokes.isEmpty, "the merge would skip its stroke")

        model.brushSource = .underCursor
        #expect(model.frame(at: CGPoint(x: 0.5, y: 0.5)) == frames[2])
        await model.addStroke([CGPoint(x: 0.5, y: 0.5)])
        #expect(model.strokes.map(\.source) == [.frame("c.png")])
    }
}
