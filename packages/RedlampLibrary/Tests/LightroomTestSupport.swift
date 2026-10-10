import Compression
import Foundation
import RedlampDocument
@testable import RedlampLibrary

/// A Lightroom Classic catalog made for a test (LIB-29): the tables the import reads, with the columns Lightroom
/// gives them, filled by the test. Never a catalog Lightroom made.
final class LightroomCatalogMaker {
    let url: URL
    private let database: SQLiteDatabase
    private var next: Int64 = 100
    /// The keyword list's own top, which isn't a keyword.
    private(set) var topKeyword: Int64 = 1

    static let schema = """
    CREATE TABLE Adobe_variablesTable (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, name, type,
      value NOT NULL DEFAULT '');
    CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
      absolutePath UNIQUE NOT NULL DEFAULT '', name NOT NULL DEFAULT '', relativePathFromCatalog);
    CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, parentId INTEGER,
      pathFromRoot NOT NULL DEFAULT '', rootFolder INTEGER NOT NULL DEFAULT 0, visibility INTEGER);
    CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, baseName NOT NULL DEFAULT '',
      errorMessage, errorTime, extension NOT NULL DEFAULT '', externalModTime, folder INTEGER NOT NULL DEFAULT 0,
      idx_filename NOT NULL DEFAULT '', importHash, lc_idx_filename NOT NULL DEFAULT '',
      lc_idx_filenameExtension NOT NULL DEFAULT '', md5, modTime, originalFilename NOT NULL DEFAULT '',
      sidecarExtensions);
    CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
      aspectRatioCache NOT NULL DEFAULT -1, bitDepth NOT NULL DEFAULT 0, captureTime,
      colorChannels NOT NULL DEFAULT 0, colorLabels NOT NULL DEFAULT '', colorMode NOT NULL DEFAULT -1,
      copyCreationTime NOT NULL DEFAULT -63113817600, copyName, copyReason, developSettingsIDCache,
      editLock INTEGER NOT NULL DEFAULT 0, fileFormat NOT NULL DEFAULT 'unset', fileHeight, fileWidth,
      hasMissingSidecars INTEGER, masterImage INTEGER, orientation, originalCaptureTime,
      originalRootEntity INTEGER, panningDistanceH, panningDistanceV, pick NOT NULL DEFAULT 0,
      positionInFolder NOT NULL DEFAULT 'z', propertiesCache, pyramidIDCache, rating,
      rootFile INTEGER NOT NULL DEFAULT 0, sidecarStatus, touchCount NOT NULL DEFAULT 0,
      touchTime NOT NULL DEFAULT 0);
    CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
      dateCreated NOT NULL DEFAULT '', genealogy NOT NULL DEFAULT '', imageCountCache DEFAULT -1,
      includeOnExport INTEGER NOT NULL DEFAULT 1, includeParents INTEGER NOT NULL DEFAULT 1,
      includeSynonyms INTEGER NOT NULL DEFAULT 1, keywordType, lastApplied, lc_name, name, parent INTEGER);
    CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER NOT NULL DEFAULT 0,
      tag INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE AgLibraryKeywordSynonym (id_local INTEGER PRIMARY KEY, keyword INTEGER NOT NULL DEFAULT 0,
      lc_name, name);
    CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, creationId NOT NULL DEFAULT '',
      genealogy NOT NULL DEFAULT '', imageCount, name NOT NULL DEFAULT '', parent INTEGER,
      systemOnly NOT NULL DEFAULT '');
    CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0,
      image INTEGER NOT NULL DEFAULT 0, pick NOT NULL DEFAULT 0, positionInCollection);
    CREATE TABLE AgLibraryCollectionContent (id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0,
      content, owningModule);
    CREATE TABLE AgLibraryIPTC (id_local INTEGER PRIMARY KEY, altTextAccessibility, caption, copyright,
      extDescrAccessibility, image INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE Adobe_AdditionalMetadata (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
      additionalInfoSet INTEGER NOT NULL DEFAULT 0, embeddedXmp INTEGER NOT NULL DEFAULT 0,
      externalXmpIsDirty INTEGER NOT NULL DEFAULT 0, image INTEGER, incrementalWhiteBalance INTEGER NOT NULL DEFAULT 0,
      internalXmpDigest, isRawFile INTEGER NOT NULL DEFAULT 0, lastSynchronizedHash,
      lastSynchronizedTimestamp NOT NULL DEFAULT -63113817600, metadataPresetID, metadataVersion,
      monochrome INTEGER NOT NULL DEFAULT 0, xmp NOT NULL DEFAULT '');
    CREATE TABLE AgHarvestedExifMetadata (id_local INTEGER PRIMARY KEY, image INTEGER, aperture,
      cameraModelRef INTEGER, cameraSNRef INTEGER, dateDay, dateMonth, dateYear, flashFired INTEGER, focalLength,
      gpsLatitude, gpsLongitude, gpsSequence NOT NULL DEFAULT 0, hasGPS INTEGER, isoSpeedRating, lensRef INTEGER,
      shutterSpeed);
    CREATE TABLE AgLibraryFolderStack (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
      collapsed INTEGER NOT NULL DEFAULT 0, text NOT NULL DEFAULT '');
    CREATE TABLE AgLibraryFolderStackImage (id_local INTEGER PRIMARY KEY, collapsed INTEGER NOT NULL DEFAULT 0,
      image INTEGER NOT NULL DEFAULT 0, position NOT NULL DEFAULT '', stack INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE Adobe_imageDevelopSettings (id_local INTEGER PRIMARY KEY, digest, hasDevelopAdjustments,
      hasDevelopAdjustmentsEx, image INTEGER, processVersion, text);
    """

