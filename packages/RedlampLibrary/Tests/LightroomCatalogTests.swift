import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Reading a Lightroom Classic catalog (LIB-29): its own tables, opened read-only and immutable and never
/// written, a catalog Lightroom has open refused and one it didn't close read from a copy.
struct LightroomCatalogTests {
    /// A catalog of one root with two folders: rated, picked, rejected and labelled photos, keywords in a
    /// hierarchy with synonyms and export options, collections in a set, a smart collection, the Quick
    /// Collection, IPTC fields, XMP as text and compressed, a virtual copy, a stack and an edit.
    static func catalog(in folder: URL, root: String = "/Volumes/Photos/Archive/") throws -> LightroomCatalogMaker {
        let maker = try LightroomCatalogMaker(at: folder.appending(path: "Catalog/Lightroom Catalog.lrcat"))
        let top = try maker.root(root)
        let june = try maker.folder(top, "2024/June/")
        let july = try maker.folder(top, "2024/July/")
        let first = try maker.photo(june, "IMG_0001.CR3", rating: 5, pick: 1, label: "Red", sidecars: "JPG")
        let second = try maker.photo(june, "IMG_0002.CR3", rating: 2, pick: -1, label: "Approved")
        let third = try maker.photo(july, "IMG_0003.JPG", label: "Client")
        try maker.photo(july, "IMG_0003.JPG", master: third, copyName: "Black and white")
        let places = try maker.keyword("Places")
        let portugal = try maker.keyword("Portugal", parent: places)
        let lisbon = try maker.keyword("Lisbon", parent: portugal, synonyms: ["Lisboa"])
        let ana = try maker.keyword("Ana", type: "person")
        try maker.keyword("Private", includeOnExport: false, includeParents: false, includeSynonyms: false)
        try maker.tag(first, lisbon)
        try maker.tag(first, ana)
        try maker.tag(second, portugal)
        let clients = try maker.collection("Clients", kind: LightroomCatalogMaker.setKind)
        try maker.collection("Acme", parent: clients, photos: [first, second])
        try maker.collection("Quick Collection", system: true, photos: [third])
        try maker.collection("Five stars", kind: LightroomCatalogMaker.smartKind, rules: """
        s = { { criteria = "rating", operation = "==", value = 5, value2 = 0, }, combine = "intersect", }
        """)
        try maker.iptc(first, caption: "Trams at dusk", copyright: "© Ana Sousa")
        try maker.xmp(first, title: "Line 28", creator: ["Ana Sousa", "Rui"], location: PhotoLocation(
            country: "Portugal", city: "Lisbon", sublocation: "Alfama", countryCode: "PT",
        ))
        try maker.xmp(second, title: "Compressed", compressed: true)
        try maker.gps(second)
        try maker.stack([first, second])
        try maker.edited(first)
        maker.close()
        return maker
    }

