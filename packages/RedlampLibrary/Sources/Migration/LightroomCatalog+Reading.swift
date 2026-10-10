import Foundation
import RedlampDocument
import Synchronization

/// Reads a catalog's tables into a `LightroomCatalog`, looking each table and column up first.
struct LightroomCatalogReader {
    let database: SQLiteDatabase
    /// The catalog's tables, by their names in lower case: SQLite matches names ignoring case.
    private let tables: Set<String>

    init(_ database: SQLiteDatabase) throws {
        self.database = database
        tables = try Set(database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map {
            ($0.string(at: 0) ?? "").lowercased()
        })
    }

    func has(_ table: String) -> Bool {
        tables.contains(table.lowercased())
    }

    /// The table's columns, in lower case.
    func columns(_ table: String) throws -> Set<String> {
        guard has(table) else { return [] }
        return try Set(database.prepare("PRAGMA table_info(\(table))").map { ($0.string(at: 1) ?? "").lowercased() })
    }

    func read(url: URL) throws -> LightroomCatalog {
        var catalog = LightroomCatalog(url: url)
        catalog.version = try version()
        catalog.roots = try roots()
        catalog.folders = try folders()
        var notes: [String] = []
        var (photos, copies) = try photos(notes: &notes)
        var places: [Int64: Int] = [:]
        for (place, photo) in photos.enumerated() {
            places[photo.id] = place
        }
        try readIPTC(into: &photos, places: places, notes: &notes)
        try readXMP(into: &photos, places: places, notes: &notes)
        try readGPS(into: &photos, places: places)
        catalog.keywords = try keywords(notes: &notes)
        try readKeywordLinks(into: &photos, places: places, keywords: catalog.keywords)
        catalog.collections = try collections(notes: &notes)
        catalog.photos = photos
        copies.sort { $0.id < $1.id }
        catalog.virtualCopies = copies
        catalog.stacks = try stackCount()
        catalog.edited = try editedCount()
        catalog.notes = notes
        return catalog
    }

    // MARK: - The catalog, its folders and photos

    private func version() throws -> String? {
        guard try columns("Adobe_variablesTable").isSuperset(of: ["name", "value"]) else { return nil }
        return try database.prepare("SELECT value FROM Adobe_variablesTable WHERE name = 'Adobe_DBVersion'")
            .first { $0.string(at: 0) } ?? nil
    }

    private func roots() throws -> [LightroomCatalog.Root] {
        let columns = try columns("AgLibraryRootFolder")
        guard columns.contains("absolutepath") else { return [] }
        let name = columns.contains("name") ? "name" : "NULL"
        let relative = columns.contains("relativepathfromcatalog") ? "relativePathFromCatalog" : "NULL"
        return try database.prepare("""
        SELECT id_local, absolutePath, \(name), \(relative) FROM AgLibraryRootFolder ORDER BY id_local
        """).map { row in
            let path = row.string(at: 1) ?? ""
            let fallback = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            return LightroomCatalog.Root(
                id: row.int64(at: 0), name: row.string(at: 2).flatMap(Self.text) ?? fallback, path: path,
                relativePath: row.string(at: 3).flatMap(Self.text),
            )
        }
    }

    private func folders() throws -> [Int64: LightroomCatalog.Folder] {
        var folders: [Int64: LightroomCatalog.Folder] = [:]
        try database.prepare("SELECT id_local, rootFolder, pathFromRoot FROM AgLibraryFolder").forEachRow { row in
            let id = row.int64(at: 0)
            folders[id] = LightroomCatalog.Folder(id: id, root: row.int64(at: 1), path: row.string(at: 2) ?? "")
        }
        return folders
    }

