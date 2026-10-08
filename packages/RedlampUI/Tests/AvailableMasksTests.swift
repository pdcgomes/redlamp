import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Which AI masks the engine offers for the open photo. The first ask builds the model
/// catalogue, which can take seconds on a busy Mac (RESP-15).
@MainActor
struct AvailableMasksTests {
    /// The main actor's longest wait between turns while it runs.
    @MainActor private final class Heartbeat {
        private var last = ContinuousClock.now
        private(set) var longestGap = Duration.zero
        private var task: Task<Void, Never>?

        func start() {
            last = .now
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard let self else { return }
                    longestGap = max(longestGap, .now - last)
                    last = .now
                }
            }
        }

        func stop() {
            task?.cancel()
            longestGap = max(longestGap, .now - last)
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `opening a photo doesn't wait on the engine's list of AI masks`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = GatedEngine()
        engine.base.availableKinds = [.subject, .sky]
        engine.maskKindsDelay = 3
        let model = EditorModel(engine: engine)
        let heartbeat = Heartbeat()
        heartbeat.start()
        model.select(folder.appending(path: "IMG_0001.ARW"))
        try await eventually { model.info != nil && model.availableAIMaskKinds == [.subject, .sky] }
        heartbeat.stop()
        try #require(model.info != nil)
        #expect(model.canCreateMask(.subject))
        #expect(model.canCreateMask(.sky))
        #expect(heartbeat.longestGap < .milliseconds(1500), "the main actor was held for \(heartbeat.longestGap)")
    }
}
