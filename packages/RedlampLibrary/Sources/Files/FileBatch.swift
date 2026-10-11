import Foundation
import RedlampDocument

/// One batch of the library's file operations (LIB-26): photos renamed, moved or copied with their
/// sidecars, folders made, moved or removed, photos and folders moved to the Trash, and put back from
/// it, as steps that run in order, each with what it does to the index. `FileOperations` writes it to
/// the journal, and syncs it, before anything moves; Undo is a batch of the steps' inverses, run
/// backwards, and a copy's Undo moves the copies to the Trash.
public struct FileBatch: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case rename, move, newFolder, trash, undo
        /// Photos from Recently Trashed put back where they were.
        case putBack
        /// Photos copied into a folder, each copy a photo of its own.
        case copy
        /// Missing photos taken out of the library (DEC-59): nothing moves.
        case remove
        /// Missing photos found again in the files the user located (DEC-59).
        case relink
    }

    public let id: UUID
    public var kind: Kind
    /// What it does, as Undo names it: "Rename 120 photos".
    public var title: String
    public let created: Date
    public var steps: [FileStep]
    /// The batch this one undoes.
    public var undoes: UUID?
    /// For an Undo or a Put Back, what it leaves out because it isn't where a batch put it any more,
    /// by path.
    public var gone: [String] = []
    /// For a move to the Trash, the photos it was asked to move that the index no longer has, which
    /// it leaves out: the caller says so, since it moves fewer photos than it was asked to.
    public var notInIndex: [Int64] = []

    public init(
        id: UUID = UUID(), kind: Kind, title: String, created: Date = Date(), steps: [FileStep], undoes: UUID? = nil,
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.created = created
        self.steps = steps
        self.undoes = undoes
    }

    /// The photos the batch renames, moves or removes, or the copies it makes.
    public var photoCount: Int {
        Set(steps.flatMap { $0.photos.map(\.id) + $0.removed.map(\.photo.id) }).count
    }
}

