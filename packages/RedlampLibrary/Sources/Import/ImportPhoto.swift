import Foundation
import RedlampDocument

/// A file of a photo on a source: the photo, its raw or JPEG pair, or a sidecar named after them.
public struct ImportFile: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        /// A raw, a JPEG, a HEIC.
        case photo
        /// Redlamp's `.redlamp`, named after the photo it's beside: a package or a single file.
        case sidecar
        /// Another app's sidecar: `.xmp`, `.dop`, `.pp3` or `.on1`.
        case otherApp
    }

    public var name: String
    public var role: Role
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool
    /// A photo's content key, once its first bytes are read.
    public var contentKey: ContentKey?

    public init(
        name: String, role: Role, size: Int64, modified: Date, isDirectory: Bool = false,
        contentKey: ContentKey? = nil,
    ) {
        self.name = name
        self.role = role
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.contentKey = contentKey
    }

    public var isRaw: Bool {
        role == .photo && NamingJob.isRaw(NamingJob.split(name).ext)
    }
}

/// What the user chose for a photo while browsing a source: whether it's imported, and the rating,
/// flag and label its `.redlamp` gets at the destination. Fields the user didn't set are the photo's
/// own, as its file and other apps' `.xmp` say.
public struct ImportChoices: Sendable, Hashable, Codable {
    public enum Field: String, Sendable, Hashable, Codable, CaseIterable {
        case rating, flag, label
    }

    public var isChosen: Bool
    /// 0 to 5 stars.
    public var rating: Int
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    /// The fields the user set.
    public var given: Set<Field>

    public init(
        isChosen: Bool = true, rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil,
        given: Set<Field> = [],
    ) {
        self.isChosen = isChosen
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.label = label
        self.given = given
    }

    public mutating func rate(_ stars: Int) {
        rating = min(max(stars, 0), 5)
        given.insert(.rating)
    }

    public mutating func setFlag(_ flag: PhotoFlag?) {
        self.flag = flag
        given.insert(.flag)
    }

    public mutating func setLabel(_ label: ColorLabel?) {
        self.label = label
        given.insert(.label)
    }

    /// The fields the user didn't set taken from `own`, the photo's own values.
    mutating func fill(from own: ImportChoices) {
        if !given.contains(.rating) {
            rating = own.rating
        }
        if !given.contains(.flag) {
            flag = own.flag
        }
        if !given.contains(.label) {
            label = own.label
        }
    }
}

/// A photo on a source, as an import shows it while browsing: its files (a raw with its JPEG, and the
/// sidecars named after them), what their first bytes say, whether the library has them, its preview,
/// and what the user chose.
public struct ImportPhoto: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Listed: names, sizes and dates.
        case listed
        /// Its first bytes read: content keys and metadata.
        case read
        /// Read, and its grid thumbnail is in the store.
        case previewed
        /// Every photo file of it is in the library already, so its preview isn't read.
        case imported
        case failed(String)
    }

    /// Its first file's path.
    public let id: String
    public let source: String
    /// The path of its folder on the source.
    public let folder: String
    /// The photo files first, the raw leading, then the sidecars.
    public var files: [ImportFile]
    /// What the first photo file's head says.
    public var metadata: CaptureMetadata?
    /// What other apps' `.xmp` beside it says.
    public var xmp: CaptureMetadata?
    public var state: State
    public var choices: ImportChoices
    /// Its files the library already has, recognised by content key, by name.
    public var imported: Set<String>

    public init(
        id: String, source: String, folder: String, files: [ImportFile], metadata: CaptureMetadata? = nil,
        xmp: CaptureMetadata? = nil, state: State = .listed, choices: ImportChoices = ImportChoices(),
        imported: Set<String> = [],
    ) {
        self.id = id
        self.source = source
        self.folder = folder
        self.files = files
        self.metadata = metadata
        self.xmp = xmp
        self.state = state
        self.choices = choices
        self.imported = imported
    }

    public var primary: ImportFile {
        files[0]
    }

    public var photoFiles: [ImportFile] {
        files.filter { $0.role == .photo }
    }

    public var url: URL {
        URL(fileURLWithPath: folder + "/" + primary.name, isDirectory: false)
    }

    public var isRead: Bool {
        switch state {
        case .listed: false
        case .read, .previewed, .imported, .failed: true
        }
    }

    /// Every photo file of it is in the library already.
    public var isImported: Bool {
        !imported.isEmpty && photoFiles.allSatisfy { imported.contains($0.name) }
    }

    /// When it was taken, by the camera's clock (wall-clock time, read as UTC); until its head is read,
    /// or when the file doesn't say, its file's date in this Mac's zone.
    public var captured: Date {
        metadata?.captured ?? Self.wallClock(primary.modified)
    }

    /// `date` as this Mac's clock shows it, read as UTC: how cameras record their times.
    static func wallClock(_ date: Date) -> Date {
        date.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: date)))
    }

    /// The rating, flag and label its own files give it: a `.redlamp`'s copied from elsewhere aren't
    /// read here, its other apps' `.xmp` first, then its embedded XMP.
    var ownChoices: ImportChoices {
        let organising = LibraryIndexer.Run.organising(metadata, sidecar: nil, xmp: xmp).fields
        return ImportChoices(rating: organising.rating ?? 0, flag: organising.flag, label: organising.label)
    }

    /// The photos a folder's `entries` hold, `source`'s, each a photo file with the others of its name but
    /// for the extension (case and Unicode's forms folded) and the sidecars named after them, the raw first.
    /// What isn't a photo or a sidecar of one (videos, a camera's own files) comes back in `others`.
    static func group(_ entries: [FileEntry], folder: String, source: String) -> (
        photos: [ImportPhoto], others: [FileEntry],
    ) {
        var byStem: [String: [FileEntry]] = [:]
        var order: [String] = []
        var rest: [FileEntry] = []
        for entry in entries {
            if FolderWalk.isPhoto(entry) {
                let stem = NamingJob.fold(NamingJob.split(entry.name).base)
                if byStem[stem] == nil {
                    order.append(stem)
                }
                byStem[stem, default: []].append(entry)
            } else {
                rest.append(entry)
            }
        }
        var claimed = Set<String>()
        var photos: [ImportPhoto] = []
        for stem in order {
            let members = byStem[stem, default: []].sorted { first, second in
                let (a, b) = (NamingJob.split(first.name).ext, NamingJob.split(second.name).ext)
                if NamingJob.isRaw(a) != NamingJob.isRaw(b) {
                    return NamingJob.isRaw(a)
                }
                return first.name < second.name
            }
            var files = members.map { entry in
                ImportFile(name: entry.name, role: .photo, size: entry.size, modified: entry.modified)
            }
            let names = Set(members.map { NamingJob.fold($0.name) })
            for entry in rest where !claimed.contains(entry.name) {
                let folded = NamingJob.fold(entry.name)
                let (base, ext) = NamingJob.split(folded)
                guard NamingJob.sidecarExtensions.contains(ext), names.contains(base) || base == stem else { continue }
                claimed.insert(entry.name)
                files.append(ImportFile(
                    name: entry.name, role: ext == "redlamp" ? .sidecar : .otherApp, size: entry.size,
                    modified: entry.modified, isDirectory: entry.isDirectory,
                ))
            }
            photos.append(ImportPhoto(id: folder + "/" + members[0].name, source: source, folder: folder, files: files))
        }
        return (photos, rest.filter { !claimed.contains($0.name) && !$0.isDirectory })
    }
}
