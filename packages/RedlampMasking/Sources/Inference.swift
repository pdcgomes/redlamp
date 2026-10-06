import CoreML
import Foundation
import Synchronization

/// Every Core ML model loads and predicts through `shared`, so the app can stop them before it
/// exits: `exit` destroys Metal Performance Shaders Graph's statics while other threads still run,
/// and a model still preparing or encoding its GPU work then reads them freed (EXC_BAD_ACCESS at
/// 0x8 in `MPSGraphOSLog`).
public final class Inference: Sendable {
    public static let shared = Inference()

    private let stopped = Mutex(false)
    private let running = DispatchGroup()

    /// The compiled model at `url`. Loading prepares its GPU work.
    func load(_ url: URL, configuration: MLModelConfiguration) throws -> MLModel {
        try run { try MLModel(contentsOf: url, configuration: configuration) }
    }

    /// `model`'s prediction for `input`.
    func predict(_ model: MLModel, from input: MLFeatureProvider) throws -> MLFeatureProvider {
        try run { try model.prediction(from: input) }
    }

    /// Runs `work`, or throws `CancellationError` once `stop(waitingAtMost:)` has been called.
    func run<Result>(_ work: () throws -> Result) throws -> Result {
        try stopped.withLock { stopped in
            guard !stopped else { throw CancellationError() }
            running.enter()
        }
        defer { running.leave() }
        return try work()
    }

    /// Whether a model is loading or predicting now.
    var isRunning: Bool {
        running.wait(timeout: .now()) == .timedOut
    }

    /// Lets no model load or predict again, and waits at most `timeout` for those running to
    /// return; false if one still runs.
    @discardableResult
    public func stop(waitingAtMost timeout: TimeInterval) -> Bool {
        stopped.withLock { $0 = true }
        return running.wait(timeout: .now() + timeout) == .success
    }
}
