import Foundation

/// What the indexer reports as it goes, each once the index holds it.
public enum LibraryIndexerEvent: Sendable, Hashable {
    /// A folder's photos are indexed as its listing found them.
    case folderIndexed(FolderIndexed)
    /// Photos added to the index, by ID.
    case photosInserted([Int64])
    /// Photos whose rows changed, keeping their IDs: read again, organised in another app, renamed
    /// or moved.
    case photosUpdated([Int64])
    /// Photos taken out of the index: those of a root removed from the library.
    case photosRemoved([Int64])
    /// Photos whose files went from their folders outside Redlamp, kept in the index as missing (DEC-59): every list
    /// but Library Health's Missing check leaves them out.
    case photosMissing([Int64])
    /// A volume stopped answering: its photos are marked offline. By the index's name for it
    /// (`VolumeRecord.uuid`).
    case volumeOffline(String)
    /// A volume answers again, and its photos are no longer marked offline.
    case volumeOnline(String)
    /// A folder or photo that couldn't be read, or a batch that couldn't be written. Its folder isn't
    /// marked indexed, so the next run tries it again.
    case failed(path: String, message: String)
    /// The run is over: everything it read is written.
    case finished(LibraryIndexerSummary)
}

/// A folder whose photos are indexed, and what that changed.
public struct FolderIndexed: Sendable, Hashable {
    public var path: String
    public var inserted: Int
    public var updated: Int
    /// Photos that left it outside Redlamp, now missing.
    public var removed: Int

    public init(path: String, inserted: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.path = path
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }
}

/// What a run did.
public struct LibraryIndexerSummary: Sendable, Hashable {
    public var foldersListed = 0
    /// Folders whose listing had changed, and whose photos are indexed again.
    public var foldersIndexed = 0
    public var foldersRemoved = 0
    public var photosInserted = 0
    /// Photos read again, or organised in another app; moves aren't counted here.
    public var photosUpdated = 0
    /// Photos renamed or moved, found by their file identifiers and kept with their IDs.
    public var photosMoved = 0
    /// Photos of roots removed from the library, taken out of the index.
    public var photosRemoved = 0
    /// Photos whose files went from their folders, kept as missing (DEC-59).
    public var photosMissing = 0
    /// Photos whose first `PhotoMetadataReader.headLength` bytes were read.
    public var headsRead = 0
    /// Photos written as unreadable (LIB-40): their read failed, though they're there and their volume
    /// answers. Empty files and files no format starts or that end early aren't counted: lists keep them.
    public var photosUnreadable = 0
    /// Photos whose ends were read to see whether they end early.
    public var endsRead = 0
    public var failures = 0
    /// The volumes that stopped answering, by the index's name for them.
    public var offlineVolumes: [String] = []
    public var elapsed = Duration.zero

    public init() {}
}

/// A folder change detection names for listing again (LIB-08).
public struct FolderChange: Sendable, Hashable {
    public var url: URL
    /// Its subfolders are listed again too: their changes weren't recorded one by one.
    public var recursive: Bool

    public init(_ url: URL, recursive: Bool = false) {
        self.url = url
        self.recursive = recursive
    }
}
