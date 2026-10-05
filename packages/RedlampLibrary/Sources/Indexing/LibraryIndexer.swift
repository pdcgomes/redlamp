import Foundation
import RedlampDocument
import Synchronization

/// Fills the index from the photos' folders and keeps it in step with them (LIB-07): walks the
/// folders through each volume's readers, skips every folder whose signature is the one it was
/// indexed at, and for each new or changed photo reads its first `PhotoMetadataReader.headLength`
/// bytes once, for its content key and metadata, then its sidecars, and writes the rows in batches.
///
/// The folders asked for come first (`prioritise`, the folders on screen), then the newest by
/// modification date; their photos in Finder's order. A run that stops partway leaves every folder
/// it didn't finish to the next, which reads only the photos the index doesn't hold as they are.
/// A photo that vanishes from its folder while one with its file identifier, size and date appears
/// on the same volume was renamed or moved in the Finder: its row moves, keeping its ID. Runs go
/// one at a time, in the order they're asked for.
///
/// Photos of the folders asked for are read on the scheduler's on-screen lane, the others on its
/// background lane, which waits in Low Power Mode and while the Mac is hot.
public final class LibraryIndexer: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Photos written in one transaction, at most.
        public var batchSize: Int
        /// How long photos read wait for the rest of their batch before they're written anyway.
        public var batchInterval: Duration
        /// The bytes of heads kept for `thumbnails` until their batch is written, at most.
        public var retainedHeadBytes: Int

        public init(
            batchSize: Int = 1000,
            batchInterval: Duration = .milliseconds(500),
            retainedHeadBytes: Int = 64 << 20,
        ) {
            self.batchSize = max(batchSize, 1)
            self.batchInterval = batchInterval
            self.retainedHeadBytes = retainedHeadBytes
        }
    }

    /// Called with a photo's URL, its content key and the head read for it once its row is written,
    /// to make its thumbnail (LIB-09). Called on the scheduler's background lane.
    public typealias Thumbnails = @Sendable (_ photo: URL, _ key: ContentKey, _ head: Data) -> Void

    /// Every lane as wide as the performance cores; the background lane waits in Low Power Mode and
    /// while the Mac is hot.
    public static let scheduler = WorkScheduler(widths: WorkScheduler.Widths(
        onScreen: CoreCounts.performance, lookAhead: CoreCounts.performance, background: CoreCounts.performance,
    ))

    public let index: LibraryIndex
    public let volumes: VolumeIORegistry
    public let scheduler: WorkScheduler
    public let configuration: Configuration
    let thumbnails: Thumbnails?
    private let state = Mutex(State())

    private struct State {
        var prioritised: Set<String> = []
        var last: Task<Void, Never>?
    }

    public convenience init(
        index: LibraryIndex, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        scheduler: WorkScheduler = LibraryIndexer.scheduler, configuration: Configuration = Configuration(),
        thumbnails: Thumbnails? = nil,
    ) {
        self.init(
            index: index, volumes: VolumeIORegistry(fileSystem: fileSystem), scheduler: scheduler,
            configuration: configuration, thumbnails: thumbnails,
        )
    }

    public init(
        index: LibraryIndex, volumes: VolumeIORegistry, scheduler: WorkScheduler = LibraryIndexer.scheduler,
        configuration: Configuration = Configuration(), thumbnails: Thumbnails? = nil,
    ) {
        self.index = index
        self.volumes = volumes
        self.scheduler = scheduler
        self.configuration = configuration
        self.thumbnails = thumbnails
    }

    public var fileSystem: any LibraryFileSystem {
        volumes.fileSystem
    }

    // MARK: - Runs

    /// Adds `roots` to the library if they aren't in it, and indexes them: every folder below them
    /// is listed, and those that changed since they were indexed are read again. Run at launch it
    /// reconciles the index with the disks. Cancelling the task iterating the events stops the run,
    /// once what it has read is written.
    public func index(_ roots: [URL]) -> AsyncStream<LibraryIndexerEvent> {
        start(.roots(roots.map(Self.path)))
    }

    /// Lists `changes`' folders again, and their subfolders where a change says so, as change
    /// detection names them. A folder the index doesn't have is found from the nearest one above it
    /// that it does.
    public func update(_ changes: [FolderChange]) -> AsyncStream<LibraryIndexerEvent> {
        start(.folders(changes.map { (Self.path($0.url), $0.recursive) }))
    }

    /// The folders to index first, replacing those asked for before: the folders on screen.
    public func prioritise(_ folders: [URL]) {
        let paths = Set(folders.map(Self.path))
        state.withLock { $0.prioritised = paths }
    }

    var prioritised: Set<String> {
        state.withLock { $0.prioritised }
    }

    private func start(_ request: Request) -> AsyncStream<LibraryIndexerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryIndexerEvent.self)
        let task = state.withLock { state -> Task<Void, Never> in
            let previous = state.last
            let task = Task { [self] in
                await previous?.value
                if !Task.isCancelled {
                    await Run(indexer: self, events: continuation).perform(request)
                }
                continuation.finish()
            }
            state.last = task
            return task
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The path the index keeps for `url`: standardised, without a trailing slash.
    static func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
