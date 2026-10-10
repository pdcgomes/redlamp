import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Copying photos (LIB-26), with `REDLAMP_COPY_BENCH=1` (which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_COPY_BENCH=1`): `REDLAMP_COPY_BENCH_PHOTOS` photos (1,000 by default), clones of the
/// repository's raws each ending in bytes of its own, half with a sidecar, in a library in
/// `REDLAMP_COPY_BENCH_FOLDER` (the temporary folder by default), copied as one batch into a folder of theirs on
/// that volume, then, with `REDLAMP_COPY_BENCH_OTHER` naming a folder on another volume, into a folder there. Each
/// batch is timed and every copy compared with its original by size, and every 50th byte for byte. Everything it
/// made is removed at the end; nothing goes to the Trash.
struct FileCopyBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_COPY_BENCH"] == "1"))
    func `photos copied within their volume and to another`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["REDLAMP_COPY_BENCH_PHOTOS"].flatMap { Int($0) } ?? 1000
        let base = environment["REDLAMP_COPY_BENCH_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appending(path: "redlamp-copy-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        let other = environment["REDLAMP_COPY_BENCH_OTHER"].map { path in
            URL(fileURLWithPath: path, isDirectory: true)
                .appending(path: "redlamp-copy-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        defer {
            try? FileManager.default.removeItem(at: folder)
            if let other {
                try? FileManager.default.removeItem(at: other)
            }
        }
        let root = folder.appending(path: "Photos", directoryHint: .isDirectory)
        let paths = LibraryPaths(root: folder.appending(path: "Library", directoryHint: .isDirectory))
        let names = try Self.write(count, in: root.appending(path: "Shoot", directoryHint: .isDirectory))
        let bytes = try names.reduce(Int64(0)) { total, name in
            try total + LocalFileSystem().attributes(of: root.appending(path: "Shoot/" + name)).size
        }
        let (index, ids) = try await Self.index(names, root: root, other: other, paths: paths)
        defer { index.closeAndWait() }
        let operations = FileOperations(index: index, paths: paths)

        var lines: [String] = []
        for (label, destination) in [("within its volume", root), ("to another volume", other)] {
            guard let destination else { continue }
            let copies = destination.appending(path: "Copies", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = try await operations.run(operations.planCopy(photos: ids, to: copies))
            let seconds = (clock.now - started) / .seconds(1)
            #expect(outcome.state == .finished && outcome.photos == names.count, "\(label)")
            for (number, name) in names.enumerated() {
                let (original, copy) = (root.appending(path: "Shoot/" + name), copies.appending(path: name))
                let sizes = try (
                    LocalFileSystem().attributes(of: original).size,
                    LocalFileSystem().attributes(of: copy).size,
                )
                #expect(sizes.0 == sizes.1, "\(label): \(name)")
                if number % 50 == 0 {
                    #expect(try Data(contentsOf: original) == Data(contentsOf: copy), "\(label): \(name)")
                }
            }
            lines.append(String(
                format: "%d photos (%.1f GB) copied %@: %.1f s, %.0f MB a second, load %@",
                names.count, Double(bytes) / 1e9, label, seconds, Double(bytes) / 1e6 / max(seconds, 1e-9),
                Self.load(),
            ))
        }
        for line in lines {
            print("COPY-BENCH \(line)")
        }
    }

    /// `count` raws in `folder`, `IMG_0001.ARW` on, each a clone of one of the repository's ending in a box of its
    /// own length, and a sidecar beside every other one; their names.
    private static func write(_ count: Int, in folder: URL) throws -> [String] {
        let manager = FileManager.default
        let raws = try manager.contentsOfDirectory(at: FixtureTests.rawFolder, includingPropertiesForKeys: nil)
            .filter { ["arw", "raf", "cr3", "nef", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!raws.isEmpty, "the raws in tests/fixtures/raw")
        let sources = folder.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources", directoryHint: .isDirectory)
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = raws.map { sources.appending(path: $0.lastPathComponent) }
        for (raw, copy) in zip(raws, local) {
            try manager.copyItem(at: raw, to: copy)
        }
        let store = SidecarStore(locator: .besidePhotos)
        var names: [String] = []
        for number in 0 ..< count {
            let source = local[number % local.count]
            let name = String(format: "IMG_%04d.", number + 1) + source.pathExtension
            let photo = folder.appending(path: name)
            try manager.copyItem(at: source, to: photo)
            let handle = try FileHandle(forWritingTo: photo)
            try handle.seekToEnd()
            let length = 16 + number
            var box = Data([
                UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
            ])
            box.append(contentsOf: Array("free".utf8))
            box.append(Data(count: length - 8))
            try handle.write(contentsOf: box)
            try handle.close()
            if number % 2 == 0 {
                try store.save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3)), for: photo)
            }
            names.append(name)
        }
        return names
    }

    /// An index of the photos in `root`'s Shoot, with `other` a root of its own on another volume; and the photos'
    /// IDs in `names`' order.
    private static func index(_ names: [String], root: URL, other: URL?, paths: LibraryPaths) async throws
        -> (LibraryIndex, [Int64]) {
        if let other {
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        }
        let index = try await LibraryIndex.open(at: paths.index)
        let (rootPath, otherPath) = (LibraryIndexer.path(root), other.map(LibraryIndexer.path))
        let entries = try Dictionary(
            LocalFileSystem().contentsOfDirectory(at: root.appending(path: "Shoot")).map { ($0.name, $0) },
        ) { first, _ in first }
        let ids = try await index.write { writer -> [Int64] in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "COPY-BENCH", name: "Bench", kind: .ssd))
            _ = try writer.upsertRoot(RootRecord(volume: volume, path: rootPath))
            if let otherPath {
                let otherVolume = try writer.upsertVolume(VolumeRecord(
                    uuid: "COPY-BENCH-OTHER",
                    name: "Other",
                    kind: .ssd,
                ))
                _ = try writer.upsertRoot(RootRecord(volume: otherVolume, path: otherPath))
            }
            guard let folder = try writer.folderID(forPath: rootPath + "/Shoot") else { return [] }
            let records = names.enumerated().compactMap { number, name -> PhotoRecord? in
                guard let entry = entries[name] else { return nil }
                return PhotoRecord(
                    folder: folder, name: name, size: entry.size, modified: entry.modified,
                    fileID: entry.fileIdentifier,
                    captured: Date(timeIntervalSince1970: 1_709_294_400 + Double(number)), indexed: 1,
                )
            }
            return try writer.upsertPhotos(records)
        }
        return (index, ids)
    }

    private static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.0f", loads[0]) : "unknown"
    }
}