    /// A new catalog at `url`, made as Lightroom leaves one it has closed: in rollback-journal mode.
    init(at url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: url.path)
        try database.execute(Self.schema)
        try database.execute("""
        INSERT INTO Adobe_variablesTable (id_global, name, value) VALUES ('v1', 'Adobe_DBVersion', '1300025');
        INSERT INTO AgLibraryKeyword (id_local, id_global, name, parent) VALUES (1, 'top', NULL, NULL);
        """)
    }

    func close() {
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Runs `body` in one transaction, as a catalog of thousands of photos is best made.
    func transaction(_ body: () throws -> Void) throws {
        try database.transaction(.immediate, body)
    }

    private func id() -> Int64 {
        next += 1
        return next
    }

    private func run(_ sql: String, _ values: [Any?]) throws {
        let statement = try database.cached(sql)
        for (place, value) in values.enumerated() {
            let at = Int32(place + 1)
            switch value {
            case let text as String: try statement.bind(text, at: at)
            case let number as Int64: try statement.bind(number, at: at)
            case let number as Int: try statement.bind(number, at: at)
            case let number as Double: try statement.bind(number, at: at)
            case let data as Data: try statement.bind(data, at: at)
            default: try statement.bindNull(at: at)
            }
        }
        try statement.run()
    }

    @discardableResult
    func root(_ path: String, name: String? = nil, relative: String? = nil) throws -> Int64 {
        let id = id()
        try run(
            "INSERT INTO AgLibraryRootFolder (id_local, id_global, absolutePath, name, relativePathFromCatalog) "
                + "VALUES (?, ?, ?, ?, ?)",
            [id, "root-\(id)", path, name ?? (path as NSString).lastPathComponent, relative],
        )
        return id
    }

    @discardableResult
    func folder(_ root: Int64, _ path: String) throws -> Int64 {
        let id = id()
        try run(
            "INSERT INTO AgLibraryFolder (id_local, id_global, pathFromRoot, rootFolder) VALUES (?, ?, ?, ?)",
            [id, "folder-\(id)", path, root],
        )
        return id
    }

    /// A photo in `folder`: its file and its image, `master` making it a virtual copy of that image.
    @discardableResult
    func photo(
        _ folder: Int64, _ name: String, rating: Int? = nil, pick: Int = 0, label: String = "",
        sidecars: String? = nil, master: Int64? = nil, copyName: String? = nil,
    ) throws -> Int64 {
        let file = id()
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        try run(
            "INSERT INTO AgLibraryFile (id_local, id_global, baseName, extension, folder, idx_filename, lc_idx_filename, "
                + "originalFilename, sidecarExtensions) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [file, "file-\(file)", stem, ext, folder, name, name.lowercased(), name, sidecars],
        )
        let image = id()
        try run(
            "INSERT INTO Adobe_images (id_local, id_global, colorLabels, copyName, masterImage, pick, rating, rootFile) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [image, "image-\(image)", label, copyName, master, pick, rating, file],
        )
        return image
    }

    @discardableResult
    func keyword(
        _ name: String, parent: Int64? = nil, includeOnExport: Bool = true, includeParents: Bool = true,
        includeSynonyms: Bool = true, type: String? = nil, synonyms: [String] = [],
    ) throws -> Int64 {
        let id = id()
        try run(
            "INSERT INTO AgLibraryKeyword (id_local, id_global, name, lc_name, parent, includeOnExport, includeParents, "
                + "includeSynonyms, keywordType) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                id,
                "keyword-\(id)",
                name,
                name.lowercased(),
                parent ?? topKeyword,
                includeOnExport ? 1 : 0,
                includeParents ? 1 : 0,
                includeSynonyms ? 1 : 0,
                type,
            ],
        )
        for synonym in synonyms {
            try run(
                "INSERT INTO AgLibraryKeywordSynonym (keyword, name, lc_name) VALUES (?, ?, ?)",
                [id, synonym, synonym.lowercased()],
            )
        }
        return id
    }

    func tag(_ photo: Int64, _ keyword: Int64) throws {
        try run("INSERT INTO AgLibraryKeywordImage (image, tag) VALUES (?, ?)", [photo, keyword])
    }

    static let collectionKind = "com.adobe.ag.library.collection"
    static let setKind = "com.adobe.ag.library.group"
    static let smartKind = "com.adobe.ag.library.smart_collection"

    @discardableResult
    func collection(
        _ name: String, kind: String = LightroomCatalogMaker.collectionKind, parent: Int64? = nil,
        system: Bool = false, photos: [Int64] = [], rules: String? = nil,
    ) throws -> Int64 {
        let id = id()
        try run(
            "INSERT INTO AgLibraryCollection (id_local, creationId, name, parent, systemOnly) VALUES (?, ?, ?, ?, ?)",
            [id, kind, name, parent, system ? "1" : ""],
        )
        for (position, photo) in photos.enumerated() {
            try run(
                "INSERT INTO AgLibraryCollectionImage (collection, image, positionInCollection) VALUES (?, ?, ?)",
                [id, photo, "\(position)"],
            )
        }
        if let rules {
            try run(
                "INSERT INTO AgLibraryCollectionContent (collection, content, owningModule) VALUES (?, ?, ?)",
                [id, rules, "ag.library.smart_collection"],
            )
        }
        return id
    }

    func iptc(_ photo: Int64, caption: String? = nil, copyright: String? = nil) throws {
        try run("INSERT INTO AgLibraryIPTC (image, caption, copyright) VALUES (?, ?, ?)", [photo, caption, copyright])
    }

    /// The photo's XMP as the catalog keeps it, with Develop settings around the fields, as text or compressed.
    func xmp(
        _ photo: Int64, title: String? = nil, creator: [String] = [], location: PhotoLocation? = nil,
        caption: String? = nil, compressed: Bool = false, settings: Int = 3,
    ) throws {
        let text = Self.packet(title: title, creator: creator, location: location, caption: caption, settings: settings)
        let value: Any = compressed ? Self.compressed(Data(text.utf8)) : text
        let id = id()
        try run(
            "INSERT INTO Adobe_AdditionalMetadata (id_local, id_global, image, xmp) VALUES (?, ?, ?, ?)",
            [id, "xmp-\(id)", photo, value],
        )
    }

    /// `settings` Develop settings around the fields: a real catalog's photos have a hundred or more.
    static func packet(
        title: String?, creator: [String], location: PhotoLocation?, caption: String?, settings: Int = 3,
    ) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var attributes = [#"crs:Version="15.5""#, #"crs:Exposure2012="+0.35""#, #"crs:Contrast2012="+12""#]
        attributes += (3 ..< max(settings, 3)).map { "crs:Setting\($0)=\"\($0 * 7 % 100)\"" }
        if let location {
            for (name, value) in [
                ("Iptc4xmpCore:Location", location.sublocation),
                ("photoshop:City", location.city),
                ("photoshop:State", location.state),
                ("photoshop:Country", location.country),
                ("Iptc4xmpCore:CountryCode", location.countryCode),
            ] {
                if let value {
                    attributes.append("\(name)=\"\(escaped(value))\"")
                }
            }
        }
        var elements: [String] = []
        if let title {
            elements
                .append(
                    #"<dc:title><rdf:Alt><rdf:li xml:lang="x-default">\#(escaped(title))</rdf:li></rdf:Alt></dc:title>"#,
                )
        }
        if let caption {
            elements.append(
                #"<dc:description><rdf:Alt><rdf:li xml:lang="x-default">\#(escaped(caption))</rdf:li></rdf:Alt></dc:description>"#,
            )
        }
        if !creator.isEmpty {
            elements.append("<dc:creator><rdf:Seq>" + creator.map { "<rdf:li>\(escaped($0))</rdf:li>" }.joined()
                + "</rdf:Seq></dc:creator>")
        }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attributes.joined(separator: " "))>
           \(elements.joined(separator: "\n   "))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// `data` compressed with zlib behind its length in four bytes, most significant first.
    static func compressed(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB,
                )
            }
        }
        output.count = written
        let length = UInt32(data.count)
        return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            + Data([0x78, 0x9C]) + output
    }

    func gps(_ photo: Int64) throws {
        try run(
            "INSERT INTO AgHarvestedExifMetadata (image, hasGPS, gpsLatitude, gpsLongitude) VALUES (?, 1, 38.7, -9.1)",
            [photo],
        )
    }

    func stack(_ photos: [Int64]) throws {
        let stack = id()
        try run("INSERT INTO AgLibraryFolderStack (id_local, id_global) VALUES (?, ?)", [stack, "stack-\(stack)"])
        for (position, photo) in photos.enumerated() {
            try run(
                "INSERT INTO AgLibraryFolderStackImage (image, position, stack) VALUES (?, ?, ?)",
                [photo, "\(position)", stack],
            )
        }
    }

    func edited(_ photo: Int64) throws {
        try run(
            "INSERT INTO Adobe_imageDevelopSettings (image, hasDevelopAdjustments, hasDevelopAdjustmentsEx) "
                + "VALUES (?, 1, 1)",
            [photo],
        )
    }
}
