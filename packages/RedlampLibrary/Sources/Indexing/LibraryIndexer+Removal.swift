import Foundation

public extension LibraryIndexer {
    /// Takes out the rows of the roots marked removed (`LibraryIndex.Writer.markRemoved`), a transaction of at
    /// most `configuration.batchSize` photos at a time, in the indexer's turn: after the runs asked for before
    /// it, whose last photos of a root it takes out too, and before those asked for after, so a root indexed
    /// again once it's removed is read afresh. What's kept beside the photos' rows goes with them, but for the
    /// photos a batch of the file journal beside the index can bring back under their IDs (LIB-26). Each batch is
    /// reported as photos removed, then the run finished. Cancelling the task iterating the events stops it between
    /// batches; the marks stay for the next sweep.
    func sweepRemovedRoots() -> AsyncStream<LibraryIndexerEvent> {
        inTurn { [index, configuration] events in
            let started = ContinuousClock.now
            var summary = LibraryIndexerSummary()
            let journal = FileJournal(paths: LibraryPaths(root: index.url.deletingLastPathComponent()))
            let restorable = try? await LibraryIndex.offCaller { journal.restorable() }
            while !Task.isCancelled {
                let sweep: RootSweep
                do {
                    sweep = try await index.write {
                        try $0.sweepRemoved(limit: configuration.batchSize, keeping: restorable)
                    }
                } catch {
                    summary.failures += 1
                    events.yield(.failed(path: "", message: String(describing: error)))
                    break
                }
                summary.photosRemoved += sweep.photos.count
                summary.foldersRemoved += sweep.folders
                if !sweep.photos.isEmpty {
                    events.yield(.photosRemoved(sweep.photos))
                }
                guard sweep.more else { break }
            }
            summary.elapsed = ContinuousClock.now - started
            events.yield(.finished(summary))
        }
    }
}
