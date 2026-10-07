import Foundation

/// Photos found by their file's name (LIB-19), as the command palette lists them: the first in the
/// name order, and how many there are.
public struct PhotosNamed: Sendable, Hashable {
    /// A photo found: its ID, and its path, its folder's, a slash and its name.
    public struct Photo: Sendable, Hashable {
        public let id: Int64
        public let path: String

        public init(id: Int64, path: String) {
            self.id = id
            self.path = path
        }
    }

    public let text: String
    public let photos: [Photo]
    /// The photos whose name holds the text.
    public let count: Int

    public init(text: String, photos: [Photo], count: Int) {
        self.text = text
        self.photos = photos
        self.count = count
    }
}

public extension QueryEngine {
    /// The photos whose file name holds `text`, as the text index finds them (three characters or
    /// more, as `name:` does): the first `limit` in the name order, without those that can't be read,
    /// and how many there are. Unlike `search`, it cancels nothing. Nothing runs on the caller's thread.
    func photos(named text: String, limit: Int = 5) async throws -> PhotosNamed {
        let text = text.trimmingCharacters(in: .whitespaces)
        let none = PhotosNamed(text: text, photos: [], count: 0)
        guard limit > 0, QueryText.isSearchable(text) else { return none }
        if await loadedSnapshot() == nil {
            try await load()
        }
        guard let (store, vocabulary, generation) = snapshot() else { return none }
        let query = LibraryQuery.filter(LibraryQuery.Filter(.name, .equal, [.text(text)]))
        let found = try await store.readable(matches(
            for: query, in: store, vocabulary: vocabulary, generation: generation,
        ))
        try Task.checkCancellation()
        let order = store.order(.name)
        var ids = ContiguousArray<Int64>()
        _ = store.collect(found, in: order, ascending: true, from: 0, limit: limit, places: order.count, into: &ids)
        let paths = try await source.photoPaths(of: Array(ids))
        return PhotosNamed(
            text: text, photos: ids.compactMap { id in paths[id].map { PhotosNamed.Photo(id: id, path: $0) } },
            count: found.count,
        )
    }

    /// Makes the names completion and the palette rank ready ahead of the first key (LIB-18, LIB-19):
    /// the small tables' and the store's, off the caller's thread, once the store is loaded.
    func prepareNames() {
        Task.detached(priority: .utility) { [self] in
            guard let (store, vocabulary, _) = await loadedSnapshot() else { return }
            _ = vocabulary.rankedNames()
            _ = storeNames(of: store)
        }
    }
}
