import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

/// Where an import has got to, as it runs.
public struct ImportProgress: Sendable, Hashable {
    public var photos: Int
    public var done: Int
    public var failed: Int
    public var bytes: Int64
    public var copied: Int64
}

/// What an import did.
public struct ImportOutcome: Sendable, Hashable {
    /// A source's part: a card can be erased only once every photo chosen from it is verified at every
    /// destination.
    public struct Source: Sendable, Hashable {
        public var id: String
        public var name: String
        public var kind: ImportSource.Kind
        /// Photos the plan copies from it.
        public var photos: Int
        public var verified: Int
        public var failed: Int
        /// Every photo the plan copies from it is verified at the destination and the backup, and the
        /// import finished.
        public var isSafeToErase: Bool
    }

    public struct Failure: Sendable, Hashable {
        public var photo: String
        public var message: String
    }

    public var id: UUID
    public var state: ImportJournal.State
    public var photos: Int
    /// Photos whose every file is verified at every target and in place.
    public var verified: Int
    /// Files in place at the destination, and at the backup.
    public var files: Int
    public var backups: Int
    /// The bytes read from the sources and copied.
    public var bytes: Int64
    public var failures: [Failure]
    public var sources: [Source]
    /// `.redlamp` sidecars written at the destination with the choices made and the metadata preset.
    public var sidecars: Int
    /// Photos whose sidecar couldn't be written, by path.
    public var sidecarsFailed: [String]
    /// Photos the index added.
    public var indexed: Int
    public var elapsed: Duration
    /// For an import a forced quit interrupted: the photos it had done.
    public var recoveredFrom: Int?

    /// Every source can be erased.
    public var isSafeToErase: Bool {
        !sources.isEmpty && sources.allSatisfy(\.isSafeToErase)
    }
}

/// Copies an import's plan (LIB-27): the plan is written to the journal and synced before anything is
/// copied, then each photo's files are copied to the destination and the backup at once, a few photos
/// at a time from each source volume, through its readers (`ImportCopier`): each file read once, and
/// verified by its size and SHA-256 at every target before it's renamed into place, never over
/// anything. A photo that fails leaves nothing at either target; the others go on. Then its `.redlamp`
/// gets the choices made while browsing and the metadata preset, and the index and live lists hear of
/// the folders it's in, in batches. A forced quit leaves the journal, which `recover` finishes at the
/// next launch, keeping every copy already verified. One import runs at a time.
public final class Importer: Sendable {
    public let library: ImportLibrary
    /// The sources' file system.
    public let fileSystem: any LibraryFileSystem
    /// The destination's and the backup's.
    public let destinationFileSystem: any LibraryFileSystem
    public let volumes: VolumeIORegistry
    public let journal: ImportJournal
    let interruption = Mutex<Interruption?>(nil)
    private let serial = Mutex<Task<Void, Never>?>(nil)

    /// Photos copied at once from each source volume: its readers' width, waiting on the targets'
    /// writes and checks in between.
    static let perVolume = 4
    /// Photos placed between the index's updates.
    static let indexBatch = 250

    /// Where a forced quit is simulated, for the tests and the benchmark: the run stops as a killed
    /// process would, leaving the journal as it is.
    enum Interruption: Sendable, Hashable {
        /// Once this many photos are done.
        case afterPhotos(Int)
        /// A photo's files verified and logged, but not yet renamed into place.
        case beforePlacing(Int)
    }

    struct ForcedQuit: Error {}

    public init(
        library: ImportLibrary, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        destinationFileSystem: any LibraryFileSystem = LocalFileSystem(), volumes: VolumeIORegistry? = nil,
    ) {
        self.library = library
        self.fileSystem = fileSystem
        self.destinationFileSystem = destinationFileSystem
        self.volumes = volumes ?? VolumeIORegistry(fileSystem: fileSystem)
        journal = ImportJournal(paths: library.paths)
    }

    // MARK: - Running

