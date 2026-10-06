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

/// A folder of photos that exist only in its listing, on a volume of their own: each reads as its
/// name, in which ImageIO finds nothing. A run over as many photos as a test needs writes no files.
final class ListedPhotos: LibraryFileSystem {
    let folder: String
    let names: [String]
    private static let modified = Date(timeIntervalSince1970: 1_700_000_000)

    init(in folder: URL, count: Int) {
        self.folder = LibraryIndexer.path(folder)
        names = (1 ... count).map { "IMG_\($0).JPG" }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        guard LibraryIndexer.path(url) == folder else { throw CocoaError(.fileReadNoSuchFile) }
        return names.map { FileEntry(name: $0, size: Int64($0.utf8.count), modified: Self.modified) }
    }

    func attributes(of url: URL) throws -> FileEntry {
        let path = LibraryIndexer.path(url)
        if path == folder {
            return FileEntry(name: url.lastPathComponent, isDirectory: true, modified: Self.modified)
        }
        guard (path as NSString).deletingLastPathComponent == folder else { throw CocoaError(.fileReadNoSuchFile) }
        return FileEntry(
            name: url.lastPathComponent,
            size: Int64(url.lastPathComponent.utf8.count),
            modified: Self.modified,
        )
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        let bytes = try Data(attributes(of: url).name.utf8)
        return bytes[min(range.lowerBound, bytes.count) ..< min(range.upperBound, bytes.count)]
    }

    func volume(of _: URL) throws -> VolumeInfo {
        VolumeInfo(uuid: "LISTED-PHOTOS", name: "Listed", isLocal: true, isInternal: true)
    }
}

/// Folders of photos that exist only in their listings, like `ListedPhotos`, under one root that
/// holds only the folders; it keeps what was asked of it, in order.
final class ListedFolders: LibraryFileSystem {
    enum Operation: Equatable {
        case listing(String)
        case read(String)
    }

    let root: String
    let folders: [String]
    private let photos: Int
    private let asked = Mutex<[Operation]>([])
    private static let modified = Date(timeIntervalSince1970: 1_700_000_000)

    init(in root: URL, folders: Int, photos: Int) {
        self.root = LibraryIndexer.path(root)
        self.folders = (1 ... folders).map { "Folder \($0)" }
        self.photos = photos
    }

    var operations: [Operation] {
        asked.withLock { $0 }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        let path = LibraryIndexer.path(url)
        asked.withLock { $0.append(.listing(path)) }
        if path == root {
            return folders.map { FileEntry(name: $0, isDirectory: true, modified: Self.modified) }
        }
        guard (path as NSString).deletingLastPathComponent == root,
              folders.contains(url.lastPathComponent) else { throw CocoaError(.fileReadNoSuchFile) }
        return (1 ... photos).map { photo in
            let name = "IMG_\(photo).JPG"
            return FileEntry(name: name, size: Int64(name.utf8.count), modified: Self.modified)
        }
    }

    func attributes(of url: URL) throws -> FileEntry {
        let path = LibraryIndexer.path(url)
        let parent = (path as NSString).deletingLastPathComponent
        if path == root || parent == root {
            return FileEntry(name: url.lastPathComponent, isDirectory: true, modified: Self.modified)
        }
        guard (parent as NSString).deletingLastPathComponent == root else { throw CocoaError(.fileReadNoSuchFile) }
        return FileEntry(
            name: url.lastPathComponent,
            size: Int64(url.lastPathComponent.utf8.count),
            modified: Self.modified,
        )
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        asked.withLock { $0.append(.read(LibraryIndexer.path(url))) }
        let bytes = try Data(attributes(of: url).name.utf8)
        return bytes[min(range.lowerBound, bytes.count) ..< min(range.upperBound, bytes.count)]
    }

    func volume(of _: URL) throws -> VolumeInfo {
        VolumeInfo(uuid: "LISTED-FOLDERS", name: "Listed", isLocal: true, isInternal: true)
    }
}

/// Another file system whose first read waits until it's let go: a run caught with a photo half read.
final class FirstReadHoldingFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let holding = Mutex(true)
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(_ base: any LibraryFileSystem) {
        self.base = base
    }

    /// Returns once the first read is waiting.
    func held() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [started] in
                started.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        released.signal()
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        if holding.withLock({ first in
            defer { first = false }
            return first
        }) {
            started.signal()
            released.wait()
        }
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}

/// Another file system that keeps the folders it lists, in the order it's asked to.
final class ListingOrderFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let order = Mutex<[String]>([])

    init(_ base: any LibraryFileSystem = LocalFileSystem()) {
        self.base = base
    }

    var listed: [String] {
        order.withLock { $0 }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        order.withLock { $0.append(LibraryIndexer.path(url)) }
        return try base.contentsOfDirectory(at: url)
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

/// Another file system whose listings of some folders take `delay` longer.
final class SlowListingFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let slow: Set<String>
    private let delay: Duration

    init(_ base: any LibraryFileSystem = LocalFileSystem(), slow: Set<String>, delay: Duration) {
        self.base = base
        self.slow = slow
        self.delay = delay
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        if slow.contains(LibraryIndexer.path(url)) {
            Thread.sleep(forTimeInterval: delay.seconds)
        }
        return try base.contentsOfDirectory(at: url)
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

    /// The photos each written batch inserted, a list a batch.
    var insertions: [[Int64]] {
        events.compactMap { event in
            guard case let .photosInserted(ids) = event else { return nil }
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
