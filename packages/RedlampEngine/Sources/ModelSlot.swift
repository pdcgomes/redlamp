import Foundation
import Synchronization

/// Where the engine keeps one AI model: loaded once, however many ask for it at a time, and
/// unloaded when nothing has asked for it in `idle`, or when told to.
final class ModelSlot<Model: Sendable>: Sendable {
    private struct State {
        var model: Model?
        var loading: Task<Model, any Error>?
        var lastUse = ContinuousClock.now
        var watching = false
        /// Moves on at each unload, so a load finishing after it isn't kept.
        var generation = 0
    }

    private enum Next {
        case loaded(Model)
        case loading(Task<Model, any Error>, generation: Int)
    }

    private let state = Mutex(State())
    private let idle: Duration

    init(idle: Duration = .seconds(300)) {
        self.idle = idle
    }

    var model: Model? {
        state.withLock { $0.model }
    }

    /// The model, made by `load` unless it's loaded or being loaded.
    func model(loading load: @escaping @Sendable () async throws -> Model) async throws -> Model {
        let next = state.withLock { state -> Next in
            state.lastUse = .now
            if let model = state.model {
                return .loaded(model)
            }
            let loading = state.loading ?? Task.detached(priority: .userInitiated) { try await load() }
            state.loading = loading
            return .loading(loading, generation: state.generation)
        }
        switch next {
        case let .loaded(model):
            return model
        case let .loading(loading, generation):
            return try await finish(loading, generation: generation)
        }
    }

    private func finish(_ loading: Task<Model, any Error>, generation: Int) async throws -> Model {
        let result = await loading.result
        let watch = state.withLock { state -> Bool in
            guard state.generation == generation, state.loading == loading else { return false }
            state.loading = nil
            guard case let .success(model) = result else { return false }
            state.model = model
            state.lastUse = .now
            defer { state.watching = true }
            return !state.watching
        }
        if watch {
            watchIdle()
        }
        return try result.get()
    }

    func unload() {
        state.withLock { state in
            state.model = nil
            state.loading = nil
            state.watching = false
            state.generation += 1
        }
    }

    private func watchIdle() {
        Task.detached(priority: .utility) { [weak self, idle] in
            var wait = idle
            while true {
                try? await Task.sleep(for: wait)
                guard let self else { return }
                let left = state.withLock { state -> Duration? in
                    guard state.watching, state.model != nil else { return nil }
                    let left = ContinuousClock.now.duration(to: state.lastUse + idle)
                    guard left > .zero else {
                        state.model = nil
                        state.watching = false
                        return nil
                    }
                    return left
                }
                guard let left else { return }
                wait = left
            }
        }
    }
}
