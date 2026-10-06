import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The time from each render's request to its frame reaching the editor, which the performance
/// sweep reports (RESP-10).
@MainActor
struct FrameLatencyTests {
    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = GatedEngine()
        engine.sendsFrames = true
        let model = EditorModel(engine: engine)
        model.canvas.updateView(size: CGSize(width: 300, height: 200), backingScale: 1)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 400 where !model.hasFrame {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.hasFrame)
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    private func holdMainActor(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test func `each frame received records the time since its render was asked for`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let frames = model.debugFrameCount
        let latencies = model.debugFrameLatencies.count
        model.beginEdit(.exposure)
        model.setSliderValue(.exposure, 0.5)
        // The frame is already sent; holding the main actor keeps it from being received.
        holdMainActor(for: 0.05)
        for _ in 0 ..< 400 where model.debugFrameCount == frames {
            try await Task.sleep(for: .milliseconds(5))
        }
        defer { model.endEdit() }
        try #require(model.debugFrameCount == frames + 1)
        #expect(model.debugFrameLatencies.count == latencies + 1)
        let latency = try #require(model.debugFrameLatencies.last)
        #expect(latency >= .milliseconds(50))
        #expect(latency < .seconds(2))
    }
}
