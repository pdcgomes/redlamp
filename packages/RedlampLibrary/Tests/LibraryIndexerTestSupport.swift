import Foundation
import Synchronization
@testable import RedlampLibrary

/// Counts what's asked of the file system beneath it: listings by folder, and reads by file.
final class CountingFileSystem: LibraryFileSystem {
    struct Counts {
        var listings: [String: Int] = [:]
        var attributes = 0
        var reads: [String: Int] = [:]
        /// Reads of a file's first `PhotoMetadataReader.headLength` bytes.
        var heads = 0

        var listed: Int {
            listings.values.reduce(0, +)
        }

        var read: Int {
            reads.values.reduce(0, +)
        }
    }

    let base: any LibraryFileSystem
    private let state = Mutex(Counts())

    init(_ base: any LibraryFileSystem = LocalFileSystem()) {
        self.base = base
    }

    var counts: Counts {
        state.withLock { $0 }
    }

    func reset() {
        state.withLock { $0 = Counts() }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        state.withLock { $0.listings[url.path, default: 0] += 1 }
        return try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        state.withLock { $0.attributes += 1 }
        return try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        state.withLock { counts in
            counts.reads[url.path, default: 0] += 1
            if range == 0 ..< PhotoMetadataReader.headLength {
                counts.heads += 1
            }
        }
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}

/// A file system that's another until it's switched: a volume that goes and comes back.
final class SwitchingFileSystem: LibraryFileSystem {
    private let current: Mutex<any LibraryFileSystem>

    init(_ initial: any LibraryFileSystem) {
        current = Mutex(initial)
    }

    func switchTo(_ fileSystem: any LibraryFileSystem) {
        current.withLock { $0 = fileSystem }
    }

    private var base: any LibraryFileSystem {
        current.withLock { $0 }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}

/// A fixture in a folder of its own, and an index for it in another.
struct IndexerSandbox {
    let folder: TemporaryFolder
    let fixture: LibraryFixture
    let manifest: FixtureManifest
    let index: LibraryIndex
    let indexFolder: URL

    var root: URL {
        folder.url
    }

    /// The root's path as the index keeps it.
    var rootPath: String {
        LibraryIndexer.path(folder.url)
    }

    /// `spec`'s fixture, with raws when `raws` (written on the raws' own volume, to clone them).
    static func make(_ spec: LibraryFixture.Spec, raws: Bool = false) async throws -> IndexerSandbox {
        let sources = raws ? FixtureTests.sources : []
        let folder = try raws ? TemporaryFolder(on: FixtureTests.rawFolder) : TemporaryFolder()
        let fixture = LibraryFixture(spec: spec, rawSources: sources)
        let summary = try fixture.write(to: folder.url)
        let indexFolder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-indexer-\(UUID().uuidString)", directoryHint: .isDirectory)
        let index = try await LibraryIndex.open(at: indexFolder.appending(path: "Index.sqlite"), readers: 2)
        return IndexerSandbox(
            folder: folder, fixture: fixture, manifest: summary.manifest, index: index, indexFolder: indexFolder,
        )
    }

    func remove() {
        index.closeAndWait()
        try? FileManager.default.removeItem(at: indexFolder)
    }

    func url(_ photo: FixturePhoto) -> URL {
        folder.url.appending(path: photo.path)
    }

    /// The path the index keeps for a file or folder below the root.
    func path(_ relative: String) -> String {
        rootPath + "/" + relative
    }
}

/// What a run reported, collected.
struct IndexerRun {
    var events: [LibraryIndexerEvent] = []

    var summary: LibraryIndexerSummary? {
        for case let .finished(summary) in events.reversed() {
            return summary
        }
        return nil
    }

    var inserted: [Int64] {
        events.flatMap { event -> [Int64] in
            guard case let .photosInserted(ids) = event else { return [] }
            return ids
        }
    }

    var failures: [String] {
        events.compactMap { event in
            guard case let .failed(path, message) = event else { return nil }
            return "\(path): \(message)"
        }
    }

    static func collect(_ stream: AsyncStream<LibraryIndexerEvent>) async -> IndexerRun {
        var run = IndexerRun()
        for await event in stream {
            run.events.append(event)
        }
        return run
    }
}

extension LibraryIndexer.Configuration {
    /// Small batches, written quickly.
    static func testing(batchSize: Int = 100) -> Self {
        Self(batchSize: batchSize, batchInterval: .milliseconds(100))
    }
}

extension LibraryIndexer {
    /// Waits for the runs asked for before this one to finish.
    func settle() async {
        for await _ in update([]) {}
    }
}
