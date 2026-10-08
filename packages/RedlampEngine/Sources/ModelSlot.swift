import Foundation
import Synchronization

/// Where the engine keeps one AI model once it's loaded.
final class ModelSlot<Model: Sendable>: Sendable {
    private let loaded = Mutex<Model?>(nil)
    private let idle: Duration

    init(idle: Duration = .seconds(300)) {
        self.idle = idle
    }

    var model: Model? {
        loaded.withLock { $0 }
    }

    /// The model, made by `load` unless it's already loaded.
    func model(loading load: @escaping @Sendable () async throws -> Model) async throws -> Model {
        if let model {
            return model
        }
        let made = try await Task.detached(priority: .userInitiated) { try await load() }.value
        loaded.withLock { $0 = made }
        return made
    }

    func unload() {}
}