    @Test func `the catalog's folders, photos, fields, keywords and collections are read from its tables`() throws {
        let folder = try TemporaryFolder()
        let maker = try Self.catalog(in: folder.url)
        let catalog = try LightroomCatalog.read(maker.url)
        #expect(catalog.version == "1300025")
        #expect(catalog.roots.map(\.path) == ["/Volumes/Photos/Archive/"])
        #expect(Set(catalog.folders.values.map(\.path)) == ["2024/June/", "2024/July/"])
        #expect(catalog.photos.map(\.name) == ["IMG_0001.CR3", "IMG_0002.CR3", "IMG_0003.JPG"])
        let (first, second, third) = (catalog.photos[0], catalog.photos[1], catalog.photos[2])
        #expect(first.rating == 5 && first.flag == .pick && first.label == "Red" && first.sidecarExtensions == ["JPG"])
        #expect(second.rating == 2 && second.flag == .reject && second.label == "Approved")
        #expect(third.rating == 0 && third.flag == nil && third.label == "Client")
        #expect(catalog.virtualCopies.map(\.name) == ["Black and white"])
        #expect(catalog.virtualCopies.first?.master == third.id)

        #expect(first.caption == "Trams at dusk" && first.copyright == "© Ana Sousa" && first.title == "Line 28")
        #expect(first.creator == "Ana Sousa; Rui")
        #expect(first.location == PhotoLocation(
            country: "Portugal",
            city: "Lisbon",
            sublocation: "Alfama",
            countryCode: "PT",
        ))
        #expect(second.title == "Compressed", "the XMP compressed with zlib")
        #expect(second.hasGPS && !first.hasGPS)

        let names = catalog.keywords.values.compactMap(\.name).sorted()
        #expect(names == ["Ana", "Lisbon", "Places", "Portugal", "Private"])
        let lisbon = try #require(catalog.keywords.values.first { $0.name == "Lisbon" })
        #expect(lisbon.synonyms == ["Lisboa"])
        #expect(catalog.keywords.values.first { $0.name == "Ana" }?.isPerson == true)
        let hidden = try #require(catalog.keywords.values.first { $0.name == "Private" })
        #expect(!hidden.includeOnExport && !hidden.exportContainingKeywords && !hidden.exportSynonyms)
        #expect(first.keywords.count == 2 && second.keywords.count == 1 && third.keywords.isEmpty)

        let collections = Dictionary(uniqueKeysWithValues: catalog.collections.values.map { ($0.name, $0) })
        #expect(collections["Clients"]?.kind == .set)
        #expect(collections["Acme"]?.kind == .collection && collections["Acme"]?.photos == [first.id, second.id])
        #expect(collections["Acme"]?.parent == collections["Clients"]?.id)
        #expect(collections["Quick Collection"]?.kind == .quick)
        #expect(collections["Five stars"]?.kind == .smart && collections["Five stars"]?.rules?
            .contains("rating") == true)
        #expect(catalog.stacks == 1 && catalog.edited == 1)
        #expect(catalog.notes.isEmpty)
    }

    @Test func `reading never writes the catalog, nor leaves anything beside it`() throws {
        let folder = try TemporaryFolder()
        let maker = try Self.catalog(in: folder.url)
        let beside = maker.url.deletingLastPathComponent()
        let before = try Data(contentsOf: maker.url)
        let modified = try FileManager.default.attributesOfItem(atPath: maker.url.path)[.modificationDate] as? Date
        let files = try FileManager.default.contentsOfDirectory(atPath: beside.path).sorted()
        _ = try LightroomCatalog.read(maker.url)
        #expect(try Data(contentsOf: maker.url) == before)
        #expect(try FileManager.default
            .attributesOfItem(atPath: maker.url.path)[.modificationDate] as? Date == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: beside.path).sorted() == files)
    }

    @Test func `a catalog Lightroom has open is refused, and one it didn't close is read from a copy`() throws {
        let folder = try TemporaryFolder()
        let maker = try Self.catalog(in: folder.url)
        let lock = LightroomCatalog.lockURL(of: maker.url)
        #expect(lock.lastPathComponent == "Lightroom Catalog.lrcat.lock")
        try Data().write(to: lock)
        #expect(throws: LightroomCatalogError.openInLightroom(maker.url.path)) { try LightroomCatalog.read(maker.url) }
        try FileManager.default.removeItem(at: lock)

        // A catalog left in write-ahead mode with changes still in its log, as a crash leaves it.
        let copy = folder.url.appending(path: "Crashed/Lightroom Catalog.lrcat")
        try Self.leaveLog(from: maker.url, at: copy, renaming: "IMG_0002.CR3", to: "IMG_0009.CR3")
        let log = URL(fileURLWithPath: copy.path + "-wal")
        #expect(((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) > 0)
        let logBefore = try Data(contentsOf: log)
        let catalogBefore = try Data(contentsOf: copy)
        let catalog = try LightroomCatalog.read(copy)
        #expect(catalog.photos.map(\.name).contains("IMG_0009.CR3"), "the log's change is read")
        #expect(catalog.notes.contains { $0.contains("read from a copy") })
        #expect(try Data(contentsOf: log) == logBefore && Data(contentsOf: copy) == catalogBefore)
    }

    /// `source` at `target` with a change in write-ahead mode still in its log, as Lightroom leaves a catalog
    /// it stopped without closing: the change is made in a scratch copy, and the copy and its log copied while
    /// it's open, since closing it would move the log's changes into the catalog.
    static func leaveLog(from source: URL, at target: URL, renaming name: String, to newName: String) throws {
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = folder.appending(path: "scratch.lrcat")
        try FileManager.default.copyItem(at: source, to: scratch)
        let database = try SQLiteDatabase(path: scratch.path)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA wal_autocheckpoint=0")
        try database.execute("UPDATE AgLibraryFile SET idx_filename = '\(newName)' WHERE idx_filename = '\(name)'")
        try withExtendedLifetime(database) {
            try FileManager.default.copyItem(at: scratch, to: target)
            try FileManager.default.copyItem(atPath: scratch.path + "-wal", toPath: target.path + "-wal")
        }
    }

    @Test func `a file that isn't a catalog, and one that isn't there, say so`() throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "notes.lrcat")
        try Data("not a database at all, just some text that's long enough to have a header".utf8).write(to: text)
        #expect(throws: LightroomCatalogError.notACatalog(text.path)) { try LightroomCatalog.read(text) }
        let other = folder.url.appending(path: "other.lrcat")
        let database = try SQLiteDatabase(path: other.path)
        try database.execute("CREATE TABLE photos (id INTEGER PRIMARY KEY)")
        #expect(throws: LightroomCatalogError.notACatalog(other.path)) { try LightroomCatalog.read(other) }
        let missing = folder.url.appending(path: "missing.lrcat")
        #expect(throws: LightroomCatalogError.noSuchFile(missing.path)) { try LightroomCatalog.read(missing) }
    }

    @Test func `a catalog without some tables or columns is still read, and its notes say what it lacked`() throws {
        let folder = try TemporaryFolder()
        let maker = try Self.catalog(in: folder.url)
        let database = try SQLiteDatabase(path: maker.url.path)
        try database.execute("DROP TABLE AgLibraryKeywordSynonym; DROP TABLE Adobe_AdditionalMetadata")
        try database.execute("ALTER TABLE Adobe_images DROP COLUMN colorLabels")
        let catalog = try LightroomCatalog.read(maker.url)
        #expect(catalog.photos.count == 3)
        #expect(catalog.photos.allSatisfy { $0.label == nil && $0.title == nil })
        #expect(catalog.photos[0].caption == "Trams at dusk")
        #expect(catalog.notes.count == 3, "\(catalog.notes)")
    }

    @Test func `a path with characters a URI escapes opens as itself`() throws {
        let folder = try TemporaryFolder()
        let maker = try LightroomCatalogMaker(at: folder.url.appending(path: "Odd #1 ?%/Cat 50% off.lrcat"))
        let root = try maker.root("/Photos/")
        try maker.photo(maker.folder(root, ""), "A.JPG")
        maker.close()
        #expect(try LightroomCatalog.read(maker.url).photos.map(\.name) == ["A.JPG"])
        #expect(LightroomCatalog.immutableURI("/a b/#?%.lrcat") == "file:/a%20b/%23%3F%25.lrcat?mode=ro&immutable=1")
    }
}
