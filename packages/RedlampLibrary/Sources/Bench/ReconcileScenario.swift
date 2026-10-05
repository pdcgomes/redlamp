import Foundation

/// Changes a copy of the fixture while its index is closed, in 50 of its folders: in each, a photo
/// renamed, one added and one deleted, as in the Finder. Then opens the index again and reconciles it
/// through the simulated volume: how long that takes, that every change is in the index, that each
/// renamed photo kept its row, and that only the added photos are read. The copy is a clone beside
/// the fixture, removed afterwards.
public struct ReconcileScenario: BenchScenario {
    public let name = "reconcile"
    static let folders = 50

    /// The changes made in one folder, by name: photos without sidecars, so a rename is only a rename.
    struct Changes {
        /// Below the fixture's root.
        let folder: String
        let renamed: String
        let deleted: String
        /// Copied to `added`.
        let copied: String

        var renamedTo: String {
            "Renamed " + renamed
        }

        var added: String {
            "Added " + copied
        }
    }

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let copy = context.fixture.deletingLastPathComponent().appending(
            path: "\(context.fixture.lastPathComponent) reconcile \(UUID().uuidString.prefix(8))",
            directoryHint: .isDirectory,
        )
        try IndexingScenario.clone(context.fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Index.sqlite")
        try await IndexingScenario.build([copy], at: url)

        let root = LibraryIndexer.path(copy)
        let planned = try Self.plan(context.manifest, in: copy)
        var index = try await LibraryIndex.open(at: url)
        let ids = try await index.read { reader in
            try planned.map { try reader.photo(path: root + "/" + $0.folder + "/" + $0.renamed)?.id }
        }
        await index.close()
        let files = FileManager.default
        for changes in planned {
            let folder = copy.appending(path: changes.folder, directoryHint: .isDirectory)
            try files.moveItem(
                at: folder.appending(path: changes.renamed),
                to: folder.appending(path: changes.renamedTo),
            )
            try files.removeItem(at: folder.appending(path: changes.deleted))
            try IndexingScenario.clone(
                folder.appending(path: changes.copied),
                to: folder.appending(path: changes.added),
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        index = try await LibraryIndex.open(at: url)
        let indexer = LibraryIndexer(index: index, fileSystem: context.fileSystem())
        let run = await IndexingScenario.timed(indexer.index([copy]))
        let elapsed = clock.now - started
        let (renamed, added, deleted, photos) = try await index.read { reader in
            var counts = (renamed: 0, added: 0, deleted: 0)
            for (changes, id) in zip(planned, ids) {
                let folder = root + "/" + changes.folder + "/"
                if let id, try reader.photo(path: folder + changes.renamedTo)?.id == id,
                   try reader.photo(path: folder + changes.renamed) == nil {
                    counts.renamed += 1
                }
                counts.added += try reader.photo(path: folder + changes.added) == nil ? 0 : 1
                counts.deleted += try reader.photo(path: folder + changes.deleted) == nil ? 1 : 0
            }
            return try (counts.renamed, counts.added, counts.deleted, reader.photoCount())
        }
        await index.close()
        let count = Double(planned.count)
        func check(_ id: String, _ label: String, _ value: Int, _ target: Double, _ unit: String) -> BenchResult {
            BenchResult(
                scenario: name, id: "library-reconcile-\(id)", name: label, value: Double(value), unit: unit,
                budget: .exactly(target, unit),
            )
        }
        return [
            BenchResult(
                scenario: name, id: "library-reconcile",
                name: "Reconciled \(BenchResult.grouped(3 * planned.count)) changes in \(planned.count) folders",
                value: elapsed.seconds * 1000, unit: "ms",
            ),
            check("renamed", "Renamed photos that kept their rows", renamed, count, "photos"),
            check("added", "Added photos in the index", added, count, "photos"),
            check("deleted", "Deleted photos gone from the index", deleted, count, "photos"),
            check("read", "Photos read", run.summary.headsRead, count, "photos"),
            check("photos", "Photos in the index", photos, Double(context.manifest.totals.photos), "photos"),
        ]
    }

    /// The changes to make in up to `folders` of the fixture's folders, spread through it: in each, the
    /// first three photos without sidecars or other apps' `.xmp`.
    static func plan(_ manifest: FixtureManifest, in fixture: URL) throws -> [Changes] {
        let candidates = manifest.folders.filter { $0.photos >= 3 }
        let step = max(candidates.count / folders, 1)
        let order = candidates.indices.sorted { ($0 % step, $0) < ($1 % step, $1) }
        let disk = LocalFileSystem()
        var planned: [Changes] = []
        for index in order where planned.count < folders {
            let path = candidates[index].path
            let entries = try disk.contentsOfDirectory(at: fixture.appending(path: path, directoryHint: .isDirectory))
            let names = Set(entries.map { $0.name.lowercased() })
            let plain = entries.filter(FolderWalk.isPhoto).map(\.name).sorted().filter { name in
                let stem = (name as NSString).deletingPathExtension
                return [name + ".redlamp", name + ".xmp", stem + ".xmp"].allSatisfy { !names.contains($0.lowercased()) }
            }
            guard plain.count >= 3 else { continue }
            planned.append(Changes(folder: path, renamed: plain[0], deleted: plain[1], copied: plain[2]))
        }
        return planned
    }
}