/// A step of a batch: what moves, together, and what that does to the index.
public struct FileStep: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Files and folders renamed or moved together: photos with their pair, their `.redlamp`
        /// sidecars and other apps', or a folder.
        case move
        case createFolder
        /// A folder whose contents went to another volume, removed once nothing is left in it.
        case removeFolder
        case trash
        /// Out of the Trash, back where it was.
        case putBack
        /// Each photo's name before Redlamp first renamed it, written in its sidecar
        /// (`PhotoMetadata.originalName`); taken out again when it's undone.
        case recordOriginalNames
        case clearOriginalNames
        /// Files copied together, each to a place nothing held: a photo with its pair, its `.redlamp`
        /// sidecars and other apps', each checked byte for byte; the originals stay. Each copy is a photo
        /// of its own, with a row of its own (`removed`): its original's, under a new ID, in no
        /// collection or stack.
        case copy
        /// The copies' sidecars made their own: out of the collections and the stack their originals
        /// are in, and, for a copy given a number, its original's name recorded as its original name
        /// unless it has one. Like original names, it can't be told done, so it's made again.
        case detachCopies
        /// Photos taken out of the index with nothing moved, their rows as they were in `removed`: missing photos
        /// removed from the library (DEC-59), or the row a file had while a missing photo is relinked to it.
        case removeFromLibrary
        /// Photos put back in the index as `removed` has them, as `removeFromLibrary` took them out; one whose place
        /// another photo has taken since stays out.
        case returnToLibrary
        /// A missing photo found again (DEC-59): its row moved to the file it was found as (`photos`, from where it
        /// was), with that file's identifier, size and date, and read again from it. `items` are the file, which
        /// stays where it is, and the `.redlamp` sidecar the photo left behind, brought beside it; `removed` is the
        /// photo's row as it was; with `writesDecisions`, a file without a sidecar is given one with what the row
        /// holds.
        case relink
        /// A relinked photo back where it was, missing again, as `removed` has its row, and the sidecar its relink
        /// brought beside the file taken back.
        case unlink
    }

    public var kind: Kind
    public var items: [FileItem]
    /// Photos it renames or moves (`move`), or whose original names it records or clears; for `copy`
    /// and `detachCopies`, the copies, by their own IDs, from their originals' paths to their own.
    public var photos: [PhotoMove]
    /// Folders it renames or moves on their volume, keeping their rows.
    public var folders: [FolderMove]
    /// The folder it makes or removes.
    public var folder: String?
    /// Photos it takes out of the index (`trash`) or puts back (`putBack`), with their rows as they
    /// were; for `copy`, the copies' rows it adds.
    public var removed: [RemovedPhoto]
    /// Folders it takes out of the index or puts back, with their rows as they were, parents first.
    public var removedFolders: [RemovedFolder]
    /// After it, nothing is under a temporary name: a batch that's cancelled stops after a safe step.
    public var isSafe: Bool
    /// For `relink`, the file it finds the photo as has no `.redlamp` sidecar, nor did the photo leave one behind: the
    /// photo's decisions, as its row holds them, are written in a new one, so reading the file again keeps them.
    public var writesDecisions: Bool

    public init(
        kind: Kind, items: [FileItem] = [], photos: [PhotoMove] = [], folders: [FolderMove] = [],
        folder: String? = nil, removed: [RemovedPhoto] = [], removedFolders: [RemovedFolder] = [], isSafe: Bool = true,
        writesDecisions: Bool = false,
    ) {
        self.kind = kind
        self.items = items
        self.photos = photos
        self.folders = folders
        self.folder = folder
        self.removed = removed
        self.removedFolders = removedFolders
        self.isSafe = isSafe
        self.writesDecisions = writesDecisions
    }

    private enum CodingKeys: String, CodingKey {
        case kind, items, photos, folders, folder, removed, removedFolders, isSafe, writesDecisions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        items = try container.decodeIfPresent([FileItem].self, forKey: .items) ?? []
        photos = try container.decodeIfPresent([PhotoMove].self, forKey: .photos) ?? []
        folders = try container.decodeIfPresent([FolderMove].self, forKey: .folders) ?? []
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        removed = try container.decodeIfPresent([RemovedPhoto].self, forKey: .removed) ?? []
        removedFolders = try container.decodeIfPresent([RemovedFolder].self, forKey: .removedFolders) ?? []
        isSafe = try container.decodeIfPresent(Bool.self, forKey: .isSafe) ?? true
        writesDecisions = try container.decodeIfPresent(Bool.self, forKey: .writesDecisions) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if !items.isEmpty {
            try container.encode(items, forKey: .items)
        }
        if !photos.isEmpty {
            try container.encode(photos, forKey: .photos)
        }
        if !folders.isEmpty {
            try container.encode(folders, forKey: .folders)
        }
        try container.encodeIfPresent(folder, forKey: .folder)
        if !removed.isEmpty {
            try container.encode(removed, forKey: .removed)
        }
        if !removedFolders.isEmpty {
            try container.encode(removedFolders, forKey: .removedFolders)
        }
        if !isSafe {
            try container.encode(isSafe, forKey: .isSafe)
        }
        if writesDecisions {
            try container.encode(writesDecisions, forKey: .writesDecisions)
        }
    }
}

