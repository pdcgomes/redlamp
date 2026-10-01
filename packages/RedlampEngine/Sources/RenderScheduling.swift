import CoreGraphics
import Foundation
import RedlampEngineAPI
import Synchronization

/// A still waiting for, or being rendered on, the render queue. `lastYield` is only touched
/// on the render queue; everything else is locked or atomic.
final class StillJob: @unchecked Sendable {
    let request: StillRequest
    let session: ImageSession
    let continuation = Mutex<CheckedContinuation<CGImage, any Error>?>(nil)
    private let cancelled = Atomic<Bool>(false)
    /// When the still last yielded (or started), for the thermal cooldown.
    var lastYield = ContinuousClock.now

    init(request: StillRequest, session: ImageSession) {
        self.request = request
        self.session = session
    }

    var isCancelled: Bool {
        cancelled.load(ordering: .relaxed)
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    func finish(_ result: Result<CGImage, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

/// Stills waiting for the render queue: previews (thumbnails, look browsers) before exports.
struct StillLanes {
    var previews: [StillJob] = []
    var exports: [StillJob] = []
    var isDraining = false

    mutating func next(previewsOnly: Bool = false) -> StillJob? {
        if !previews.isEmpty {
            return previews.removeFirst()
        }
        return previewsOnly || exports.isEmpty ? nil : exports.removeFirst()
    }
}

extension RedlampEngine {
    /// Queues a still in its lane, starting the drain if none is running.
    func schedule(_ job: StillJob) {
        let start = stillLanes.withLock { lanes -> Bool in
            if job.request.purpose == .export {
                lanes.exports.append(job)
            } else {
                lanes.previews.append(job)
            }
            guard !lanes.isDraining else { return false }
            lanes.isDraining = true
            return true
        }
        if start {
            renderQueue.async { [self] in drainStills() }
        }
    }

    /// A cancelled still that hasn't started leaves its lane at once; a running one stops at
    /// its next yield.
    func cancel(_ job: StillJob) {
        job.cancel()
        let waiting = stillLanes.withLock { lanes -> Bool in
            let count = lanes.previews.count + lanes.exports.count
            lanes.previews.removeAll { $0 === job }
            lanes.exports.removeAll { $0 === job }
            return lanes.previews.count + lanes.exports.count < count
        }
        if waiting {
            job.finish(.failure(CancellationError()))
        }
    }

    private func drainStills() {
        while let job = stillLanes.withLock({ lanes -> StillJob? in
            if let job = lanes.next() {
                return job
            }
            lanes.isDraining = false
            return nil
        }) {
            run(job)
        }
    }

    private func run(_ job: StillJob) {
        guard !job.isCancelled else {
            job.finish(.failure(CancellationError()))
            return
        }
        runningStills.append(job)
        defer { runningStills.removeLast() }
        job.lastYield = .now
        job.finish(Result { try renderStillNow(job.request, session: job.session) })
    }

    /// Called between a still's tiles. The canvas comes first: pending interactive renders run
    /// here, so a long export never holds up a frame by more than a tile. Inside an export,
    /// waiting previews run too, and a hot machine (thermal state serious or critical) pauses
    /// while still serving the canvas. A cancelled still stops here.
    func yieldBetweenTiles() throws {
        guard DispatchQueue.getSpecific(key: Self.renderQueueKey) != nil else { return }
        let job = runningStills.last
        if job?.isCancelled == true {
            throw CancellationError()
        }
        serveInteractive()
        guard let job, job.request.purpose == .export else { return }
        while let preview = stillLanes.withLock({ $0.next(previewsOnly: true) }) {
            run(preview)
        }
        let pause = Self.cooldown(after: .now - job.lastYield, thermalState: thermalState())
        let resume = ContinuousClock.now + pause
        while ContinuousClock.now < resume {
            if job.isCancelled {
                throw CancellationError()
            }
            serveInteractive()
            Thread.sleep(forTimeInterval: 0.005)
        }
        job.lastYield = .now
    }

    /// How long an export rests after `work`: as long again when the machine is hot, three
    /// times as long when it is critical, so the GPU runs at a half or a quarter of its duty.
    static func cooldown(after work: Duration, thermalState: ProcessInfo.ThermalState) -> Duration {
        switch thermalState {
        case .serious: work
        case .critical: work * 3
        default: .zero
        }
    }
}
