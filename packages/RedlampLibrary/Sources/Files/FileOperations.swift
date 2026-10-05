import Foundation
import RedlampDocument
import Synchronization

/// The library's file operations (LIB-26, DEC-38): renames, moves, new folders and moves to the
/// Trash, each a batch of steps (`FileBatch`) planned from the files as they are, checked, written to
/// the journal in `LibraryPaths.root` and synced before anything moves, then run in order.
///
/// - **Together:** a photo moves with its raw or JPEG pair, its `.redlamp` sidecars beside it and on
///   this Mac, and other apps' sidecars named after it.
/// - **Nothing is ever overwritten:** a file where a step would put one, or a photo gone since the
///   batch was planned, stops the batch before it starts; a step that still meets one undoes itself.
/// - **Across volumes** a file is copied, checked by size and SHA-256, and only then removed.
/// - **A forced quit** leaves the journal, which `recover` finishes or rolls back at the next launch.
///   A failed step rolls the batch back. Cancelling stops it after a safe step, keeping what's done.
/// - **Undo** is a batch of its own, planned from where the photos are then.
/// - **The index follows** as the steps go, in batches: rows keep their IDs and get their new paths,
///   folders are made and moved, and no photo is read; `live` hears of every change. The store
///   needs nothing, since it's keyed by the photos' content.
///
/// One batch runs at a time; the file system's work runs off the caller.
public final class FileOperations: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths
    public let fileSystem: any LibraryFileSystem
    public let live: LibraryLive?
    public let journal: FileJournal
    /// Steps between writes to the index.
    static let stepsPerWrite = 250
    private let serial = Mutex<Task<Void, Never>?>(nil)
    let interruption = Mutex<Interruption?>(nil)

    /// `paths` defaults to the library whose index is `index`, at `LibraryPaths.index` in its folder.
    public init(
        index: LibraryIndex, paths: LibraryPaths? = nil, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        live: LibraryLive? = nil,
    ) {
        self.index = index
        self.paths = paths ?? LibraryPaths(root: index.url.deletingLastPathComponent())
        self.fileSystem = fileSystem
        self.live = live
        journal = FileJournal(paths: self.paths)
    }

    /// Where a forced quit is simulated, for the tests and the benchmark: the run stops as a killed
    /// process would, leaving the journal as it is.
    enum Interruption: Sendable, Hashable {
        case afterStep(Int)
        /// The step's files moved, but not yet logged.
        case beforeLogging(Int)
        /// After this many of the step's items.
        case withinStep(Int, items: Int)
    }

    struct ForcedQuit: Error {}

    // MARK: - Running

    /// Checks `batch` against the files as they are, writes it to the journal and runs it. Throws
    /// `FileOperationError.conflicts`, moving nothing, when something is in its way;
    /// `.failed` when a step failed and the batch was rolled back; `.unfinished` while a batch a
    /// forced quit interrupted waits for `recover`. Cancelling the task stops the batch after the next
    /// safe step.
    @discardableResult
    public func run(_ batch: FileBatch, progress: (@Sendable (FileProgress) -> Void)? = nil) async throws
        -> FileOutcome {
        try await serially { [self] in
            try await runNow(batch, progress: progress)
        }
    }

    /// What stops `batch` before it starts, as the files are now; empty when it can run.
    public func check(_ batch: FileBatch) async throws -> [FileConflict] {
        let locator = try await locator()
        let fileSystem = fileSystem
        return try await LibraryIndex.offCaller {
            FilePlanner(fileSystem: fileSystem, locator: locator).check(batch.steps).conflicts
        }
    }

    private func runNow(_ batch: FileBatch, progress: (@Sendable (FileProgress) -> Void)?) async throws
        -> FileOutcome {
        if let unfinished = try await unfinishedEntries().first {
            throw FileOperationError.unfinished(unfinished.id)
        }
        let locator = try await locator()
        let (fileSystem, journal) = (fileSystem, journal)
        let checked = try await LibraryIndex.offCaller {
            FilePlanner(fileSystem: fileSystem, locator: locator).check(batch.steps)
        }
        guard checked.conflicts.isEmpty else { throw FileOperationError.conflicts(checked.conflicts) }
        var batch = batch
        batch.steps = checked.steps
        let written = batch
        try await LibraryIndex.offCaller {
            journal.prune()
            try journal.write(written)
        }
        let runner = try FileRunner(
            batch: batch, log: journal.log(batch.id), fileSystem: fileSystem, store: SidecarStore(locator: locator),
            outcome: FileOutcome(batch: batch, state: .running), interruption: interruption.withLock { $0 },
        )
        return try await forward(runner, from: 0, locator: locator, progress: progress)
    }

    /// Runs the batch's steps from `start`, writing the index as it goes; rolls the batch back if a
    /// step fails.
    private func forward(
        _ runner: FileRunner, from start: Int, locator: SidecarLocator,
        progress: (@Sendable (FileProgress) -> Void)?,
    ) async throws -> FileOutcome {
        let batch = runner.batch
        let steps = batch.steps
        let cancelled = Cancellation()
        var next = start
        do {
            try await withTaskCancellationHandler {
                while next < steps.count {
                    let first = next
                    let end = try await LibraryIndex.offCaller {
                        var index = first
                        while index < steps.count {
                            try runner.perform(index)
                            index += 1
                            progress?(FileProgress(done: index, total: steps.count))
                            if steps[index - 1].isSafe, index - first >= Self.stepsPerWrite || cancelled.isSet {
                                break
                            }
                        }
                        return index
                    }
                    var changes = IndexChanges()
                    steps[first ..< end].forEach { changes.add($0) }
                    try await record(changes, locator: locator)
                    next = end
                    if cancelled.isSet, next < steps.count {
                        break
                    }
                }
            } onCancel: {
                cancelled.set()
            }
        } catch is ForcedQuit {
            throw ForcedQuit()
        } catch let error as FileOperationError {
            if case .stuck = error {
                throw error
            }
            let done = Set(runner.performed).union(0 ..< start)
            try await rollBack(runner, steps: done.sorted(by: >), locator: locator, progress: progress)
            throw error
        }
        let state: FileJournal.State = next < steps.count ? .stopped : .finished
        try await LibraryIndex.offCaller { try runner.log.state(state) }
        if let original = batch.undoes, state == .finished {
            try await LibraryIndex.offCaller { [journal] in try journal.log(original).state(.undone) }
        }
        var outcome = runner.outcome
        outcome.state = state
        outcome.done = next
        outcome.photos = Self.photos(in: steps[..<next])
        outcome.gone = batch.gone
        return outcome
    }

    /// Puts back what `steps` (done, last first) did, as their files say, and writes the index back.
    private func rollBack(
        _ runner: FileRunner, steps indexes: [Int], locator: SidecarLocator,
        progress: (@Sendable (FileProgress) -> Void)?,
    ) async throws {
        let batch = runner.batch
        let steps = batch.steps
        try await LibraryIndex.offCaller {
            try runner.log.state(.rollingBack)
            for (count, index) in indexes.enumerated() {
                do {
                    try runner.reverse(index, from: runner.states(of: index))
                } catch {
                    throw FileOperationError.stuck(
                        batch.id, path: steps[index].items.first?.source ?? steps[index].folder ?? "",
                        message: FileRunner.message(error),
                    )
                }
                progress?(FileProgress(done: indexes.count - count - 1, total: steps.count, isRollingBack: true))
            }
            try runner.log.state(.rolledBack)
        }
        var changes = IndexChanges()
        for index in indexes {
            changes.add(steps[index].inverse(trashed: Self.places(
                runner.trashed[index],
                count: steps[index].items.count,
            )))
        }
        try await record(changes, locator: locator)
    }

    // MARK: - Recovery

    /// Finishes, or rolls back as `choice` says, every batch a forced quit left unfinished, and writes
    /// the index as the files are then. A batch that can't be finished, because something took a
    /// place one of its steps needs, is rolled back. Returns what became of each.
    @discardableResult
    public func recover(_ choice: FileRecovery = .finish, progress: (@Sendable (FileProgress) -> Void)? = nil)
        async throws -> [FileOutcome] {
        try await serially { [self] in
            var outcomes: [FileOutcome] = []
            for entry in try await unfinishedEntries() {
                try await outcomes.append(recover(entry.id, choice, progress: progress))
            }
            return outcomes
        }
    }

    private func recover(_ id: UUID, _ choice: FileRecovery, progress: (@Sendable (FileProgress) -> Void)?)
        async throws -> FileOutcome {
        let journal = journal
        let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(id) }
        let locator = try await locator()
        let runner = try FileRunner(
            batch: batch, log: journal.log(id), fileSystem: fileSystem, store: SidecarStore(locator: locator),
            trashed: logged.trashed, outcome: FileOutcome(batch: batch, state: logged.state), interruption: nil,
        )
        let steps = batch.steps
        if logged.state == .rollingBack {
            try await rollBack(runner, steps: logged.done.sorted(by: >), locator: locator, progress: progress)
            var outcome = runner.outcome
            outcome.state = .rolledBack
            outcome.recoveredFrom = logged.done.count
            return outcome
        }
        // The steps logged done, then those a forced quit stopped before they were logged.
        let lastLogged = logged.done.max() ?? -1
        let (frontier, partial, names) = try await LibraryIndex.offCaller { runner.frontier(after: lastLogged) }
        var finishing = choice == .finish
        if finishing, frontier < steps.count {
            var rest = Array(steps[frontier...])
            if let partial {
                rest[0].items = zip(rest[0].items, partial).compactMap { $1 == .atSource ? $0 : nil }
            }
            let fileSystem = fileSystem
            let conflicts = try await LibraryIndex.offCaller { [rest] in
                FilePlanner(fileSystem: fileSystem, locator: locator).check(rest).conflicts
            }
            finishing = conflicts.isEmpty
        }
        if !finishing {
            try await LibraryIndex.offCaller {
                if let partial {
                    try runner.reverse(frontier, from: partial)
                }
            }
            let done = Set(logged.done).union(0 ..< frontier)
            try await rollBack(runner, steps: done.sorted(by: >), locator: locator, progress: progress)
            var outcome = runner.outcome
            outcome.state = .rolledBack
            outcome.recoveredFrom = frontier
            return outcome
        }
        var start = frontier
        try await LibraryIndex.offCaller {
            for step in lastLogged + 1 ..< frontier where !names.contains(step) {
                try runner.markDone(step)
            }
            for step in names {
                try runner.perform(step)
            }
            if let partial {
                try runner.perform(frontier, from: partial)
            }
        }
        if partial != nil {
            start += 1
        }
        var changes = IndexChanges()
        steps[..<start].forEach { changes.add($0) }
        try await record(changes, locator: locator)
        var outcome = try await forward(runner, from: start, locator: locator, progress: progress)
        outcome.recoveredFrom = frontier
        return outcome
    }

    // MARK: - The journal

    /// Every batch in the journal, oldest first.
    public func entries() async throws -> [FileJournal.Entry] {
        let journal = journal
        return try await LibraryIndex.offCaller { try journal.entries() }
    }

    /// The batches a forced quit left unfinished.
    public func unfinishedEntries() async throws -> [FileJournal.Entry] {
        try await entries().filter(\.state.isUnfinished)
    }

    /// The batch Undo would undo: the newest that's finished or stopped, its own Undo not run.
    public func lastUndoable() async throws -> FileJournal.Entry? {
        try await entries().last { $0.kind != .undo && ($0.state == .finished || $0.state == .stopped) }
    }

    // MARK: - Helpers

    /// The locator that places sidecars on this Mac for every root, whatever their placement, so a
    /// sidecar there has a place wherever its photo goes.
    func locator() async throws -> SidecarLocator {
        let folder = paths.sidecars
        let roots = try await index.read { reader in try LibrarySidecars.locatorRoots(reader) }
        return SidecarLocator(folder: folder, roots: roots)
    }

    static func photos(in steps: ArraySlice<FileStep>) -> Int {
        var ids = Set<Int64>()
        for step in steps where step.kind == .move || step.kind == .trash || step.kind == .putBack {
            ids.formUnion(step.photos.map(\.id))
            ids.formUnion(step.removed.map(\.photo.id))
        }
        return ids.count
    }

    /// Where a step's items went in the Trash, in their order.
    static func places(_ trashed: [Int: String]?, count: Int) -> [String?] {
        (0 ..< count).map { trashed?[$0] }
    }

    /// Runs `body` after the batches asked for before it.
    private func serially<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = serial.withLock { last -> Task<T, any Error> in
            let previous = last
            let task = Task {
                await previous?.value
                return try await body()
            }
            last = Task { _ = try? await task.value }
            return task
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// A flag set once, from any thread.
final class Cancellation: Sendable {
    private let flag = Atomic(false)

    var isSet: Bool {
        flag.load(ordering: .acquiring)
    }

    func set() {
        flag.store(true, ordering: .releasing)
    }
}
