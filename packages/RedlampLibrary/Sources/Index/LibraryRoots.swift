import Foundation
import Synchronization

/// Folders taken out of the library (LIB-05, LIB-10), as Lightroom Classic's Remove takes a folder out of its
/// catalog: a root Folders no longer has leaves every list, count and search, then the index, with its folders
/// and photos, their keywords, collection memberships and text. Nothing on disk changes, and indexing the
/// folder again brings everything back from its photos and their sidecars: ratings, keywords, collections. A
/// root that can't be found isn't taken out: its photos stay, offline.
///
/// `remove` marks the root removed in one small transaction (`LibraryIndex.Writer.markRemoved`), keeping the
/// folders of the roots still followed, and the column store drops its photos at once; their keywords and
/// collection memberships go next, so the counts made from them follow; the rows go last, a batch at a time in
/// the indexer's turn (`LibraryIndexer.sweepRemovedRoots`). Every read of the store leaves out what's marked,
/// so a quit partway shows none of the root, and `resume` sweeps the rest at the next launch.
public final class LibraryRoots: Sendable {
    public let index: LibraryIndex
    public let indexer: LibraryIndexer
    public let live: LibraryLive
    private let state = Mutex(State())

    private struct State {
        /// The sweeps asked of the indexer, each in its turn, that haven't been followed yet.
        var runs: [AsyncStream<LibraryIndexerEvent>] = []
        /// Follows them, one after another, while there are any.
        var sweeping: Task<Void, Never>?
        var stopped = false
    }

    public init(index: LibraryIndex, indexer: LibraryIndexer, live: LibraryLive) {
        self.index = index
        self.indexer = indexer
        self.live = live
    }

    /// Takes the root at `root` out of the library, keeping the folders of `kept`, the roots still followed, and
    /// returns once the open lists leave its photos out and so do the counts of keywords and collections; its rows
    /// go behind (`swept`). Nil when the index has nothing of it to take out, or the photos stay in a root of
    /// `kept` that holds it.
    @discardableResult
    public func remove(_ root: URL, keeping kept: [URL]) async throws -> RootRemoval? {
        let (path, others) = (LibraryIndexer.path(root), kept.map(LibraryIndexer.path))
        guard let removal = try await index.write({ try $0.markRemoved(path, keeping: others) }) else { return nil }
        if removal.photos.isEmpty {
            try await live.engine.updateNames()
        } else {
            await live.remove(removal.photos)
            try await index.write { try $0.unlinkPhotos(removal.photos) }
        }
        sweep()
        return removal
    }

    /// Sweeps what a removal a quit cut short left, after the indexer's runs asked for before: at launch.
    public func resume() async {
        if await (try? index.read { try !$0.removedRoots().isEmpty }) == true {
            sweep()
        }
    }

    /// Returns once the sweeps asked for so far are over.
    public func swept() async {
        await state.withLock { $0.sweeping }?.value
    }

    /// Stops sweeping after the batch under way, as the app quits: the marks stay, and the next `resume` sweeps
    /// the rest.
    public func stop() {
        let sweeping = state.withLock { state in
            state.stopped = true
            state.runs = []
            return state.sweeping
        }
        sweeping?.cancel()
    }

    /// Asks the indexer for a sweep in its turn, now, and follows it: the store reads the photos of each batch
    /// again, which keeps it reflecting the index's generation, and finds them gone.
    private func sweep() {
        state.withLock { state in
            guard !state.stopped else { return }
            state.runs.append(indexer.sweepRemovedRoots())
            guard state.sweeping == nil else { return }
            let engine = live.engine
            state.sweeping = Task.detached(priority: .utility) { [self] in
                while let events = nextRun() {
                    for await event in events {
                        if case let .photosRemoved(ids) = event {
                            try? await engine.update(photos: ids)
                        }
                    }
                }
            }
        }
    }

    /// The next sweep to follow; nil, ending the task following them, when there's none.
    private func nextRun() -> AsyncStream<LibraryIndexerEvent>? {
        state.withLock { state in
            guard !state.runs.isEmpty, !Task.isCancelled else {
                state.sweeping = nil
                return nil
            }
            return state.runs.removeFirst()
        }
    }
}
