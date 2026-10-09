import Foundation

/// Where the library keeps what isn't beside the photos: the index, its snapshots, the thumbnail
/// and preview store, the sidecars of folders kept on this Mac, and the definitions that aren't
/// per photo (the keyword list, collections, smart collections, naming and import presets).
///
/// All of it is on the Mac's own disk, never on a network volume: SQLite's locking isn't reliable
/// over network file systems, and the store is what lets slow volumes browse quickly.
public struct LibraryPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Redlamp/Library`.
    public static var standard: LibraryPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryPaths(root: support.appending(path: "Redlamp/Library", directoryHint: .isDirectory))
    }

    /// The index: rebuilt from the photos and their sidecars whenever it's lost. `Index.ids` beside it keeps the
    /// last IDs it gave, which an index rebuilt or restored gives none of again (`IndexIDMarks`).
    public var index: URL {
        root.appending(path: "Index.sqlite")
    }

    /// Copies of the index taken while it runs, the newest restored when the index is damaged.
    public var snapshots: URL {
        root.appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    /// Thumbnails and previews, keyed by photo identity rather than by path or index row.
    public var store: URL {
        root.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// Sidecars of the folders that keep them on this Mac (DEC-43).
    public var sidecars: URL {
        root.appending(path: "Sidecars", directoryHint: .isDirectory)
    }

    /// The keyword list, collections, smart collections and presets, as readable files (DEC-42).
    public var definitions: URL {
        root.appending(path: "Definitions", directoryHint: .isDirectory)
    }
}
