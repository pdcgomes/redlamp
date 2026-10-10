import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// A Lightroom Classic catalog brought into the library (LIB-29): the report before anything is written, then
/// the import as the library's batches, each photo's sidecar written, with Undo.
struct LightroomImportTests {
    /// The library's photos in two folders, one with a sidecar of its own, and a catalog of them.
    struct Library {
        let sandbox: KeywordSandbox
        let folder: TemporaryFolder
        let catalog: URL

        var paths: LibraryPaths {
            sandbox.paths
        }

        func plan(moved: [String: URL] = [:]) async throws -> LightroomPlan {
            try await LightroomPlan.make(
                LightroomCatalog.read(catalog), index: sandbox.index, paths: paths, moved: moved,
            )
        }

        func importer(partSize: Int = LightroomImport.standardPartSize) -> LightroomImport {
            LightroomImport(index: sandbox.index, paths: paths, partSize: partSize)
        }

        func row(_ path: String) async throws -> PhotoRecord {
            let id = try await sandbox.id(path)
            return try #require(try await sandbox.index.read { try $0.photo(id: id) })
        }

        func remove() {
            sandbox.remove()
        }
    }

    static let names = [
        "2024/June/IMG_0001.CR3", "2024/June/IMG_0001.JPG", "2024/June/IMG_0002.CR3", "2024/July/IMG_0003.JPG",
        "2024/July/IMG_0004.JPG",
    ]

    static func library(root: String? = nil) async throws -> Library {
        let sandbox = try await KeywordSandbox.make()
        for name in names {
            try sandbox.photo(name)
        }
        try sandbox.sidecar("2024/July/IMG_0004.JPG", PhotoMetadata(
            rating: 3, keywords: ["Existing"], caption: "Kept caption", collections: ["Mine"],
        ))
        try await sandbox.indexAll()
        let folder = try TemporaryFolder()
        let maker = try LightroomCatalogMaker(at: folder.url.appending(path: "Lightroom Catalog.lrcat"))
        let top = try maker.root(root ?? sandbox.root.path + "/")
        let june = try maker.folder(top, "2024/June/")
        let july = try maker.folder(top, "2024/July/")
        let first = try maker.photo(june, "IMG_0001.CR3", rating: 5, pick: 1, label: "Red", sidecars: "JPG,xmp")
        let second = try maker.photo(june, "IMG_0002.CR3", pick: -1, label: "To Print")
        let third = try maker.photo(july, "IMG_0003.JPG", rating: 1, label: "Client")
        let fourth = try maker.photo(july, "IMG_0004.JPG", rating: 4)
        let gone = try maker.photo(july, "IMG_0005.JPG", rating: 2)
        try maker.photo(july, "IMG_0003.JPG", rating: 5, master: third, copyName: "Copy 1")
        let places = try maker.keyword("Places")
        let lisbon = try maker.keyword("Lisbon", parent: places, synonyms: ["Lisboa"])
        let ana = try maker.keyword("Ana", type: "person")
        try maker.keyword("Unused", parent: places)
        try maker.keyword("Hidden", includeOnExport: false)
        try maker.tag(first, lisbon)
        try maker.tag(first, ana)
        try maker.tag(fourth, lisbon)
        try maker.tag(gone, ana)
        let clients = try maker.collection("Clients", kind: LightroomCatalogMaker.setKind)
        try maker.collection("Acme", parent: clients, photos: [first, second])
        try maker.collection("Empty one", parent: clients)
        try maker.collection("Quick Collection", system: true, photos: [third])
        try maker.collection("Mine", photos: [fourth])
        try maker.collection("Top rated", kind: LightroomCatalogMaker.smartKind, rules: """
        s = { { criteria = "rating", operation = ">=", value = 4, value2 = 0, },
              { criteria = "pick", operation = "!=", value = -1, value2 = 0, }, combine = "intersect", }
        """)
        try maker.collection("Recently edited", kind: LightroomCatalogMaker.smartKind, rules: """
        s = { { criteria = "touchTime", operation = "inLast", value = 7, value2 = "days", }, combine = "intersect", }
        """)
        try maker.iptc(first, caption: "Trams at dusk", copyright: "© Ana Sousa")
        try maker.xmp(first, title: "Line 28", creator: ["Ana Sousa"], location: PhotoLocation(
            country: "Portugal", city: "Lisbon", countryCode: "PT",
        ))
        try maker.gps(second)
        maker.close()
        return Library(sandbox: sandbox, folder: folder, catalog: maker.url)
    }

