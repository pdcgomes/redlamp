import Foundation
import RedlampDocument
import SQLite3

/// What a Lightroom Classic catalog (`.lrcat`, an SQLite database) holds that the library can take
/// (LIB-29, DEC-51), read from the catalog's own tables: its root folders and folders, its photos and
/// their ratings, picks, labels, keywords, IPTC fields and collections, its keywords with their hierarchy,
/// synonyms and export options, and its collections, sets and smart collections with their rules' text.
/// Virtual copies, edits, stacks and the places Lightroom's map gave photos are counted for the report.
///
/// The catalog is opened read-only and immutable and never written. One Lightroom has open (its
/// `.lrcat.lock` beside it) is refused; one with a write-ahead log beside it, which Lightroom leaves
/// when it stops without closing the catalog, is read from a copy in a temporary folder, so the log's
/// changes are seen and the catalog itself stays as it is. Tables and columns are looked up before
/// they're read: a catalog lacking one is still read, and `notes` says what it lacked.
public struct LightroomCatalog: Sendable {
    public struct Root: Sendable, Hashable {
        public var id: Int64
        public var name: String
        /// Where Lightroom last found it, as the catalog writes it: `/Volumes/Photos/Archive/`, or a
        /// Windows path from a catalog made there.
        public var path: String
        /// Where it is from the catalog's folder, when Lightroom could say: `../Photos/`.
        public var relativePath: String?
    }

    public struct Folder: Sendable, Hashable {
        public var id: Int64
        public var root: Int64
        /// Its path inside its root, with a slash at its end: `2024/June/`; empty for the root itself.
        public var path: String
    }

    public struct Photo: Sendable, Hashable {
        public var id: Int64
        public var folder: Int64
        /// The file's name: `IMG_0001.CR3`.
        public var name: String
        /// The extensions of the files Lightroom keeps with it as one photo, a raw's JPEG among them (`JPG`).
        public var sidecarExtensions: [String] = []
        /// 0 to 5.
        public var rating = 0
        public var flag: PhotoFlag?
        /// The label's text, as the label set in use named it: `Red`, `Approved`.
        public var label: String?
        public var keywords: [Int64] = []
        public var title: String?
        public var caption: String?
        public var creator: String?
        public var copyright: String?
        public var location: PhotoLocation?
        /// Lightroom's map, or the file, gave it a place.
        public var hasGPS = false
    }

    public struct VirtualCopy: Sendable, Hashable {
        public var id: Int64
        public var master: Int64
        public var name: String?
    }

    public struct Keyword: Sendable, Hashable {
        public var id: Int64
        public var parent: Int64?
        /// Nil for the keyword list's own top, which isn't a keyword.
        public var name: String?
        public var includeOnExport = true
        public var exportContainingKeywords = true
        public var exportSynonyms = true
        public var isPerson = false
        public var synonyms: [String] = []
    }

    public struct Collection: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case set, collection, smart
            /// The Quick Collection.
            case quick
            /// A book, slideshow, print or web gallery saved with its photos: its `creationId`.
            case output(String)
            /// Another collection Lightroom keeps for itself.
            case system(String)
        }

        public var id: Int64
        public var parent: Int64?
        public var name: String
        public var kind: Kind
        public var photos: [Int64] = []
        /// A smart collection's rules, as the catalog writes them.
        public var rules: String?
    }

    public let url: URL
    /// The catalog's version, as Lightroom numbers it: `1300025`.
    public var version: String?
    public var roots: [Root] = []
    public var folders: [Int64: Folder] = [:]
    /// Each photo but the virtual copies.
    public var photos: [Photo] = []
    public var virtualCopies: [VirtualCopy] = []
    public var keywords: [Int64: Keyword] = [:]
    public var collections: [Int64: Collection] = [:]
    /// Stacks of more than one photo.
    public var stacks = 0
    /// Photos with Develop settings that aren't the defaults.
    public var edited = 0
    /// What the catalog lacked, in words: tables and columns other versions of Lightroom have.
    public var notes: [String] = []

    init(url: URL) {
        self.url = url
    }
}

/// Why a catalog couldn't be read.
public enum LightroomCatalogError: Error, Sendable, Hashable, CustomStringConvertible {
    case noSuchFile(String)
    /// Lightroom Classic has it open: its `.lrcat.lock` is beside it.
    case openInLightroom(String)
    case notACatalog(String)
    case unreadable(String, String)

    public var description: String {
        switch self {
        case let .noSuchFile(path): "there's no catalog at \(path)"
        case let .openInLightroom(path):
            "Lightroom Classic has \((path as NSString).lastPathComponent) open: quit Lightroom, or choose a copy of "
                + "the catalog"
        case let .notACatalog(path): "\((path as NSString).lastPathComponent) isn't a Lightroom Classic catalog"
        case let .unreadable(path, why): "\((path as NSString).lastPathComponent) can't be read: \(why)"
        }
    }
}

public extension LightroomCatalog {
    /// The lock file Lightroom keeps beside a catalog it has open: `Catalog.lrcat.lock`.
    static func lockURL(of url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".lock")
    }

    /// Reads the catalog at `url`, off the caller's thread is best: a catalog of 100,000 photos takes about a
    /// second.
    static func read(_ url: URL) throws(LightroomCatalogError) -> LightroomCatalog {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { throw .noSuchFile(path) }
        guard !FileManager.default.fileExists(atPath: lockURL(of: url).path) else { throw .openInLightroom(path) }
        let log = URL(fileURLWithPath: path + "-wal")
        let logSize = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        if logSize > 0 {
            return try readCopy(url, log: log)
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(
                path: immutableURI(path),
                flags: [.readOnly, SQLiteDatabase.OpenFlags(rawValue: SQLITE_OPEN_URI)],
            )
        } catch {
            throw .unreadable(path, error.message)
        }
        return try read(database, url: url)
    }

    /// `file:` with the path's characters SQLite reads apart escaped, opened immutable: SQLite reads the file
    /// as it is, takes no lock and makes no `-shm` or `-wal` beside it.
    internal static func immutableURI(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(escaped)?mode=ro&immutable=1"
    }

    /// The catalog and its write-ahead log copied to a temporary folder and read there, where SQLite may
    /// replay the log into the copy.
    private static func readCopy(_ url: URL, log: URL) throws(LightroomCatalogError) -> LightroomCatalog {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Lightroom catalog \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            try FileManager.default.copyItem(at: log, to: URL(fileURLWithPath: copy.path + "-wal"))
            let database = try SQLiteDatabase(path: copy.path, flags: [.readWrite])
            var catalog = try read(database, url: url)
            catalog.notes.append("Lightroom didn't close the catalog: it was read from a copy, with its log")
            return catalog
        } catch let error as LightroomCatalogError {
            throw error
        } catch {
            throw .unreadable(url.path, error.message)
        }
    }

    private static func read(_ database: SQLiteDatabase, url: URL) throws(LightroomCatalogError) -> LightroomCatalog {
        do {
            let reader = try LightroomCatalogReader(database)
            guard reader.has("Adobe_images"), reader.has("AgLibraryFile"), reader.has("AgLibraryFolder") else {
                throw LightroomCatalogError.notACatalog(url.path)
            }
            return try reader.read(url: url)
        } catch let error as LightroomCatalogError {
            throw error
        } catch let error as SQLiteError where error.extendedCode & 0xFF == SQLITE_NOTADB {
            throw .notACatalog(url.path)
        } catch {
            throw .unreadable(url.path, error.message)
        }
    }
}

private extension Error {
    var message: String {
        (self as? SQLiteError)?.message ?? localizedDescription
    }
}