/// A file or folder a step moves, and how it was when the batch was planned, to tell it from
/// another one that took its name since.
public struct FileItem: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        case photo
        /// A `.redlamp` sidecar beside its photo.
        case sidecar
        /// A `.redlamp` sidecar in Redlamp on this Mac (`LibraryPaths.sidecars`).
        case sidecarOnThisMac
        /// Another app's sidecar: `.xmp`, `.dop`, `.pp3` or `.on1`.
        case otherApp
        case folder
        /// Anything else in a folder that moves to another volume a file at a time.
        case file
    }

    public var role: Role
    public var source: String
    /// Nil for the Trash: where it goes there is known once it's there.
    public var destination: String?
    /// To another volume: copied, checked byte for byte and only then removed where it was.
    public var copies: Bool
    public var fileID: UInt64?
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool

    public init(
        role: Role, source: String, destination: String?, copies: Bool = false, fileID: UInt64? = nil,
        size: Int64? = nil, modified: Date? = nil, isDirectory: Bool = false,
    ) {
        self.role = role
        self.source = source
        self.destination = destination
        self.copies = copies
        self.fileID = fileID
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }

    /// The step can't do without it: the photo, the folder, or a file of a folder.
    public var isRequired: Bool {
        role == .photo || role == .folder || role == .file
    }

    private enum CodingKeys: String, CodingKey {
        case role, source, destination, copies, fileID, size, modified, isDirectory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        source = try container.decode(String.self, forKey: .source)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        copies = try container.decodeIfPresent(Bool.self, forKey: .copies) ?? false
        fileID = try container.decodeIfPresent(UInt64.self, forKey: .fileID)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        modified = try container.decodeIfPresent(Double.self, forKey: .modified).map(Date.init(timeIntervalSince1970:))
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(destination, forKey: .destination)
        if copies {
            try container.encode(copies, forKey: .copies)
        }
        try container.encodeIfPresent(fileID, forKey: .fileID)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(modified?.timeIntervalSince1970, forKey: .modified)
        if isDirectory {
            try container.encode(isDirectory, forKey: .isDirectory)
        }
    }
}

/// A photo's row moving from one path to another: its folder's path, a slash and its name.
public struct PhotoMove: Sendable, Hashable, Codable {
    public var id: Int64
    public var from: String
    public var to: String

