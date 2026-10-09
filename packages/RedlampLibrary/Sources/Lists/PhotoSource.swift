import Foundation
import RedlampDocument

/// Where a list's photos come from (LIB-10): a folder, alone or with every folder below it, a
/// search, a collection, All Photographs or Rejected, or photos named by their IDs.
public enum PhotoSource: Sendable, Hashable {
    /// The photos in a folder, and with `includingSubfolders` those in every folder below it.
    case folder(URL, includingSubfolders: Bool)
    /// The photos a query finds.
    case query(LibraryQuery)
    /// The photos put in a collection, or those its query finds for a smart collection, as the
    /// library's definitions keep it (LIB-23); for a set, those of every collection inside it.
    case collection(CollectionPath)
    /// Every photo in the library.
    case allPhotographs
    /// The photos flagged as rejects.
    case rejected
    /// The photos a check of Library Health found (LIB-40), each with its reason and proposal in
    /// `QueryEngine.healthFindings`.
    case health(HealthCheck)
    /// The photos whose findings the user kept anyway, any check's (LIB-40).
    case keptAnyway
    /// The photos of these IDs the library has: an import's (LIB-23, LIB-27), whose folders may hold others.
    case photos(Set<Int64>)

    /// Whether it holds photos that can't be read, which other sources leave out (LIB-40). A collection
    /// leaves them out itself, keeping those a smart collection's query finds.
    var findsUnreadable: Bool {
        switch self {
        case let .query(query): query.findsUnreadable
        case let .health(check): check.findsUnreadable
        case .keptAnyway, .collection: true
        default: false
        }
    }
}

extension QueryEngine {
    /// The rows of `store` that `source` holds: without the photos that can't be read, unless
    /// `unreadable` asks for them or the source is of them (LIB-40).
    func rows(
        of source: PhotoSource, in store: ColumnStore, vocabulary: QueryVocabulary, generation: Int,
        unreadable: Bool = false,
    ) async throws -> RowBits {
        let rows = try await allRows(
            of: source, in: store, vocabulary: vocabulary, generation: generation, unreadable: unreadable,
        )
        return unreadable || source.findsUnreadable ? rows : store.readable(rows)
    }

    private func allRows(
        of source: PhotoSource, in store: ColumnStore, vocabulary: QueryVocabulary, generation: Int,
        unreadable: Bool,
    ) async throws -> RowBits {
        switch source {
        case .allPhotographs:
            return store.live
        case .rejected:
            let rejects = LibraryQuery.filter(LibraryQuery.Filter(.flag, .equal, [.flag(.reject)]))
            return try await matches(for: rejects, in: store, vocabulary: vocabulary, generation: generation)
        case let .query(query):
            return try await matches(for: query.searchable, in: store, vocabulary: vocabulary, generation: generation)
        case let .collection(path):
            let plan = QueryPlan(
                collection: path, store: store, vocabulary: vocabulary, today: today, unreadable: unreadable,
            )
            return try await rows(for: plan, in: store, vocabulary: vocabulary, generation: generation)
        case let .health(check):
            return try await store.rows(withIDs: healthFindings(check, in: store, generation: generation).photos)
        case .keptAnyway:
            return try await store.rows(withIDs: keptAnyway(generation: generation))
        case let .photos(ids):
            return store.rows(withIDs: Array(ids))
        case let .folder(url, includingSubfolders):
            let path = LibraryIndexer.path(url)
            let below = path == "/" ? "/" : path + "/"
            let folders = vocabulary.names.folders.compactMap { id, folder in
                folder == path || includingSubfolders && folder.hasPrefix(below) ? Int32(clamping: id) : nil
            }
            guard !folders.isEmpty else { return RowBits(rows: store.rowCount) }
            return store.rows(matching: .leaf(.folders(folders)), sets: [:])
        }
    }
}
