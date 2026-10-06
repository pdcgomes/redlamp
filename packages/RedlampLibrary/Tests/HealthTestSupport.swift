import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import RedlampLibrary

/// Real image files for Library Health's tests (LIB-40): noise, so they don't compress below the head
/// the indexer reads when they're meant to be longer.
enum HealthImages {
    static func data(_ type: UTType, width: Int = 64, height: Int = 48, seed: UInt64 = 1) -> Data {
        var random = SeededRandom(seed: seed)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 {
            pixels[index] = UInt8(truncatingIfNeeded: random.next())
        }
        let image = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            )!.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A JPEG longer than the head the indexer reads, so its end takes a read of its own.
    static var longJPEG: Data {
        data(.jpeg, width: 512, height: 512, seed: 7)
    }

    /// The first bytes of a TIFF-based raw, which hold its directories: what the indexer reads of it.
    static var rawHead: Data {
        get throws {
            let raw = try #require(FixtureTests.sources.first { $0.url.pathExtension.lowercased() == "arw" })
            return try LocalFileSystem().read(raw.url, range: 0 ..< 300_000)
        }
    }
}

/// Another file system whose reads of some files fail with `error`, as a damaged disk's do.
final class FailingReadFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let failing: Mutex<Set<String>>
    private let error: POSIXErrorCode

    init(_ base: any LibraryFileSystem = LocalFileSystem(), failing: Set<URL>, error: POSIXErrorCode = .EIO) {
        self.base = base
        self.failing = Mutex(Set(failing.map(LibraryIndexer.path)))
        self.error = error
    }

    func heal(_ url: URL) {
        _ = failing.withLock { $0.remove(LibraryIndexer.path(url)) }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        if failing.withLock({ $0.contains(LibraryIndexer.path(url)) }) {
            throw POSIXError(error)
        }
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}

/// A folder of photos the test writes, with an index of its own and the library's folder beside it,
/// and a simulated volume over it whose Trash is a folder of its own.
final class HealthSandbox: @unchecked Sendable {
    let folder: TemporaryFolder
    let root: URL
    let paths: LibraryPaths
    private(set) var index: LibraryIndex
    let volume = SimulatedFileSystem(profile: .ssd)
    let trash: URL

    /// When the files written were last modified: long enough ago that none is taken for one being
    /// written.
    static let written = Date(timeIntervalSince1970: 1_759_000_000)

    private init(folder: TemporaryFolder, root: URL, paths: LibraryPaths, index: LibraryIndex) {
        self.folder = folder
        self.root = root
        self.paths = paths
        self.index = index
        trash = folder.url.appending(path: "Trash", directoryHint: .isDirectory)
        volume.useTrash(trash)
    }

    /// `files` written below the root, by path.
    static func make(_ files: [String: Data]) async throws -> HealthSandbox {
        let folder = try TemporaryFolder()
        let root = folder.url.appending(path: "Photos", directoryHint: .isDirectory)
        let paths = LibraryPaths(root: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sandbox = try await HealthSandbox(
            folder: folder, root: root, paths: paths, index: LibraryIndex.open(at: paths.index, readers: 2),
        )
        try sandbox.write(files)
        return sandbox
    }

    /// Writes `files`, each modified at `modified`.
    func write(_ files: [String: Data], modified: Date = HealthSandbox.written) throws {
        for (path, data) in files {
            let url = url(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    /// Saves a `.redlamp` sidecar beside the photo at `relative` holding `metadata`.
    func sidecar(_ relative: String, _ metadata: PhotoMetadata) throws {
        try SidecarStore().save(
            Sidecar(recipe: EditRecipe(), metadata: metadata, modified: Self.written), for: url(relative),
        )
    }

    /// The file operations through the simulated volume, and Library Health over them; `live` keeps
    /// lists.
    func library(live: LibraryLive? = nil) -> LibraryHealth {
        LibraryHealth(operations: FileOperations(index: index, paths: paths, fileSystem: volume, live: live))
    }

    /// The index thrown away and made again from the photos and their sidecars.
    func rebuild() async throws {
        await index.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: paths.index.path + suffix)
        }
        index = try await LibraryIndex.open(at: paths.index, readers: 2)
        await index()
    }

    /// The files below the root, but hidden ones, by path below it.
    func files() -> Set<String> {
        Set((FileManager.default.subpaths(atPath: root.path) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return !path.split(separator: "/").contains { $0.hasPrefix(".") }
                && FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        })
    }

    /// The paths below the root of `ids`, as the index has them.
    func paths(_ ids: [Int64]) async throws -> [String] {
        let rows = try await rows()
        let byID = Dictionary(rows.map { ($0.value.id, $0.key) }) { first, _ in first }
        return ids.compactMap { byID[$0] }
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    /// Indexes the root through `fileSystem`, and returns what the run reported.
    @discardableResult
    func index(fileSystem: any LibraryFileSystem = LocalFileSystem()) async -> IndexerRun {
        let indexer = LibraryIndexer(index: index, fileSystem: fileSystem, configuration: .testing())
        return await IndexerRun.collect(indexer.index([root]))
    }

    /// Each photo's row by its path below the root.
    func rows() async throws -> [String: PhotoRecord] {
        let rootPath = LibraryIndexer.path(root)
        return try await index.read { reader in
            var rows: [String: PhotoRecord] = [:]
            guard let top = try reader.folder(path: rootPath) else { return [:] }
            let folders = try Dictionary(uniqueKeysWithValues: reader.folders(inSubtreeOf: top.id)
                .map { ($0.id, $0.path) })
            for photo in try reader.photos(inSubtreeOf: top.id) {
                let path = (folders[photo.folder] ?? "") + "/" + photo.name
                rows[String(path.dropFirst(rootPath.count + 1))] = photo
            }
            return rows
        }
    }

    /// Each photo's health that stands, by its path below the root.
    func health() async throws -> [String: PhotoHealth] {
        let rows = try await rows()
        let health = try await index.read { try $0.photoHealth(rows.values.map(\.id)) }
        return rows.compactMapValues { health[$0.id] }
    }

    func remove() {
        index.closeAndWait()
    }
}
