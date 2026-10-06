import Foundation
import RedlampDocument

/// Where a list's photos come from (LIB-10): a folder, alone or with every folder below it, a
/// search, a collection, All Photographs or Rejected.
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
}

extension QueryEngine {
    /// The rows of `store` that `source` holds.
    func rows(
        of source: PhotoSource, in store: ColumnStore, vocabulary: QueryVocabulary, generation: Int,
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
            let plan = QueryPlan(collection: path, store: store, vocabulary: vocabulary, today: today)
            return try await rows(for: plan, in: store, generation: generation)
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
