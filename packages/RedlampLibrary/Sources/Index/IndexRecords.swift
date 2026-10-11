import Foundation
import RedlampDocument
import RedlampEngineAPI

// Rows of the index's tables. An `id` of 0 is a row the index hasn't assigned yet. Dates are
// stored as seconds since 1970, as SQLite's date functions expect.

/// A disk the library's photos are on: internal, external or a network share.
public struct VolumeRecord: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable, CaseIterable {
        case unknown = 0
        case ssd = 1
        case spinning = 2
        case network = 3
    }

    public var id: Int64
    /// The volume's UUID (`URLResourceKey.volumeUUIDStringKey`).
    public var uuid: String
    public var name: String?
    public var kind: Kind
    /// The UUID of the volume's FSEvents database (`FSEventsCopyUUIDForDevice`).
    public var eventDatabase: String?
    /// The last FSEvents event the index applied.
    public var lastEvent: UInt64?

    public init(
        id: Int64 = 0, uuid: String, name: String? = nil, kind: Kind = .unknown, eventDatabase: String? = nil,
        lastEvent: UInt64? = nil,
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.kind = kind
        self.eventDatabase = eventDatabase
        self.lastEvent = lastEvent
    }
}

/// A folder added to the library, with everything under it.
public struct RootRecord: Sendable, Hashable {
    /// Where the root's sidecars are kept (DEC-43).
    public enum Sidecars: Int, Sendable, Hashable, CaseIterable {
        case besidePhotos = 0
        case onThisMac = 1
    }

    public var id: Int64
    public var volume: Int64
    public var path: String
    /// A security-scoped bookmark to the folder.
    public var bookmark: Data?
    public var sidecars: Sidecars

    public init(id: Int64 = 0, volume: Int64, path: String, bookmark: Data? = nil, sidecars: Sidecars = .besidePhotos) {
        self.id = id
        self.volume = volume
        self.path = path
        self.bookmark = bookmark
        self.sidecars = sidecars
    }
}

/// A folder under a root, by its path as the file system lists it.
public struct FolderRecord: Sendable, Hashable {
    public var id: Int64
    public var root: Int64
    public var parent: Int64?
    public var path: String
    /// The last listing's signature: the folder's modification date, its entry count and a hash
    /// of names, sizes and dates.
    public var signature: Int64?
    /// The signature the folder's photos were indexed at.
    public var indexedSignature: Int64?
    public var listedAt: Date?

    public init(
        id: Int64 = 0, root: Int64, parent: Int64? = nil, path: String, signature: Int64? = nil,
        indexedSignature: Int64? = nil, listedAt: Date? = nil,
    ) {
        self.id = id
        self.root = root
        self.parent = parent
        self.path = path
        self.signature = signature
        self.indexedSignature = indexedSignature
        self.listedAt = listedAt
    }

    /// The folder's photos are indexed as its last listing found them.
    public var isIndexed: Bool {
        signature != nil && indexedSignature == signature
    }
}

/// A photo: where it is, which file it is, what it shows, and how it's organised.
public struct PhotoRecord: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable, CaseIterable {
        case other = 0
        case raw = 1
        case jpeg = 2
        case heic = 3
        case tiff = 4
        case png = 5

