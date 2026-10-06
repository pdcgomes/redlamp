import Metal

/// How a command buffer a stage recorded state for came to nothing.
enum CommandBufferFailure: Sendable {
    /// Dropped uncommitted, after encoding into it began: nothing in it ran.
    case abandoned
    /// Committed, and failed on the GPU: what it was to write can't be relied on.
    case failed
}

/// A stage that records state for a command buffer before the buffer runs (cache entries, keys,
/// textures the buffer is to write) and undoes it when the buffer comes to nothing. The engine
/// calls every one it holds from each render error path (`RedlampEngine.rollBack`), on the queue
/// that encoded the buffer, after the buffer has completed or been dropped.
protocol CommandBufferRollback: AnyObject {
    func rollBack(_ commands: any MTLCommandBuffer, after failure: CommandBufferFailure)
}

extension DetailStage: CommandBufferRollback {
    func rollBack(_ commands: any MTLCommandBuffer, after failure: CommandBufferFailure) {
        switch failure {
        case .abandoned: abandon(commands)
        case .failed: forget(commands)
        }
    }
}

extension RetouchStage: CommandBufferRollback {
    func rollBack(_ commands: any MTLCommandBuffer, after _: CommandBufferFailure) {
        forget(commands)
    }
}
