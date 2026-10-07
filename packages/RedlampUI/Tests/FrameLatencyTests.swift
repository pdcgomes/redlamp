import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The time from each render's request to its frame reaching the editor, which the performance
/// sweep reports (RESP-10).
@MainActor
struct FrameLatencyTests {
    private func openEditor() async throws -> (EditorModel, GatedEngine, () -> Void) {
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
        // Opening renders more than once, and on a busy Mac a later frame can still be on its
        // way when the first is shown.
        try await receiveEveryFrame(model, from: engine)
        return (model, engine, { try? FileManager.default.removeItem(at: folder) })
    }

    private func receiveEveryFrame(_ model: EditorModel, from engine: GatedEngine) async throws {
        for _ in 0 ..< 400 where model.debugFrameCount < engine.framesSent {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.debugFrameCount == engine.framesSent)
    }

    private func holdMainActor(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test func `each frame received records the time since its render was asked for`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        let frames = model.debugFrameCount
        let latencies = model.debugFrameLatencies.count
        model.beginEdit(.exposure)
        model.setSliderValue(.exposure, 0.5)
        // The frame is already sent; holding the main actor keeps it from being received.
        holdMainActor(for: 0.05)
        try #require(engine.framesSent == frames + 1)
        try await receiveEveryFrame(model, from: engine)
        defer { model.endEdit() }
        #expect(model.debugFrameLatencies.count == latencies + 1)
        let latency = try #require(model.debugFrameLatencies.last)
        #expect(latency >= .milliseconds(50))
        #expect(latency < .seconds(2))
    }
}