    @Test func `the report says what would come across and what wouldn't, before anything is written`() async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let before = Self.names.map { library.sandbox.sidecar($0) }
        let report = try await library.plan().report
        #expect(report.photos == 5 && report.found == 4 && report.notFound == 1 && report.waiting == 0)
        #expect(report.notFoundPaths.first?.hasSuffix("2024/July/IMG_0005.JPG") == true)
        #expect(report.roots.map(\.state) == [.inLibrary] && report.roots.first?.found == 4)
        #expect(report.pairs == 1)
        #expect(report.fields.ratings == 4, "the raw, its JPEG, and two more")
        #expect(report.differing.ratings == 1, "IMG_0004 is rated 3 in the library")
        #expect(report.fields.picks == 2 && report.fields.rejects == 1 && report.fields.labels == 3)
        #expect(report.fields.customLabels == 1 && report.fields.marks == 1)
        #expect(report.fields.titles == 2 && report.fields.captions == 2 && report.fields.locations == 2)
        #expect(report.changing == 5)
        #expect(report.keywords == 5 && report.synonyms == 1 && report.people == 1 && report.notExported == 1)
        #expect(report.collections == 3 && report.sets == 1)
        #expect(report.smartMapped.map(\.query) == ["rating>=4 -flag:reject"])
        #expect(report.smartLeft.map(\.path) == ["Recently edited"])
        #expect(report.left.map(\.what).contains("virtual copies"))
        #expect(report.left.map(\.what).contains("places Lightroom's map gave photos"))
        #expect(!report.lines().isEmpty)
        #expect(Self.names.map { library.sandbox.sidecar($0) } == before, "the report writes nothing")
        #expect(!FileManager.default.fileExists(atPath: KeywordDefinitions.url(in: library.paths).path))
    }

    @Test func `the import writes each photo's fields, keywords and collections, and Undo takes it all back`(
    ) async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let sidecarsBefore = Self.names.map { library.sandbox.sidecar($0)?.metadata }
        let importer = library.importer()
        let outcome = try await importer.run(library.plan())
        #expect(outcome.record.batches.map(\.journal) == [.keywords, .metadata])
        #expect(outcome.record.photos == 5 && !outcome.record.stopped)

        let raw = try await library.row("2024/June/IMG_0001.CR3")
        #expect(raw.rating == 5 && raw.flag == .pick && raw.label == .red && raw.title == "Line 28")
        #expect(raw.caption == "Trams at dusk" && raw.creator == "Ana Sousa" && raw.copyright == "© Ana Sousa")
        #expect(raw.location?.city == "Lisbon" && raw.location?.countryCode == "PT")
        let jpeg = try await library.row("2024/June/IMG_0001.JPG")
        #expect(jpeg.rating == 5 && jpeg.flag == .pick && jpeg.label == .red, "the pair's JPEG gets the raw's fields")
        let second = try await library.row("2024/June/IMG_0002.CR3")
        #expect(second.flag == .reject && second.label == .purple, "To Print is purple in the Review Status set")
        let third = try await library.row("2024/July/IMG_0003.JPG")
        #expect(third.rating == 1 && third.customLabel == "Client" && third.marked)
        let fourth = try await library.row("2024/July/IMG_0004.JPG")
        #expect(fourth.rating == 4 && fourth.caption == "Kept caption")

        #expect(try await library.sandbox.indexed("2024/June/IMG_0001.CR3") == ["Ana", "Places/Lisbon"])
        #expect(try await library.sandbox.indexed("2024/July/IMG_0004.JPG") == ["Existing", "Places/Lisbon"])
        let sidecar = try #require(library.sandbox.sidecar("2024/June/IMG_0001.CR3"))
        #expect(sidecar.metadata?.keywords == ["Places/Lisbon", "Ana"] && sidecar.metadata?.rating == 5)
        #expect(sidecar.metadata?.collections == ["Clients/Acme"])
        let kept = try #require(library.sandbox.sidecar("2024/July/IMG_0004.JPG"))
        #expect(kept.metadata?.collections == ["Mine"] && kept.recipe[.exposure] == 0.35)
        #expect(kept.unknownFields["fromTheFuture"] == .string("kept"))

        let keywords = try await library.sandbox.keywords().definitions()
        #expect(keywords.keywords[kw("Places/Lisbon")]?.synonyms == ["Lisboa"])
        #expect(keywords.keywords[kw("Ana")]?.isPerson == true)
        #expect(keywords.keywords[kw("Hidden")]?.includeOnExport == false)
        #expect(keywords.keywords[kw("Places/Unused")] != nil, "a keyword no photo has stays in the list")
        let collections = try await LibraryMetadata(index: library.sandbox.index, paths: library.paths)
            .collections.definitions()
        #expect(collections.collections[kw("Clients")]?.kind == .set)
        #expect(collections.collections[kw("Clients/Empty one")]?.kind == .collection)
        #expect(collections.collections[kw("Top rated")]?.query == "rating>=4 -flag:reject")
        #expect(collections.collections[kw("Recently edited")] == nil)
        #expect(try await library.sandbox.search("collection:Acme") == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.CR3"])
        #expect(try await library.sandbox.search("kw:Lisboa") == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0004.JPG"])

        // Importing again changes nothing.
        let again = try await importer.run(library.plan())
        #expect(again.record.batches.isEmpty && again.written == 0)

        try await importer.undo()
        #expect(Self.names.map { library.sandbox.sidecar($0)?.metadata } == sidecarsBefore)
        let undone = try await library.row("2024/June/IMG_0001.CR3")
        #expect(undone.rating == 0 && undone.flag == nil && undone.label == nil && undone.title == nil)
        #expect(try await library.row("2024/July/IMG_0004.JPG").rating == 3)
        #expect(try await library.sandbox.indexed("2024/June/IMG_0001.CR3").isEmpty)
        #expect(try await library.sandbox.indexed("2024/July/IMG_0004.JPG") == ["Existing"])
        #expect(try await library.sandbox.keywords().definitions().keywords.isEmpty)
        let left = try await LibraryMetadata(index: library.sandbox.index, paths: library.paths).collections
            .definitions()
        #expect(left.collections.isEmpty)
        await #expect(throws: LightroomImportError.nothingToUndo) { try await importer.undo() }
    }

    @Test func `a root that moved is found where the user says, and one the library lacks is added first`(
    ) async throws {
        let library = try await Self.library(root: "D:/Photos/Archive/")
        defer { library.remove() }
        let missing = try await library.plan().report
        #expect(missing.roots.map(\.state) == [.missing] && missing.unlocated == 5 && missing.found == 0)
        let moved = try await library.plan(moved: ["D:/Photos/Archive/": library.sandbox.root])
        #expect(moved.report.roots.first?.moved == true && moved.report.found == 4)

        let elsewhere = try TemporaryFolder()
        try FileManager.default.createDirectory(
            at: elsewhere.url.appending(path: "2024/June"), withIntermediateDirectories: true,
        )
        let notAdded = try await library.plan(moved: ["D:/Photos/Archive/": elsewhere.url])
        #expect(notAdded.report.roots.map(\.state) == [.notInLibrary] && notAdded.report.waiting == 5)
        #expect(notAdded.foldersToAdd.map(\.path) == [LibraryIndexer.path(elsewhere.url)])
    }

    @Test func `a root in a library folder whose disk isn't connected is offline, one that's gone is missing`(
    ) async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let offline = "/Volumes/Not Connected \(UUID().uuidString)/Photos"
        try await library.sandbox.index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "OFFLINE-\(UUID())", name: "Gone", kind: .ssd))
            _ = try writer.upsertRoot(RootRecord(volume: volume, path: offline))
        }
        let maker = try LightroomCatalogMaker(at: library.folder.url.appending(path: "Two roots.lrcat"))
        let first = try maker.root(offline + "/Trip/")
        try maker.photo(maker.folder(first, ""), "A.JPG", rating: 3)
        let second = try maker.root(library.sandbox.root.path + "/Deleted/")
        try maker.photo(maker.folder(second, ""), "B.JPG", rating: 3)
        maker.close()
        let report = try await LightroomPlan.make(
            LightroomCatalog.read(maker.url), index: library.sandbox.index, paths: library.paths,
        ).report
        #expect(report.roots.map(\.state) == [.offline, .missing])
        #expect(report.offline == 1 && report.unlocated == 1 && report.found == 0)
    }

    @Test func `an import in parts stops between them, and Undo takes back the parts it made`() async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let importer = library.importer(partSize: 2)
        let progress = ProgressLog()
        let plan = try await library.plan()
        let outcome = try await importer.run(plan, progress: { progress.add($0) }, stop: { progress.count > 0 })
        #expect(outcome.record.stopped)
        #expect(!outcome.record.batches.isEmpty && outcome.record.batches.count <= 2, "the first part's batches")
        #expect(progress.last?.parts == 3 && progress.last?.total == 5)
        let rows = try await library.sandbox.index
            .read { reader in try plan.photos.map { try reader.photo(id: $0.id) } }
        let ratings = plan.photos.map(\.values.rating)
        #expect(rows.prefix(2).map { $0?.rating } == ratings.prefix(2).map(\.self), "the first part's photos")
        #expect(rows.dropFirst(2).map { $0?.rating } != ratings.dropFirst(2).map(\.self), "the parts that didn't run")
        #expect(try importer.lastImport()?.id == outcome.record.id)
        try await importer.undo()
        let undone = try await library.sandbox.index
            .read { reader in try plan.photos.map { try reader.photo(id: $0.id) } }
        #expect(undone.prefix(2).allSatisfy { $0?.rating == 0 })
    }

    @Test func `a collection at a place the library gives another kind of thing is renamed`() async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let metadata = LibraryMetadata(index: library.sandbox.index, paths: library.paths)
        try await metadata.collections.apply(.smart(kw("Clients"), query: "rating:5"))
        let plan = try await library.plan()
        #expect(plan.report.renamed == ["Clients": "Clients (Lightroom)"])
        try await library.importer().run(plan)
        let definitions = try await metadata.collections.definitions()
        #expect(definitions.collections[kw("Clients")]?.kind == .smart)
        #expect(definitions.collections[kw("Clients (Lightroom)")]?.kind == .set)
        #expect(library.sandbox.sidecar("2024/June/IMG_0002.CR3")?.metadata?
            .collections == ["Clients (Lightroom)/Acme"])
    }
}

/// The progress an import reported, from any thread.
final class ProgressLog: Sendable {
    private let entries = Mutex<[LightroomImport.Progress]>([])

    func add(_ progress: LightroomImport.Progress) {
        entries.withLock { $0.append(progress) }
    }

    var count: Int {
        entries.withLock { $0.count }
    }

    var last: LightroomImport.Progress? {
        entries.withLock { $0.last }
    }
}
