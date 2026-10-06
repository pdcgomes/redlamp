import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

public extension BenchScenarios {
    /// Adds the metadata scenario (LIB-22, LIB-15, LIB-24) after the others: `photos` of the fixture's
    /// photos changed.
    static func registerMetadata(photos: Int = MetadataScenario.defaultPhotos) {
        register(MetadataScenario(photos: photos))
    }
}

/// Metadata changed on many photos (LIB-22, LIB-24), on the fixture itself: it writes the fixture's
/// sidecars and puts them back as they were, so run it on a copy (`cp -cR`). The fixture is indexed into
/// a temporary index through the simulated volume, then a keyword is put in the sidecars of its first
/// `photos` photos behind the index's back, as another Mac's changes arrive, and the fixture is indexed
/// again: how many photos are read again for a change only their `.redlamp` has, and how long it takes.
/// The keyword is then taken off, each sidecar left as it was.
public struct MetadataScenario: BenchScenario {
    public static let defaultPhotos = 10000

    public let name = "metadata"
    public let photos: Int

    public init(photos: Int = MetadataScenario.defaultPhotos) {
        self.photos = max(photos, 1)
    }

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
        return try await sidecarOnly(context, index: index, ids: ids, failures: built.failures)
    }

    // MARK: - A change only the sidecars have

    static let keyword = "Bench/Sidecar only"

    /// The keyword put in `ids`' sidecars behind the index's back and the fixture indexed again; then
    /// the keyword taken off.
    private func sidecarOnly(
        _ context: BenchContext, index: LibraryIndex, ids: [Int64], failures: Int,
    ) async throws -> [BenchResult] {
        let found = try await index.read { try $0.photoPaths(ids) }
        let images = ids.compactMap { found[$0] }.map { URL(fileURLWithPath: $0) }
        let (earlier, unwritten) = try await LibraryIndex.offCaller { Self.addKeyword(to: images) }
        let again = await IndexingScenario.timed(
            LibraryIndexer(index: index, fileSystem: context.fileSystem()).index([context.fixture]),
        )
        let wrong = try await index.read { reader in
            try ids.count { try !reader.keywords(forPhoto: $0).contains(Self.keyword) }
        }
        let left = try await LibraryIndex.offCaller { Self.restore(images, keywords: earlier) }

        let size = BenchResult.grouped(images.count)
        return [
            BenchResult(
                scenario: name, id: "library-metadata-sidecar-only",
                name: "\(size) photos' .redlamp changed elsewhere, the fixture indexed again",
                value: again.elapsed.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-metadata-sidecar-only-reads",
                name: "Photos read again for it", value: Double(again.summary.headsRead), unit: "photos",
            ),
            BenchResult(
                scenario: name, id: "library-metadata-sidecar-only-wrong",
                name: "Photos whose keywords the index missed, sidecars not written or put back, and failures",
                value: Double(wrong + unwritten + left + failures + again.failures), unit: "photos",
                budget: .exactly(0, "photos"),
            ),
        ]
    }

    /// Adds the keyword to each image's sidecar, making one where there's none; returns each one's
    /// keyword list before (nil for none, or no sidecar), by place, and how many couldn't be written.
    private static func addKeyword(to images: [URL]) -> (keywords: [Int: [String]?], failed: Int) {
        let earlier = Mutex<[Int: [String]?]>([:])
        let failed = SidecarCounter()
        SidecarStore().change(images) { number, sidecar in
            var sidecar = sidecar ?? Sidecar(recipe: EditRecipe())
            var metadata = sidecar.metadata ?? PhotoMetadata()
            earlier.withLock { $0[number] = .some(metadata.keywords) }
            metadata.keywords = (metadata.keywords ?? []) + [keyword]
            sidecar.metadata = metadata
            sidecar.modified = Date()
            return .save(sidecar)
        } done: { result in
            if case .failed = result.outcome {
                _ = failed.add()
            }
        }
        return (earlier.withLock { $0 }, failed.value)
    }

    /// Puts each image's keyword list back as `keywords` had it, removing the sidecars left with
    /// nothing in them; returns how many couldn't be.
    private static func restore(_ images: [URL], keywords: [Int: [String]?]) -> Int {
        let failed = SidecarCounter()
        SidecarStore().change(images) { number, sidecar in
            guard var sidecar, var metadata = sidecar.metadata else { return .keep }
            metadata.keywords = keywords[number] ?? nil
            sidecar.metadata = metadata.isEmpty ? nil : metadata
            sidecar.modified = Date()
            return .saveOrRemove(sidecar)
        } done: { result in
            if case .failed = result.outcome {
                _ = failed.add()
            }
        }
        return failed.value
    }
}
