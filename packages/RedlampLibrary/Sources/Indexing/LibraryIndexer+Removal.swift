import Foundation

public extension LibraryIndexer {
    /// Takes out the rows of the roots marked removed (`LibraryIndex.Writer.markRemoved`), a transaction of at
    /// most `configuration.batchSize` photos and `sweepBudget` at a time, in the indexer's turn: after the runs
    /// asked for before it, whose last photos of a root it takes out too, and before those asked for after, so a
    /// root indexed again once it's removed is read afresh. What's kept beside the photos' rows goes with them, but
    /// for the photos a batch of the file journal beside the index can bring back under their IDs (LIB-26). Each
    /// batch is reported as photos removed; the run is finished once the text index has nothing left to merge
    /// (`IndexTextMerges`). Other writes go between the batches and between the merges' steps. Cancelling the task
    /// iterating the events stops it between batches; the marks stay for the next sweep.
    func sweepRemovedRoots() -> AsyncStream<LibraryIndexerEvent> {
        inTurn { [index, configuration] events in
            let started = ContinuousClock.now
            var summary = LibraryIndexerSummary()
            let journal = FileJournal(paths: LibraryPaths(root: index.url.deletingLastPathComponent()))
            let restorable = try? await LibraryIndex.offCaller { journal.restorable() }
            var swept = false
            while !Task.isCancelled {
                let sweep: RootSweep
                do {
                    sweep = try await index.write {
                        try $0.sweepRemoved(
                            limit: configuration.batchSize,
                            keeping: restorable,
                            budget: Self.sweepBudget,
                        )
                    }
                } catch {
                    summary.failures += 1
                    events.yield(.failed(path: "", message: String(describing: error)))
                    break
                }
                summary.photosRemoved += sweep.photos.count
                summary.foldersRemoved += sweep.folders
                if !sweep.photos.isEmpty {
                    swept = true
                    events.yield(.photosRemoved(sweep.photos))
                }
                guard sweep.more else { break }
                await index.settle()
            }
            if swept, !Task.isCancelled {
                await index.mergeText()
            }
            summary.elapsed = ContinuousClock.now - started
            events.yield(.finished(summary))
        }
    }
}

extension LibraryIndexer {
    /// How long a sweep's batch holds the writer, about: within a frame.
    static let sweepBudget = Duration.milliseconds(8)
}