    /// Every photo with its file, and the virtual copies apart.
    private func photos(notes: inout [String]) throws -> ([LightroomCatalog.Photo], [LightroomCatalog.VirtualCopy]) {
        let images = try columns("Adobe_images")
        let files = try columns("AgLibraryFile")
        func image(_ column: String) -> String {
            images.contains(column.lowercased()) ? "i.\(column)" : "NULL"
        }
        let name = files.contains("idx_filename") ? "f.idx_filename"
            : files.isSuperset(of: ["basename", "extension"]) ? "f.baseName || '.' || f.extension" : "NULL"
        let sidecars = files.contains("sidecarextensions") ? "f.sidecarExtensions" : "NULL"
        for (column, what) in [("rating", "ratings"), ("pick", "picks"), ("colorLabels", "labels")]
            where !images.contains(column.lowercased()) {
            notes.append("Adobe_images has no \(column): no \(what) came from it")
        }
        let statement = try database.prepare("""
        SELECT i.id_local, f.folder, \(name), \(sidecars), \(image("rating")), \(image("pick")),
          \(image("colorLabels")), \(image("masterImage")), \(image("copyName"))
        FROM Adobe_images i JOIN AgLibraryFile f ON f.id_local = i.rootFile ORDER BY i.id_local
        """)
        var photos: [LightroomCatalog.Photo] = []
        var copies: [LightroomCatalog.VirtualCopy] = []
        try statement.forEachRow { row in
            let id = row.int64(at: 0)
            if let master = row.optionalInt64(at: 7), master != id {
                copies.append(LightroomCatalog.VirtualCopy(id: id, master: master, name: row.string(at: 8)))
                return
            }
            var photo = LightroomCatalog.Photo(id: id, folder: row.int64(at: 1), name: row.string(at: 2) ?? "")
            photo.sidecarExtensions = (row.string(at: 3) ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            photo.rating = min(max(Int(row.optionalDouble(at: 4)?.rounded() ?? 0), 0), 5)
            switch row.optionalDouble(at: 5).map({ Int($0.rounded()) }) {
            case 1: photo.flag = .pick
            case -1: photo.flag = .reject
            default: break
            }
            photo.label = row.string(at: 6).flatMap(Self.text)
            photos.append(photo)
        }
        return (photos, copies)
    }

    /// Captions, copyright notices and, where the catalog keeps them there, titles.
    private func readIPTC(
        into photos: inout [LightroomCatalog.Photo], places: [Int64: Int], notes: inout [String],
    ) throws {
        let columns = try columns("AgLibraryIPTC")
        guard columns.contains("image") else {
            notes.append("the catalog has no AgLibraryIPTC: captions and copyright notices came from its XMP")
            return
        }
        let wanted = ["caption", "copyright", "title"]
        let present = wanted.map { columns.contains($0) ? $0 : "NULL" }
        try database.prepare("SELECT image, \(present.joined(separator: ", ")) FROM AgLibraryIPTC").forEachRow { row in
            guard let place = places[row.int64(at: 0)] else { return }
            if let caption = row.string(at: 1).flatMap(Self.text) {
                photos[place].caption = caption
            }
            if let copyright = row.string(at: 2).flatMap(Self.text) {
                photos[place].copyright = copyright
            }
            if let title = row.string(at: 3).flatMap(Self.text) {
                photos[place].title = title
            }
        }
    }

    /// Titles, creators and locations, and captions and copyright notices AgLibraryIPTC lacks, from the XMP the
    /// catalog keeps for each photo, read on every core: only packets naming one of those fields are parsed.
    private func readXMP(
        into photos: inout [LightroomCatalog.Photo], places: [Int64: Int], notes: inout [String],
    ) throws {
        guard try columns("Adobe_AdditionalMetadata").isSuperset(of: ["image", "xmp"]) else {
            notes.append("the catalog has no XMP in Adobe_AdditionalMetadata: no titles, creators or locations came "
                + "from it")
            return
        }
        var read: [(place: Int, data: Data)] = []
        try database.prepare("SELECT image, xmp FROM Adobe_AdditionalMetadata").forEachRow { row in
            guard let place = places[row.int64(at: 0)], let data = row.data(at: 1), !data.isEmpty else { return }
            read.append((place, data))
        }
        let packets = read
        let found = Mutex<[(place: Int, fields: XMPFields)]>([])
        let unreadable = Mutex(0)
        let parts = max(1, min(packets.count / 256, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: parts) { part in
            var mine: [(place: Int, fields: XMPFields)] = []
            var failed = 0
            for index in stride(from: part, to: packets.count, by: parts) {
                switch LightroomXMP.read(packets[index].data) {
                case let .fields(fields): mine.append((packets[index].place, fields))
                case .nothing: break
                case .unreadable: failed += 1
                }
            }
            found.withLock { $0.append(contentsOf: mine) }
            unreadable.withLock { $0 += failed }
        }
        for (place, fields) in found.withLock({ $0 }) {
            photos[place].title = photos[place].title ?? fields.title
            photos[place].creator = fields.creator
            photos[place].location = fields.location.flatMap { $0.isEmpty ? nil : $0 }
            photos[place].caption = photos[place].caption ?? fields.caption
            photos[place].copyright = photos[place].copyright ?? fields.copyright
        }
        let failures = unreadable.withLock { $0 }
        if failures > 0 {
            notes.append("\(failures) photos' XMP in the catalog couldn't be read: their titles, creators and "
                + "locations didn't come across")
        }
    }

    private func readGPS(into photos: inout [LightroomCatalog.Photo], places: [Int64: Int]) throws {
        let columns = try columns("AgHarvestedExifMetadata")
        guard columns.contains("image") else { return }
        let condition = columns.contains("hasgps") ? "hasGPS = 1"
            : columns.contains("gpslatitude") ? "gpsLatitude IS NOT NULL" : nil
        guard let condition else { return }
        try database.prepare("SELECT image FROM AgHarvestedExifMetadata WHERE \(condition)").forEachRow { row in
            if let place = places[row.int64(at: 0)] {
                photos[place].hasGPS = true
            }
        }
    }

    // MARK: - Keywords

    private func keywords(notes: inout [String]) throws -> [Int64: LightroomCatalog.Keyword] {
        let columns = try columns("AgLibraryKeyword")
        guard columns.contains("name") else { return [:] }
        func flag(_ column: String) -> String {
            columns.contains(column.lowercased()) ? column : "1"
        }
        let type = columns.contains("keywordtype") ? "keywordType" : "NULL"
        var keywords: [Int64: LightroomCatalog.Keyword] = [:]
        try database.prepare("""
        SELECT id_local, parent, name, \(flag("includeOnExport")), \(flag("includeParents")),
          \(flag("includeSynonyms")), \(type) FROM AgLibraryKeyword
        """).forEachRow { row in
            let id = row.int64(at: 0)
            keywords[id] = LightroomCatalog.Keyword(
                id: id, parent: row.optionalInt64(at: 1), name: row.string(at: 2).flatMap(Self.text),
                includeOnExport: row.int(at: 3) != 0, exportContainingKeywords: row.int(at: 4) != 0,
                exportSynonyms: row.int(at: 5) != 0, isPerson: row.string(at: 6)?.lowercased() == "person",
            )
        }
        if try self.columns("AgLibraryKeywordSynonym").isSuperset(of: ["keyword", "name"]) {
            try database.prepare("SELECT keyword, name FROM AgLibraryKeywordSynonym ORDER BY id_local")
                .forEachRow { row in
                    if let name = row.string(at: 1).flatMap(Self.text) {
                        keywords[row.int64(at: 0)]?.synonyms.append(name)
                    }
                }
        } else if !keywords.isEmpty {
            notes.append("the catalog has no AgLibraryKeywordSynonym: no synonyms came from it")
        }
        return keywords
    }

    private func readKeywordLinks(
        into photos: inout [LightroomCatalog.Photo], places: [Int64: Int], keywords: [Int64: LightroomCatalog.Keyword],
    ) throws {
        guard try columns("AgLibraryKeywordImage").isSuperset(of: ["image", "tag"]) else { return }
        try database.prepare("SELECT image, tag FROM AgLibraryKeywordImage ORDER BY id_local").forEachRow { row in
            let tag = row.int64(at: 1)
            if let place = places[row.int64(at: 0)], keywords[tag]?.name != nil {
                photos[place].keywords.append(tag)
            }
        }
    }

    // MARK: - Collections

    static let setID = "com.adobe.ag.library.group"
    static let collectionID = "com.adobe.ag.library.collection"
    static let smartID = "com.adobe.ag.library.smart_collection"
    static let smartModule = "ag.library.smart_collection"

    private func collections(notes: inout [String]) throws -> [Int64: LightroomCatalog.Collection] {
        let columns = try columns("AgLibraryCollection")
        guard columns.contains("name") else { return [:] }
        let creation = columns.contains("creationid") ? "creationId" : "NULL"
        let system = columns.contains("systemonly") ? "systemOnly" : "NULL"
        var collections: [Int64: LightroomCatalog.Collection] = [:]
        try database.prepare("SELECT id_local, parent, name, \(creation), \(system) FROM AgLibraryCollection")
            .forEachRow { row in
                let id = row.int64(at: 0)
                let name = row.string(at: 2) ?? ""
                let creationID = row.string(at: 3) ?? Self.collectionID
                let systemOnly = (row.string(at: 4) ?? "").trimmingCharacters(in: .whitespaces)
                let isSystem = !systemOnly.isEmpty && systemOnly != "0"
                let kind: LightroomCatalog.Collection.Kind = switch creationID {
                case Self.setID: .set
                case Self.smartID: .smart
                case Self.collectionID where isSystem && name.lowercased() == "quick collection": .quick
                case Self.collectionID where !isSystem: .collection
                default: isSystem ? .system(creationID) : .output(creationID)
                }
                collections[id] = LightroomCatalog.Collection(
                    id: id, parent: row.optionalInt64(at: 1), name: name, kind: kind,
                )
            }
        if try self.columns("AgLibraryCollectionImage").isSuperset(of: ["collection", "image"]) {
            let order = try self.columns("AgLibraryCollectionImage").contains("positionincollection")
                ? "positionInCollection, id_local" : "id_local"
            try database.prepare("SELECT collection, image FROM AgLibraryCollectionImage ORDER BY \(order)")
                .forEachRow { row in
                    collections[row.int64(at: 0)]?.photos.append(row.int64(at: 1))
                }
        }
        if try self.columns("AgLibraryCollectionContent").isSuperset(of: ["collection", "content", "owningmodule"]) {
            let statement = try database.prepare(
                "SELECT collection, content FROM AgLibraryCollectionContent WHERE owningModule = ?",
            )
            try statement.bind(Self.smartModule, at: 1)
            try statement.forEachRow { row in
                collections[row.int64(at: 0)]?.rules = row.string(at: 1)
            }
        } else if collections.values.contains(where: { $0.kind == .smart }) {
            notes.append("the catalog has no AgLibraryCollectionContent: its smart collections' rules couldn't be read")
        }
        return collections
    }

    // MARK: - Counted for the report

    private func stackCount() throws -> Int {
        guard try columns("AgLibraryFolderStackImage").contains("stack") else { return 0 }
        return try database.prepare("""
        SELECT COUNT(*) FROM (SELECT stack FROM AgLibraryFolderStackImage GROUP BY stack HAVING COUNT(*) > 1)
        """).first { $0.int(at: 0) } ?? 0
    }

    private func editedCount() throws -> Int {
        let columns = try columns("Adobe_imageDevelopSettings")
        let column = columns.contains("hasdevelopadjustmentsex") ? "hasDevelopAdjustmentsEx"
            : columns.contains("hasdevelopadjustments") ? "hasDevelopAdjustments" : nil
        guard let column, columns.contains("image") else { return 0 }
        return try database.prepare("""
        SELECT COUNT(DISTINCT image) FROM Adobe_imageDevelopSettings WHERE \(column) > 0
        """).first { $0.int(at: 0) } ?? 0
    }

    /// `text` without spaces at its ends; nil when that leaves nothing.
    static func text(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