        public init(pathExtension: String) {
            let ext = pathExtension.lowercased()
            self = switch ext {
            case _ where SupportedFormats.rawExtensions.contains(ext): .raw
            case "jpg", "jpeg": .jpeg
            case "heic", "heif": .heic
            case "tif", "tiff": .tiff
            case "png": .png
            default: .other
            }
        }
    }

    /// Why a photo can't be read now.
    public struct State: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Gone from its folder outside Redlamp (DEC-59): listed only by Library Health's Missing check.
        public static let missing = State(rawValue: 1 << 0)
        /// On a volume that isn't connected.
        public static let offline = State(rawValue: 1 << 1)
        /// Still being written (a copy in progress).
        public static let settling = State(rawValue: 1 << 2)
        /// Its file couldn't be read, for a reason other than its being gone or its volume away
        /// (LIB-40): left out of lists, the reader's reason in `PhotoHealth`.
        public static let unreadable = State(rawValue: 1 << 3)
    }

    public var id: Int64
    public var folder: Int64
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date
    /// The file's identifier on its volume (`URLResourceKey.fileIdentifierKey`).
    public var fileID: UInt64?
    /// The first 16 bytes of SHA-256 over the file's size and its first 64 KiB.
    public var contentKey: Data?
    /// When it was taken, by the camera's clock with the shift its sidecar gives it (LIB-22).
    public var captured: Date?
    /// The capture time's offset from UTC, in seconds: the zone its sidecar gives the camera, or the one
    /// its file records.
    public var capturedOffset: Int?
    public var camera: Int64?
    public var lens: Int64?
    public var iso: Double?
    public var aperture: Double?
    /// Seconds.
    public var shutter: Double?
    /// Millimetres.
    public var focal: Double?
    public var width: Int?
    public var height: Int?
    /// EXIF orientation, 1 to 8.
    public var orientation: Int?
    public var latitude: Double?
    public var longitude: Double?
    /// 0 to 5 stars.
    public var rating: Int
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    /// In the quick collection.
    public var marked: Bool
    public var edited: Bool
    public var sidecarModified: Date?
    /// The modification date of the photo's `.xmp`, or the later of its two (`IMG_1234.xmp` and
    /// darktable's `IMG_1234.ARW.xmp`).
    public var xmpModified: Date?
    public var title: String?
    public var caption: String?
    public var state: State
    /// How far indexing has got with the photo, in the indexer's terms: 0 before its file is read, 1 once it is,
    /// and `lensToRead` for a photo read before the index kept its lens's fields.
    public var indexed: Int
    /// A label's name outside the five colours, when `label` is nil.
    public var customLabel: String?
    public var creator: String?
    public var copyright: String?
    public var location: PhotoLocation?
    /// Its manual stack, or its being shown for its burst (LIB-28), as its sidecar holds it.
    public var stack: PhotoStack?
    /// The organising fields whose values are other apps' rather than the `.redlamp`'s: kept when only
    /// the `.redlamp` changes, without reading other apps' files again.
    public var otherFields: Set<XMPField>
    /// Changes whenever either of the photo's `.xmp` files does (`LibraryIndexer.xmpSignature`).
    public var xmpSignature: Int64?
    /// The time the camera recorded and the zone its file records, while its sidecar shifts the time or
    /// gives the camera another zone; nil, with `cameraOffset`, when `captured` and `capturedOffset` are
    /// the camera's own.
    public var cameraCaptured: Date?
    public var cameraOffset: Int?
    /// When change tracking found its file gone, while `state` has `.missing`.
    public var missingSince: Date?
    /// The widest f-number its lens had at its focal length (`LensOptics.widestAperture`).
    public var widestAperture: Double?
    /// Its focal length in 35 mm terms, in whole millimetres (`LensOptics.focal35`).
    public var focal35: Double?

    public init(
        id: Int64 = 0, folder: Int64, name: String, kind: Kind? = nil, size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 0), fileID: UInt64? = nil, contentKey: Data? = nil,
        captured: Date? = nil, capturedOffset: Int? = nil, camera: Int64? = nil, lens: Int64? = nil,
        iso: Double? = nil, aperture: Double? = nil, shutter: Double? = nil, focal: Double? = nil,
        width: Int? = nil, height: Int? = nil, orientation: Int? = nil, latitude: Double? = nil,
        longitude: Double? = nil, rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil,
        marked: Bool = false, edited: Bool = false, sidecarModified: Date? = nil, xmpModified: Date? = nil,
        title: String? = nil, caption: String? = nil, state: State = [], indexed: Int = 0,
        customLabel: String? = nil, creator: String? = nil, copyright: String? = nil,
        location: PhotoLocation? = nil, stack: PhotoStack? = nil, otherFields: Set<XMPField> = [],
        xmpSignature: Int64? = nil, cameraCaptured: Date? = nil, cameraOffset: Int? = nil, missingSince: Date? = nil,
        widestAperture: Double? = nil, focal35: Double? = nil,
    ) {
        self.id = id
        self.folder = folder
        self.name = name
        self.kind = kind ?? Kind(pathExtension: (name as NSString).pathExtension)
        self.size = size
        self.modified = modified
        self.fileID = fileID
        self.contentKey = contentKey
        self.captured = captured
        self.capturedOffset = capturedOffset
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focal = focal
        self.width = width
        self.height = height
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.rating = rating
        self.flag = flag
        self.label = label
        self.marked = marked
        self.edited = edited
        self.sidecarModified = sidecarModified
        self.xmpModified = xmpModified
        self.title = title
        self.caption = caption
        self.state = state
        self.indexed = indexed
        self.customLabel = customLabel
        self.creator = creator
        self.copyright = copyright
        self.location = location
        self.stack = stack
        self.otherFields = otherFields
        self.xmpSignature = xmpSignature
        self.cameraCaptured = cameraCaptured
        self.cameraOffset = cameraOffset
        self.missingSince = missingSince
        self.widestAperture = widestAperture
        self.focal35 = focal35
    }

    /// `indexed` of a photo read before the index kept its lens's widest aperture and 35 mm focal length (schema
    /// version 12): the indexer reads its file again for those two alone.
    public static let lensToRead = 2

    /// The `other_fields` column: a bit for each field, in `XMPField`'s order.
    public static func code(for fields: Set<XMPField>) -> Int {
        XMPField.allCases.enumerated().reduce(0) { code, field in
            fields.contains(field.element) ? code | 1 << field.offset : code
        }
    }

    public static func fields(code: Int) -> Set<XMPField> {
        Set(XMPField.allCases.enumerated().filter { code & 1 << $0.offset != 0 }.map(\.element))
    }

    /// The `flag` column: 0 for none, 1 pick, 2 reject.
    public static func code(for flag: PhotoFlag?) -> Int {
        switch flag {
        case nil: 0
        case .pick: 1
        case .reject: 2
        }
    }

    public static func flag(code: Int) -> PhotoFlag? {
        switch code {
        case 1: .pick
        case 2: .reject
        default: nil
        }
    }

    /// The `label` column: 0 for none, then red, yellow, green, blue and purple from 1.
    public static func code(for label: ColorLabel?) -> Int {
        label.flatMap { ColorLabel.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    }

    public static func label(code: Int) -> ColorLabel? {
        ColorLabel.allCases.indices.contains(code - 1) ? ColorLabel.allCases[code - 1] : nil
    }
}

/// The columns the column store keeps for one photo (LIB-06), as the index stores them.
public struct HotColumns: Sendable, Hashable {
    public var id: Int64
    public var folder: Int64
    /// Seconds since 1970.
    public var captured: Double?
    public var camera: Int64?
    public var lens: Int64?
    public var rating: Int
    /// `PhotoRecord.code(for:)` of the flag.
    public var flag: Int
    /// `PhotoRecord.code(for:)` of the label.
    public var label: Int
    public var marked: Bool
    public var edited: Bool
    public var iso: Double?
    public var aperture: Double?
    public var focal: Double?
    /// A `PhotoRecord.Kind` raw value.
    public var kind: Int
    public var name: String
}
