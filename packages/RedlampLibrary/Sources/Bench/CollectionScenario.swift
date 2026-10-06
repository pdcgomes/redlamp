import Foundation
import RedlampDocument
import Synchronization

public extension BenchScenarios {
    /// Adds the collections scenario (LIB-23) after the others: `photos` of the fixture's photos in a
    /// collection.
    static func registerCollections(photos: Int = CollectionScenario.defaultPhotos) {
        register(CollectionScenario(photos: photos))
    }
}

/// Collections at a professional's scale (LIB-23), on the fixture itself: it writes the fixture's
/// sidecars and puts them back as they were, so run it on a copy (`cp -cR`). The fixture is indexed into
/// a temporary index through the simulated volume; its first `photos` photos are put in a collection, and
/// the set holding it renamed, each one batch (`LibraryCollections`) rewriting every photo's sidecar, with
/// the journal, the index and the sidecars timed apart and every sidecar checked after each; then both
/// are taken back with Undo.
public struct CollectionScenario: BenchScenario {
    public static let defaultPhotos = 10000

    public let name = "collections"
    public let photos: Int

    public init(photos: Int = CollectionScenario.defaultPhotos) {
        self.photos = max(photos, 1)
    }

    static let collection = CollectionPath("Bench/Clients/Selects")!
    static let set = CollectionPath("Bench/Clients")!
    static let renamed = CollectionPath("Bench/Customers")!

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = LibraryPaths(root: folder.appending(path: "Library", directoryHint: .isDirectory))
        let index = try await LibraryIndex.open(at: paths.index)
        defer { index.closeAndWait() }
        let built = await IndexingScenario.timed(
            LibraryIndexer(index: index, fileSystem: context.fileSystem()).index([context.fixture]),
        )
        let ids = try await index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            return Array(ids.prefix(photos))
        }
        let found = try await index.read { try $0.photoPaths(ids) }
        let images = ids.compactMap { found[$0] }.map { URL(fileURLWithPath: $0) }
        let collections = LibraryMetadata(index: index, paths: paths).collections

        let clock = ContinuousClock()
        var started = clock.now
        let added = try await collections.apply(.add(ids, to: Self.collection))
        let adding = clock.now - started
        let afterAdding = try await LibraryIndex.offCaller { Self.wrong(images, holding: Self.collection) }
        started = clock.now
        let renamed = try await collections.apply(.rename(Self.set, to: Self.renamed))
        let renaming = clock.now - started
        let moved = Self.collection.replacingPrefix(Self.set, with: Self.renamed)
        let afterRenaming = try await LibraryIndex.offCaller { Self.wrong(images, holding: moved) }
        let listed = try await collections.list()[moved]?.photos ?? 0
        started = clock.now
        try await collections.metadata.undo()
        try await collections.metadata.undo()
        let undoing = clock.now - started
        let afterUndo = try await LibraryIndex.offCaller { Self.wrong(images, holding: nil) }

        let size = BenchResult.grouped(ids.count)
        return [
            BenchResult(
                scenario: name, id: "library-collections-add", name: "\(size) photos added to a collection",
                value: adding.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-add-index", name: "Of it, the index and its lists",
                value: added.indexTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-add-sidecars",
                name: "Of it, \(BenchResult.grouped(added.written)) sidecars written",
                value: added.sidecarTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-rename",
                name: "The set holding it renamed, \(BenchResult.grouped(renamed.photos)) photos' sidecars rewritten",
                value: renaming.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-rename-index", name: "Of it, the index and its lists",
                value: renamed.indexTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-rename-sidecars",
                name: "Of it, \(BenchResult.grouped(renamed.written)) sidecars written",
                value: renamed.sidecarTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-undo", name: "Both taken back with Undo",
                value: undoing.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-collections-listed", name: "Photos the list counts in it once renamed",
                value: Double(listed), unit: "photos", budget: .exactly(Double(ids.count), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-collections-wrong",
                name: "Sidecars not as each step leaves them, and failures",
                value: Double(afterAdding + afterRenaming + afterUndo + built.failures), unit: "photos",
                budget: .exactly(0, "photos"),
            ),
        ]
    }

    /// How many of the images' sidecars don't name `collection` alone, or, with none, name a collection.
    private static func wrong(_ images: [URL], holding collection: CollectionPath?) -> Int {
        let wrong = SidecarCounter()
        let store = SidecarStore()
        let expected = collection.map { [$0.text] } ?? []
        DispatchQueue.concurrentPerform(iterations: images.count) { number in
            if (store.load(for: images[number])?.metadata?.collections ?? []) != expected {
                _ = wrong.add()
            }
        }
        return wrong.value
    }
}
