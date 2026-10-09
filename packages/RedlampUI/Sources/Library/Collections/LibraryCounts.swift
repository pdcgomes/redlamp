import Foundation
import RedlampLibrary

/// The left panel's counts (LIB-23): each Library and Library Health entry's photos and each collection's,
/// as their lists show them, so photos that can't be read count only where a check finds them (LIB-40); and
/// the collection list, with the target collection. They're read off the main thread from the query engine
/// and the index: a list per entry, the index's counts of the collections less their photos that can't be
/// read, and a list per smart collection.
struct LibraryCounts: Sendable, Equatable {
    /// Each entry with photos, by its source; an entry without any isn't offered.
    var entries: [LibrarySource: Int] = [:]
    /// Every set, collection and smart collection, by path.
    var collections: [CollectionPath: CollectionList.Collection] = [:]
    /// The collection Add to Target Collection puts photos in; nil for the quick collection (Marked).
    var target: CollectionPath?
    /// Each collection's and smart collection's photos, by path; sets have none.
    var collectionPhotos: [CollectionPath: Int] = [:]
    /// The index's IDs of the previous import's photos it has and can read.
    var previousImport: [Int64] = []
    /// Duplicate candidates no recorded hash confirms yet, which Exact Duplicates lists once they're read whole.
    var unconfirmedDuplicates = 0

    /// The photos `source` holds; nil for a set, and for an entry that isn't offered.
    func count(of source: LibrarySource) -> Int? {
        if case let .collection(path) = source {
            return collections[path].map { $0.kind == .set ? nil : collectionPhotos[path] ?? 0 } ?? nil
        }
        return entries[source]
    }

    /// Whether the panels' rows are the same as `other`'s: the entries offered, and the collection list's places,
    /// kinds and target. Counts aside.
    func hasSameRows(as other: LibraryCounts) -> Bool {
        Set(entries.keys) == Set(other.entries.keys) && target == other.target
            && collections.count == other.collections.count
            && collections.allSatisfy { other.collections[$0.key]?.kind == $0.value.kind }
    }

    /// The sources whose counts differ from `other`'s.
    func changed(from other: LibraryCounts) -> Set<LibrarySource> {
        var changed = Set<LibrarySource>()
        for source in Set(entries.keys).union(other.entries.keys) where entries[source] != other.entries[source] {
            changed.insert(source)
        }
        for path in Set(collectionPhotos.keys).union(other.collectionPhotos.keys)
            where collectionPhotos[path] != other.collectionPhotos[path] {
            changed.insert(.collection(path))
        }
        return changed
    }

    /// The counts as the library has them now, Library Health's pairs under `rule`, with `previous`'s photos
    /// for Previous Import.
    static func read(core: LibraryCore, pairs rule: PairRule, previous: PreviousImport?) async throws
        -> LibraryCounts {
        let engine = core.engine
        var counts = LibraryCounts()
        let unreadable = try await Set(engine.list(.query(Self.unreadable)).ids)
        for source in LibrarySource.library + LibrarySource.healthChecks {
            if case .health(.pairs) = source, rule == .keepBoth {
                continue
            }
            guard let photos = source.photoSource(pairs: rule) else { continue }
            let count = try await engine.list(photos).count
            if count > 0 {
                counts.entries[source] = count
            }
        }
        counts.unconfirmedDuplicates = try await engine.healthFindings(.duplicates).unconfirmed
        if let previous {
            let urls = previous.photos.map { URL(fileURLWithPath: $0, isDirectory: false) }
            let found = await Set(LibraryService.indexIDs(of: urls, in: core.index).values)
            // As its list has them: of the photos the index still has, those the store holds and can read.
            let ids = try await engine.list(.photos(found)).ids
            counts.previousImport = ids.sorted()
            if !ids.isEmpty {
                counts.entries[.previousImport] = ids.count
            }
        }
        let list = try await LibraryMetadata(index: core.index, paths: core.paths).collections.list()
        counts.collections = list.collections
        counts.target = list.target
        for collection in list.collections.values where collection.kind == .collection {
            counts.collectionPhotos[collection.path] = collection.photos
        }
        if !unreadable.isEmpty {
            let kept = try await core.index.read { try $0.collectionPaths(ofPhotos: Array(unreadable)) }
            for path in kept.values.joined() where counts.collectionPhotos[path] != nil {
                counts.collectionPhotos[path, default: 0] -= 1
            }
        }
        for collection in list.collections.values where collection.kind == .smart {
            counts.collectionPhotos[collection.path] = try await engine.list(.collection(collection.path)).count
        }
        return counts
    }

    private static let unreadable = LibraryQuery.filter(LibraryQuery.Filter(.unreadable, .equal, [.bool(true)]))
}