    public init(id: Int64, from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// A photo taking a new name in its folder: its path as it is, and the name, with its extension, it
/// takes.
public struct PhotoRename: Sendable, Hashable {
    public var id: Int64
    public var path: String
    public var name: String

    public init(id: Int64, path: String, name: String) {
        self.id = id
        self.path = path
        self.name = name
    }

    var move: PhotoMove {
        PhotoMove(id: id, from: path, to: FilePlanner.split(path).folder + "/" + name)
    }
}

/// A folder's row, and those below it, moving from one path to another.
public struct FolderMove: Sendable, Hashable, Codable {
    public var id: Int64
    public var from: String
    public var to: String

    public init(id: Int64, from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// A photo's row as it was when the batch took it out of the index, to put back as it was: its
/// keywords and collections too. For a copy, the row the copy gets.
public struct RemovedPhoto: Sendable, Hashable, Codable {
    public var photo: IndexedPhoto
    /// Its folder's path.
    public var folder: String
    public var keywords: [String]
    public var collections: [CollectionPlace]
    /// For a copy's row, the photo it's a copy of.
    public var copyOf: Int64?

    public init(
        photo: IndexedPhoto, folder: String, keywords: [String] = [], collections: [CollectionPlace] = [],
        copyOf: Int64? = nil,
    ) {
        self.photo = photo
        self.folder = folder
        self.keywords = keywords
        self.collections = collections
        self.copyOf = copyOf
    }
}

/// A photo's place in a collection.
public struct CollectionPlace: Sendable, Hashable, Codable {
    public var collection: Int64
    public var position: Int?
    /// The collection's path, which a photo is put back by: an index made again since gives collections other IDs.
    /// Nil in batches journaled before it.
    public var path: String?

    public init(collection: Int64, position: Int?, path: String? = nil) {
        self.collection = collection
        self.position = position
        self.path = path
    }
}

/// A folder's row as it was when the batch took it out of the index.
public struct RemovedFolder: Sendable, Hashable, Codable {
    public var id: Int64
    public var root: Int64
    public var path: String
    public var signature: Int64?
    public var indexedSignature: Int64?

    public init(_ folder: FolderRecord) {
        id = folder.id
        root = folder.root
        path = folder.path
        signature = folder.signature
        indexedSignature = folder.indexedSignature
    }
}

/// Every field of a photo's row, as the journal keeps it.
public struct IndexedPhoto: Sendable, Hashable, Codable {
    public var id: Int64
    public var name: String
    public var kind: Int
    public var size: Int64
    public var modified: Double
    public var fileID: UInt64?
    public var contentKey: Data?
    public var captured: Double?
    public var capturedOffset: Int?
    public var camera: Int64?
    public var lens: Int64?
    public var iso: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var focal: Double?
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var rating: Int
    public var flag: Int
    public var label: Int
    public var marked: Bool
    public var edited: Bool
    public var sidecarModified: Double?
    public var xmpModified: Double?
    public var title: String?
    public var caption: String?
    public var state: Int
    public var indexed: Int
    public var customLabel: String?
    public var creator: String?
    public var copyright: String?
    public var sublocation: String?
    public var city: String?
    public var province: String?
    public var country: String?
    public var countryCode: String?
    public var stack: UUID?
    /// Nil in batches journaled before the index kept stacks, organising fields' sources and `.xmp`
    /// signatures, as are `stack` and `xmpSignature`.
    public var stackTop: Bool?
    /// The photo's place in its stack, from 0 at the top; nil while the stack is in capture order, and in batches
    /// journaled before the index kept places (schema version 9), whose photos come back after the stack's others.
    public var stackPosition: Int?
    /// `PhotoRecord.code(for:)` of the fields that are other apps'.
    public var otherFields: Int?
    public var xmpSignature: Int64?
    /// Nil in batches journaled before the index kept the camera's own capture time, as when the
    /// sidecar doesn't change it.
    public var cameraCaptured: Double?
    public var cameraOffset: Int?
    /// When a missing photo's file was found gone (DEC-59); nil in batches journaled before the index kept it
    /// (schema version 11), which had no missing photos.
    public var missingSince: Double?
    /// The widest aperture of its lens and its focal length in 35 mm terms; nil in batches journaled before the index
    /// kept them (schema version 12).
    public var widestAperture: Double?
    public var focal35: Double?

    public init(_ photo: PhotoRecord) {
        id = photo.id
        name = photo.name
        kind = photo.kind.rawValue
        size = photo.size
        modified = photo.modified.timeIntervalSince1970
        fileID = photo.fileID
        contentKey = photo.contentKey
        captured = photo.captured?.timeIntervalSince1970
        capturedOffset = photo.capturedOffset
        camera = photo.camera
        lens = photo.lens
        iso = photo.iso
        aperture = photo.aperture
        shutter = photo.shutter
        focal = photo.focal
        width = photo.width
        height = photo.height
        orientation = photo.orientation
        latitude = photo.latitude
        longitude = photo.longitude
        rating = photo.rating
        flag = PhotoRecord.code(for: photo.flag)
        label = PhotoRecord.code(for: photo.label)
        marked = photo.marked
        edited = photo.edited
        sidecarModified = photo.sidecarModified?.timeIntervalSince1970
        xmpModified = photo.xmpModified?.timeIntervalSince1970
        title = photo.title
        caption = photo.caption
        state = photo.state.rawValue
        indexed = photo.indexed
        customLabel = photo.customLabel
        creator = photo.creator
        copyright = photo.copyright
        sublocation = photo.location?.sublocation
        city = photo.location?.city
        province = photo.location?.state
        country = photo.location?.country
        countryCode = photo.location?.countryCode
        stack = photo.stack?.id
        stackTop = photo.stack?.top ?? false
        stackPosition = photo.stack?.position
        otherFields = PhotoRecord.code(for: photo.otherFields)
        xmpSignature = photo.xmpSignature
        cameraCaptured = photo.cameraCaptured?.timeIntervalSince1970
        cameraOffset = photo.cameraOffset
        missingSince = photo.missingSince?.timeIntervalSince1970
        widestAperture = photo.widestAperture
        focal35 = photo.focal35
    }

    /// The row in `folder`.
    public func record(inFolder folder: Int64) -> PhotoRecord {
        PhotoRecord(
            id: id, folder: folder, name: name, kind: PhotoRecord.Kind(rawValue: kind) ?? .other, size: size,
            modified: Date(timeIntervalSince1970: modified), fileID: fileID, contentKey: contentKey,
            captured: captured.map(Date.init(timeIntervalSince1970:)), capturedOffset: capturedOffset, camera: camera,
            lens: lens, iso: iso, aperture: aperture, shutter: shutter, focal: focal, width: width, height: height,
            orientation: orientation, latitude: latitude, longitude: longitude, rating: rating,
            flag: PhotoRecord.flag(code: flag), label: PhotoRecord.label(code: label), marked: marked, edited: edited,
            sidecarModified: sidecarModified.map(Date.init(timeIntervalSince1970:)),
            xmpModified: xmpModified.map(Date.init(timeIntervalSince1970:)), title: title, caption: caption,
            state: PhotoRecord.State(rawValue: state), indexed: indexed, customLabel: customLabel,
            creator: creator, copyright: copyright,
            location: PhotoRecord.storedLocation(
                sublocation: sublocation, city: city, province: province, country: country, countryCode: countryCode,
            ),
            stack: PhotoRecord.storedStack(id: stack?.uuidString, top: stackTop ?? false, position: stackPosition),
            otherFields: PhotoRecord.fields(code: otherFields ?? 0), xmpSignature: xmpSignature,
            cameraCaptured: cameraCaptured.map(Date.init(timeIntervalSince1970:)), cameraOffset: cameraOffset,
            missingSince: missingSince.map(Date.init(timeIntervalSince1970:)), widestAperture: widestAperture,
            focal35: focal35,
        )
    }
}

extension FileStep {
    /// The step that undoes this one, once it has run: `trashed` says where each item went in the
    /// Trash (nil for one that didn't get there).
    func inverse(trashed: [String?]) -> FileStep {
        switch kind {
        case .move:
            FileStep(
                kind: .move,
                items: items.reversed().compactMap { item in
                    item.destination.map { destination in
                        var inverse = item
                        inverse.source = destination
                        inverse.destination = item.source
                        if item.copies || item.isDirectory {
                            // A copy is another file on its volume, and a folder may have been
                            // copied away and back since.
                            inverse.fileID = nil
                        }
                        return inverse
                    }
                },
                photos: photos.map { PhotoMove(id: $0.id, from: $0.to, to: $0.from) },
                folders: folders.reversed().map { FolderMove(id: $0.id, from: $0.to, to: $0.from) },
                isSafe: isSafe,
            )
        case .createFolder:
            FileStep(kind: .removeFolder, folder: folder, removedFolders: removedFolders)
        case .removeFolder:
            FileStep(kind: .createFolder, folder: folder, removedFolders: removedFolders)
        case .trash:
            FileStep(
                kind: .putBack,
                items: zip(items, trashed).compactMap { item, trashed in
                    trashed.map { place in
                        var item = item
                        item.destination = item.source
                        item.source = place
                        return item
                    }
                },
                removed: removed, removedFolders: removedFolders,
            )
        case .putBack:
            FileStep(kind: .trash, items: items.map { item in
                var item = item
                item.source = item.destination ?? item.source
                item.destination = nil
                return item
            }, removed: removed, removedFolders: removedFolders)
        case .recordOriginalNames:
            FileStep(kind: .clearOriginalNames, photos: photos)
        case .clearOriginalNames:
            FileStep(kind: .recordOriginalNames, photos: photos)
        case .copy:
            // Rolled back, the copies' files are removed, as their rows are.
            FileStep(kind: .trash, removed: removed)
        case .detachCopies:
            // The copies' sidecars go with them.
            FileStep(kind: .detachCopies)
        case .removeFromLibrary:
            FileStep(kind: .returnToLibrary, removed: removed)
        case .returnToLibrary:
            FileStep(kind: .removeFromLibrary, removed: removed)
        case .relink:
            // The file stays where it is, and a sidecar written with the photo's decisions stays with it.
            FileStep(kind: .unlink, items: Self.back(items), photos: Self.back(photos), removed: removed)
        case .unlink:
            FileStep(kind: .relink, items: Self.back(items), photos: Self.back(photos), removed: removed)
        }
    }

    /// `items` the other way, last first: those that move go back where they were, the others stay.
    private static func back(_ items: [FileItem]) -> [FileItem] {
        items.reversed().map { item in
            guard let destination = item.destination else { return item }
            var back = item
            back.source = destination
            back.destination = item.source
            return back
        }
    }

    private static func back(_ photos: [PhotoMove]) -> [PhotoMove] {
        photos.map { PhotoMove(id: $0.id, from: $0.to, to: $0.from) }
    }
}
