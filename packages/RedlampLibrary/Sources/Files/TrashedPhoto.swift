import Foundation

/// A photo a batch of Redlamp's moved to the Trash that's still there (LIB-26): what Recently Trashed
/// lists and Put Back puts back (`FileOperations.trashed()`). Its row is out of the index; the journal
/// keeps it as it was, content key included, so the store's thumbnails show it.
public struct TrashedPhoto: Sendable, Hashable, Identifiable {
    /// The photo, by the batch and step that moved it and its row's ID then.
    public struct ID: Sendable, Hashable, Codable {
        public var batch: UUID
        public var step: Int
        public var photo: Int64

        public init(batch: UUID, step: Int, photo: Int64) {
            self.batch = batch
            self.step = step
            self.photo = photo
        }
    }

    /// A file that went to the Trash with the photo and is still there: a `.redlamp` sidecar, beside
    /// it or on this Mac, or another app's.
    public struct File: Sendable, Hashable {
        public var role: FileItem.Role
        /// Where it was.
        public var original: String
        /// Where it is in the Trash.
        public var place: String
    }

    public var id: ID
    /// Its row as the batch took it out of the index, with its keywords and collections.
    public var photo: RemovedPhoto
    /// Where it was: its folder's path, a slash and its name.
    public var original: String
    /// Where it is in the Trash.
    public var place: String
    /// The batch's title, "Move 3 photos to the Trash", and when it was made.
    public var title: String
    public var trashed: Date
    /// Its sidecars and other apps' that went with it, those still in the Trash.
    public var files: [File]
    /// The folder it was in when that went to the Trash whole, by its path then: Put Back brings the
    /// folder back with everything in it, as Finder's Put Back does.
    public var folder: String?
    /// The photos listed with it from its folder and its name but for the extension: its pair, which
    /// Put Back puts back with it.
    public var pair: [ID] = []
    /// The Trash folder that holds it.
    var trash: String
}
