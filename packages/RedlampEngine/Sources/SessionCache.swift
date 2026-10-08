import Foundation
import Synchronization

/// Decoded images kept on the GPU, so moving between photos doesn't wait on a decode.
///
/// `wanted` lists the images to keep ready, most important first; the first is the one
/// being opened. Decodes start in that order, a few at a time, and finished sessions stay
/// cached within a byte budget, least recently used evicted first. Wanted sessions go last,
/// least wanted first, and are decoded only while they fit; the one being opened is kept
/// whatever its size.
final class SessionCache: Sendable {
    typealias Build = @Sendable (URL) throws -> ImageSession
    private typealias Waiter = CheckedContinuation<ImageSession, any Error>

    /// The image being opened may use any slot; prefetches get fewer, so it never queues
    /// behind them.
    private static let maxDecodes = 3
    private static let maxPrefetchDecodes = 2

    private struct Entry {
        let session: ImageSession
        let bytes: Int
        var lastUse: UInt64
    }

    private struct Work {
        var start: [URL] = []
        var resume: [(Waiter, Result<ImageSession, any Error>)] = []
    }

    private struct State {
        var ready: [URL: Entry] = [:]
        var decoding: Set<URL> = []
        var failed: Set<URL> = []
        var waiters: [URL: [Waiter]] = [:]
        var wanted: [URL] = []
        /// Decoding when every session was let go of, and not asked for since: not kept once done.
        var released: Set<URL> = []
        var clock: UInt64 = 0
        var bytes = 0
        /// What the latest decoded session held: the guess for one not decoded yet.
        var typical = 0

        mutating func touch(_ url: URL) -> ImageSession? {
            guard var entry = ready[url] else { return nil }
            clock += 1
            entry.lastUse = clock
            ready[url] = entry
            return entry.session
        }

        mutating func insert(_ session: ImageSession, for url: URL, budget: Int) {
            clock += 1
            let size = session.allocatedBytes
            ready[url] = Entry(session: session, bytes: size, lastUse: clock)
            bytes += size
            typical = size
            while bytes > budget,
                  let oldest = ready.filter({ !wanted.contains($0.key) })
                  .min(by: { $0.value.lastUse < $1.value.lastUse }) {
                remove(oldest.key)
            }
            for url in wanted.dropFirst().reversed() where bytes > budget {
                remove(url)
            }
        }

        mutating func remove(_ url: URL) {
            if let entry = ready.removeValue(forKey: url) {
                bytes -= entry.bytes
            }
        }

        /// Lets go of every session but those of `kept`.
        mutating func keep(only kept: some Sequence<URL>) {
            let kept = Set(kept)
            for url in Array(ready.keys) where !kept.contains(url) {
                remove(url)
            }
        }

        mutating func schedule(budget: Int) -> Work {
            var work = Work()
            // Nothing would ever finish these: they aren't decoding and nobody wants them.
            for (url, pending) in waiters where !decoding.contains(url) && !wanted.contains(url) {
                waiters[url] = nil
                work.resume += pending.map { ($0, .failure(CancellationError())) }
            }
            var planned = 0
            for (index, url) in wanted.enumerated() where !failed.contains(url) {
                planned += ready[url]?.bytes ?? typical
                // Past the one being opened, only what fits: on a small budget the least wanted
                // aren't decoded at all.
                if index > 0, planned > budget {
                    break
                }
                guard ready[url] == nil, !decoding.contains(url),
                      decoding.count < (index == 0 ? SessionCache.maxDecodes : SessionCache.maxPrefetchDecodes)
                else { continue }
                decoding.insert(url)
                work.start.append(url)
            }
            return work
        }
    }

    private let state = Mutex(State())
    private let budget: Int
    private let build: Build

    init(budget: Int, build: @escaping Build) {
        self.budget = budget
        self.build = build
    }

    /// The session for `url` if it is already decoded.
    func cached(_ url: URL) -> ImageSession? {
        state.withLock { $0.touch(url) }
    }

    /// The session for `url`, decoding it first if needed. `url` becomes the most wanted image.
    func session(for url: URL) async throws -> ImageSession {
        if let session = cached(url) {
            return session
        }
        return try await withCheckedThrowingContinuation { continuation in
            let work = state.withLock { state -> Work in
                if let session = state.touch(url) {
                    return Work(resume: [(continuation, .success(session))])
                }
                state.failed.remove(url)
                state.released.remove(url)
                state.wanted.removeAll { $0 == url }
                state.wanted.insert(url, at: 0)
                state.waiters[url, default: []].append(continuation)
                return state.schedule(budget: budget)
            }
            run(work)
        }
    }

    /// Forgets `url`'s session, so the next request decodes the file again.
    func invalidate(_ url: URL) {
        state.withLock { state in
            state.remove(url)
            state.failed.remove(url)
        }
    }

    /// Lets go of every session, those still decoding once they're done, and wants none.
    func removeAll() {
        state.withLock { state in
            state.wanted = []
            state.keep(only: [])
            state.released = state.decoding
        }
    }

    /// What the cached sessions hold, as the budget counts it.
    var bytesCached: Int {
        state.withLock { $0.bytes }
    }

    /// Lets go of sessions when the system runs short of memory: on a warning those not wanted,
    /// when critical all but the one being opened. The next `prefetch` decodes them again.
    func relieve(_ pressure: DispatchSource.MemoryPressureEvent) {
        state.withLock { state in
            if pressure.contains(.critical) {
                state.keep(only: state.wanted.prefix(1))
            } else if pressure.contains(.warning) {
                state.keep(only: state.wanted)
            }
        }
    }

    func prefetch(_ urls: [URL]) {
        let work = state.withLock { state -> Work in
            var seen = Set<URL>()
            state.wanted = urls.filter { seen.insert($0).inserted }
            state.released.subtract(state.wanted)
            return state.schedule(budget: budget)
        }
        run(work)
    }

    private func finish(_ url: URL, _ result: Result<ImageSession, any Error>) {
        let work = state.withLock { state -> Work in
            state.decoding.remove(url)
            switch result {
            case let .success(session):
                if state.released.remove(url) == nil {
                    state.insert(session, for: url, budget: budget)
                }
            case .failure: state.failed.insert(url)
            }
            let finished = state.waiters.removeValue(forKey: url) ?? []
            var work = state.schedule(budget: budget)
            work.resume += finished.map { ($0, result) }
            return work
        }
        run(work)
    }

    private func run(_ work: Work) {
        for (waiter, result) in work.resume {
            waiter.resume(with: result)
        }
        for url in work.start {
            Task.detached(priority: .userInitiated) { [self] in
                finish(url, Result { try build(url) })
            }
        }
    }
}