    /// Writes `plan` to the journal and copies it. Throws `ImportError.unfinished` while an import a
    /// forced quit interrupted waits for `recover`. Cancelling the task stops it once the photos being
    /// copied are done.
    @discardableResult
    public func run(_ plan: ImportPlan, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws
        -> ImportOutcome {
        try await serially { [self] in
            if let unfinished = try await unfinishedEntries().first {
                throw ImportError.unfinished(unfinished.id)
            }
            let journal = journal
            try await LibraryIndex.offCaller {
                journal.prune()
                try journal.write(plan)
            }
            return try await perform(plan, logged: ImportJournal.Progress(), progress: progress)
        }
    }

    /// Finishes every import a forced quit left unfinished: photos verified and placed are kept, the
    /// rest copied from their sources, which have to be there as they were.
    @discardableResult
    public func recover(progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> [ImportOutcome] {
        try await serially { [self] in
            var outcomes: [ImportOutcome] = []
            for entry in try await unfinishedEntries() {
                let journal = journal
                let (plan, logged) = try await LibraryIndex.offCaller { try journal.load(entry.id) }
                var outcome = try await perform(plan, logged: logged, progress: progress)
                outcome.recoveredFrom = logged.done.count
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// Every import in the journal, oldest first.
    public func entries() async throws -> [ImportJournal.Entry] {
        let journal = journal
        return try await LibraryIndex.offCaller { try journal.entries() }
    }

    public func unfinishedEntries() async throws -> [ImportJournal.Entry] {
        try await entries().filter(\.state.isUnfinished)
    }

    // MARK: - Photos

    private struct Tally: Sendable {
        var verified = Set<Int>()
        var failed: [Int: String] = [:]
        var files = 0
        var backups = 0
        var bytes: Int64 = 0
        var sidecars = 0
        var sidecarsFailed: [String] = []
        var indexed = 0
        var waitingToIndex = Set<String>()
        var placedSinceIndexing = 0
    }

    /// One run's counts, and the index's updates, one after another.
    private final class Run: Sendable {
        let tally = Mutex(Tally())
        let indexing = Mutex<Task<Void, Never>?>(nil)

        var counts: Tally {
            tally.withLock { $0 }
        }

        /// Runs `update` after the updates asked for before it.
        func index(_ update: @escaping @Sendable () async -> Int) {
            indexing.withLock { last in
                let previous = last
                last = Task {
                    await previous?.value
                    let inserted = await update()
                    self.tally.withLock { $0.indexed += inserted }
                }
            }
        }

        func indexed() async {
            await indexing.withLock { $0 }?.value
        }
    }

    private func perform(
        _ plan: ImportPlan, logged: ImportJournal.Progress, progress: (@Sendable (ImportProgress) -> Void)?,
    ) async throws -> ImportOutcome {
        let started = ContinuousClock.now
        let log = try journal.log(plan.id)
        try log.state(.running)
        let roots = [plan.settings.destination] + (plan.settings.backup.map { [$0] } ?? [])
        let copier = ImportCopier(fileSystem: destinationFileSystem, roots: roots)
        let locator = try await locator()
        let run = Run()
        let destination = LibraryIndexer.path(plan.settings.destination)
        run.tally.withLock { tally in
            tally.verified.formUnion(logged.done)
            for index in logged.done {
                if let copy = plan.items[index].copies.first {
                    tally.waitingToIndex.insert(FilePlanner.split(destination + "/" + copy.path).folder)
                }
            }
        }
        let pending = plan.items.indices.filter { !logged.done.contains($0) }
        let sources = Dictionary(plan.sources.map { ($0.id, $0) }) { first, _ in first }
        var byVolume: [String: [Int]] = [:]
        var readers: [String: VolumeIO] = [:]
        for index in pending {
            guard let source = sources[plan.items[index].source] else { continue }
            let key = VolumeIORegistry.key(for: source.volume, probe: source.url)
            byVolume[key, default: []].append(index)
            readers[key] = readers[key] ?? volumes.io(for: source.volume, probe: source.url)
        }
        let total = plan.bytes
        let report = { @Sendable (tally: Tally) in
            progress?(ImportProgress(
                photos: plan.items.count, done: tally.verified.count, failed: tally.failed.count, bytes: total,
                copied: tally.bytes,
            ))
        }
        @Sendable func indexFolders(_ folders: Set<String>) {
            guard !folders.isEmpty else { return }
            run.index { await self.index(folders, plan: plan) }
        }

        let cancelled = Cancellation()
        let quitting = Cancellation()
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (key, indices) in byVolume {
                        guard let io = readers[key] else { continue }
                        let queue = ImportQueue(indices)
                        for _ in 0 ..< Self.perVolume {
                            group.addTask {
                                while !cancelled.isSet, let number = queue.next() {
                                    let result = await self.copy(
                                        number, of: plan, logged: logged, io: io, copier: copier, log: log,
                                        locator: locator,
                                    )
                                    if quitting.isSet {
                                        throw ForcedQuit()
                                    }
                                    let folders = try self.record(result, number, plan: plan, run: run, log: log)
                                    report(run.counts)
                                    if let folders {
                                        indexFolders(folders)
                                    }
                                    if case let .afterPhotos(count) = self.interruption.withLock({ $0 }),
                                       run.counts.verified.count + run.counts.failed.count >= count {
                                        quitting.set()
                                        throw ForcedQuit()
                                    }
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                cancelled.set()
            }
        } catch is ForcedQuit {
            quitting.set()
            await run.indexed()
            throw ForcedQuit()
        }
        indexFolders(run.tally.withLock { state in
            defer { state.waitingToIndex = [] }
            return state.waitingToIndex
        })
        await run.indexed()
        let counts = run.counts
        let state: ImportJournal.State = cancelled.isSet && counts.verified.count + counts.failed.count
            < plan.items.count ? .stopped : .finished
        try log.state(state)
        return outcome(plan, state: state, tally: counts, elapsed: ContinuousClock.now - started)
    }

    /// What became of one photo.
    private enum Result: Sendable {
        case placed(files: Int, backups: Int, bytes: Int64, sidecars: Int, sidecarFailed: String?)
        case failed(String)
        /// Cancelled before it was placed: nothing of it is at the targets.
        case stopped
        case forcedQuit
    }

    /// Copies photo `index` of `plan` to its targets, as the type describes; keeps what's verified and
    /// in place from a run a forced quit cut short.
    private func copy(
        _ index: Int, of plan: ImportPlan, logged: ImportJournal.Progress, io: VolumeIO, copier: ImportCopier,
        log: ImportJournal.Log, locator: SidecarLocator,
    ) async -> Result {
        let item = plan.items[index]
        var staged: [ImportCopier.Staged] = []
        do {
            if !logged.placed.contains(index) {
                for (number, copy) in item.copies.enumerated() {
                    let targets = plan.targets(of: copy)
                    let missing = try await missingTargets(
                        copy, targets: targets, logged: logged.verified[index]?[number] ?? [:],
                    )
                    guard !missing.isEmpty else { continue }
                    try await staged.append(copier.write(copy, to: missing.map { targets[$0] }, io: io))
                }
                try await copier.flush()
                for written in staged {
                    try await copier.verify(written)
                    guard let number = item.copies.firstIndex(of: written.copy) else { continue }
                    let targets = plan.targets(of: written.copy)
                    for target in written.targets {
                        try log.verified(
                            index, copy: number, target: targets.firstIndex(of: target) ?? 0,
                            sha256: written.fingerprint,
                        )
                    }
                }
                if interruption.withLock({ $0 }) == .beforePlacing(index) {
                    throw ForcedQuit()
                }
                try await copier.place(staged)
                try log.placed(index)
            }
        } catch is ForcedQuit {
            return .forcedQuit
        } catch is CancellationError {
            copier.discard(staged.flatMap(\.stagings))
            return .stopped
        } catch {
            copier.discard(staged.flatMap(\.stagings))
            return .failed(ImportCopyError.message(error))
        }
        let sidecars: Int
        var problem: String?
        do {
            sidecars = try await writeSidecars(item, plan: plan, locator: locator)
        } catch {
            sidecars = 0
            problem = LibraryIndexer.path(plan.settings.destination) + "/" + (item.photos.first?.path ?? "")
        }
        let backups = plan.settings.backup == nil ? 0 : item.copies.count
        return .placed(
            files: item.copies.count, backups: backups, bytes: item.bytes, sidecars: sidecars, sidecarFailed: problem,
        )
    }

    /// Logs what became of photo `index` and counts it; returns its folder at the destination once enough
    /// photos are placed for the index to be told.
    private func record(
        _ result: Result, _ index: Int, plan: ImportPlan, run: Run, log: ImportJournal.Log,
    ) throws -> Set<String>? {
        switch result {
        case .forcedQuit:
            throw ForcedQuit()
        case .stopped:
            return nil
        case let .failed(message):
            try log.failed(index, message: message)
            run.tally.withLock { $0.failed[index] = message }
            return nil
        case let .placed(files, backups, bytes, sidecars, problem):
            try log.done(index)
            let folder = plan.items[index].copies.first.map { copy in
                FilePlanner.split(LibraryIndexer.path(plan.settings.destination) + "/" + copy.path).folder
            }
            return run.tally.withLock { tally -> Set<String>? in
                tally.verified.insert(index)
                tally.failed.removeValue(forKey: index)
                tally.files += files
                tally.backups += backups
                tally.bytes += bytes
                tally.sidecars += sidecars
                if let problem {
                    tally.sidecarsFailed.append(problem)
                }
                if let folder {
                    tally.waitingToIndex.insert(folder)
                }
                tally.placedSinceIndexing += 1
                guard tally.placedSinceIndexing >= Self.indexBatch else { return nil }
                tally.placedSinceIndexing = 0
                defer { tally.waitingToIndex = [] }
                return tally.waitingToIndex
            }
        }
    }

    /// The targets `copy` still has to go to: those without a copy in place whose fingerprint the log
    /// recorded. Something else in the way stops the photo.
    private func missingTargets(_ copy: ImportPlan.Copy, targets: [URL], logged: [Int: String]) async throws -> [Int] {
        let fileSystem = destinationFileSystem
        return try await LibraryIndex.offCaller {
            try targets.indices.filter { number in
                let target = targets[number]
                guard fileSystem.exists(target) else { return true }
                if let sha = logged[number],
                   let found = try? ImportCopier.fingerprint(
                       of: target,
                       isDirectory: copy.isDirectory,
                       fileSystem: fileSystem,
                   ),
                   ImportJournal.hex(found) == sha {
                    return false
                }
                throw ImportCopyError(path: copy.source, message: "\(target.path) is already there")
            }
        }
    }

    // MARK: - Sidecars

    /// Writes the choices made while browsing and the metadata preset in the `.redlamp` of each of the
    /// photo's files at the destination, keeping what a `.redlamp` copied with it holds; and, for a
    /// photo given a new name, the name it had. Returns how many were written.
    private func writeSidecars(_ item: ImportPlan.Item, plan: ImportPlan, locator: SidecarLocator) async throws -> Int {
        let preset = plan.settings.metadata
        let renamed = item.photos.contains { $0.name != $0.sourceName }
        guard !item.choices.given.isEmpty || !preset.isEmpty || renamed else { return 0 }
        let destination = LibraryIndexer.path(plan.settings.destination)
        let store = SidecarStore(locator: locator)
        return try await LibraryIndex.offCaller {
            var written = 0
            for copy in item.photos {
                let image = URL(fileURLWithPath: destination + "/" + copy.path, isDirectory: false)
                let existing = store.load(for: image)
                var sidecar = existing ?? Sidecar(recipe: EditRecipe())
                var metadata = sidecar.metadata ?? PhotoMetadata()
                let own = existing?.metadata == nil
                    ? (item.choices.rating, item.choices.flag, item.choices.label)
                    : (metadata.rating, metadata.flag, metadata.label)
                let given = item.choices.given
                metadata.rating = given.contains(.rating) ? item.choices.rating : preset.rating ?? own.0
                metadata.flag = given.contains(.flag) ? item.choices.flag : own.1
                metadata.label = given.contains(.label) ? item.choices.label : preset.label ?? own.2
                if !preset.keywords.isEmpty {
                    metadata.keywords = KeywordPath.texts((metadata.keywords ?? item.keywords) + preset.keywords)
                }
                if copy.name != copy.sourceName, metadata.originalName == nil {
                    metadata.originalName = copy.sourceName
                }
                sidecar.metadata = metadata.isEmpty ? nil : metadata
                sidecar.modified = Date()
                try store.save(sidecar, for: image)
                written += 1
            }
            return written
        }
    }

    /// The locator that places sidecars as the library's roots keep them.
    private func locator() async throws -> SidecarLocator {
        guard let index = library.index else { return .besidePhotos }
        let roots = try await index.read { reader in try LibrarySidecars.locatorRoots(reader) }
        return SidecarLocator(folder: library.paths.sidecars, roots: roots)
    }

    // MARK: - The index

    /// Indexes `folders` at the destination, adding the destination to the library first if it isn't
    /// in it, and passes what the indexer reports to the live lists; returns how many photos it added.
    private func index(_ folders: Set<String>, plan: ImportPlan) async -> Int {
        guard let indexer = library.indexer, let index = library.index else { return 0 }
        let destination = LibraryIndexer.path(plan.settings.destination)
        let inLibrary = await (try? index.read { try $0.root(containing: destination) }) != nil
        let events = inLibrary
            ? indexer.update(folders.sorted().map { FolderChange(URL(fileURLWithPath: $0, isDirectory: true)) })
            : indexer.index([plan.settings.destination])
        var inserted = 0
        for await event in events {
            library.live?.receive(event)
            if case let .photosInserted(ids) = event {
                inserted += ids.count
            }
        }
        return inserted
    }

    // MARK: - Outcome

    private func outcome(_ plan: ImportPlan, state: ImportJournal.State, tally: Tally, elapsed: Duration)
        -> ImportOutcome {
        let sources = plan.sources.map { source in
            let indices = plan.items.indices.filter { plan.items[$0].source == source.id }
            let verified = indices.count { tally.verified.contains($0) }
            let failed = indices.count { tally.failed[$0] != nil }
            return ImportOutcome.Source(
                id: source.id, name: source.name, kind: source.kind, photos: indices.count, verified: verified,
                failed: failed + source.unimported,
                isSafeToErase: state == .finished && failed == 0 && source.unimported == 0
                    && verified == indices.count,
            )
        }
        return ImportOutcome(
            id: plan.id, state: state, photos: plan.items.count, verified: tally.verified.count, files: tally.files,
            backups: tally.backups, bytes: tally.bytes,
            failures: tally.failed.sorted { $0.key < $1.key }.map { index, message in
                ImportOutcome.Failure(photo: plan.items[index].photo, message: message)
            },
            sources: sources, sidecars: tally.sidecars, sidecarsFailed: tally.sidecarsFailed.sorted(),
            indexed: tally.indexed, elapsed: elapsed,
        )
    }

    /// Runs `body` after the imports asked for before it.
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
