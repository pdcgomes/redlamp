import Foundation
import Synchronization

/// The library an import goes into: its folder (the import journal is kept there), its index (what's
/// in it isn't copied again, and what's copied is added), its store (previews made while browsing go
/// there, by content key), and the indexer and live lists that hear of what arrives. Without an index
/// an import copies, verifies and journals, and recognises only what's already at its destination.
public struct ImportLibrary: Sendable {
    public let paths: LibraryPaths
    public let index: LibraryIndex?
    public let store: PhotoStore?
    public let indexer: LibraryIndexer?
    public let live: LibraryLive?

    public init(
        paths: LibraryPaths, index: LibraryIndex? = nil, store: PhotoStore? = nil, indexer: LibraryIndexer? = nil,
        live: LibraryLive? = nil,
    ) {
        self.paths = paths
        self.index = index
        self.store = store
        self.indexer = indexer
        self.live = live
    }

    /// The library whose index is `index`, at `LibraryPaths.index` in its folder, with its store and an
    /// indexer that makes the thumbnails the store doesn't have.
    public static func around(_ index: LibraryIndex, live: LibraryLive? = nil) -> ImportLibrary {
        let paths = LibraryPaths(root: index.url.deletingLastPathComponent())
        let store = PhotoStore(root: paths.store)
        let indexer = LibraryIndexer(index: index, thumbnails: StoreThumbnailMaker(store: store).thumbnails)
        return ImportLibrary(paths: paths, index: index, store: store, indexer: indexer, live: live)
    }

    /// The content keys of every photo in the index, read in one pass: the index keeps no index of
    /// them, so they're loaded once and looked up in memory.
    func contentKeys() async throws -> ImportKeys {
        guard let index else { return ImportKeys() }
        return try await index.read { reader in
            var halves: [ImportKeys.Key] = []
            try reader.database.cached("SELECT content_key FROM photos WHERE content_key IS NOT NULL")
                .forEachRow { row in
                    if let (high, low) = row.contentKeyHalves(at: 0) {
                        halves.append(ImportKeys.Key(high: high, low: low))
                    }
                }
            return ImportKeys(halves)
        }
    }
}

/// Work taken a piece at a time by several tasks.
final class ImportQueue<Element: Sendable>: Sendable {
    private let items: Mutex<ArraySlice<Element>>

    init(_ items: some Sequence<Element>) {
        self.items = Mutex(ArraySlice(items))
    }

    func next() -> Element? {
        items.withLock { $0.popFirst() }
    }
}

/// Content keys, sorted, for looking up many: 16 bytes a photo.
struct ImportKeys: Sendable {
    struct Key: Sendable, Hashable, Comparable {
        var high: UInt64
        var low: UInt64

        init(high: UInt64, low: UInt64) {
            self.high = high
            self.low = low
        }

        init(_ key: ContentKey) {
            let bytes = Array(key.data)
            high = bytes[0 ..< 8].reduce(0) { $0 << 8 | UInt64($1) }
            low = bytes[8 ..< 16].reduce(0) { $0 << 8 | UInt64($1) }
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.high, lhs.low) < (rhs.high, rhs.low)
        }
    }

    private let keys: ContiguousArray<Key>

    init(_ keys: [Key] = []) {
        self.keys = ContiguousArray(keys.sorted())
    }

    var count: Int {
        keys.count
    }

    func contains(_ key: ContentKey) -> Bool {
        let wanted = Key(key)
        var (low, high) = (0, keys.count)
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < wanted {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < keys.count && keys[low] == wanted
    }
}
