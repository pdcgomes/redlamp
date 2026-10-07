import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The column store's snapshot beside the index (LIB-44).
struct ColumnSnapshotTests {
    @Test func `the snapshot is written after commits and at quit, atomically`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let url = ColumnSnapshot.url(forIndex: library.index.url)
        let engine = QueryEngine(
            index: library.index, timeZone: .gmt, now: { QueryTestLibrary.now },
            saving: .init(quiet: .milliseconds(50), longest: .seconds(5)),
        )
        func generation() async throws -> IndexGeneration {
            try await library.index.read { try $0.generation() }
        }
        func waitForSnapshot(of expected: IndexGeneration) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while try SnapshotHeader.read(url)?.generation != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try SnapshotHeader.read(url)?.generation == expected)
        }
        func reopened() async throws -> QueryEngine {
            let next = QueryEngine(index: library.index, timeZone: .gmt, now: { QueryTestLibrary.now }, saving: nil)
            try await next.load()
            return next
        }

        try await engine.load()
        try await waitForSnapshot(of: generation())
        let first = try SnapshotHeader.inode(url)

        try await library.index.write { try $0.setOrganising([.rating(4)], forPhotos: [library.ids[7]]) }
        try await engine.update(photos: [library.ids[7]])
        try await waitForSnapshot(of: generation())
        #expect(try SnapshotHeader.inode(url) != first, "a new file renamed over the last")
        #expect(try await library.numbers(reopened().ids("rating:4")).sorted() == [5, 8])

        try await library.index.write { try $0.setOrganising([.flag(.pick)], forPhotos: [library.ids[6]]) }
        try await engine.saveSnapshot()
        #expect(try await SnapshotHeader.read(url)?.generation == generation(), "at quit")
        #expect(try await library.numbers(reopened().ids("flag:pick")).sorted() == [1, 7], "a change no update named")

        let changed = try SnapshotHeader.inode(url)
        try await library.index.write { try $0.setLastEvent(42, eventDatabase: nil, forVolume: library.sandbox.volume) }
        try await engine.saveSnapshot()
        #expect(try await SnapshotHeader.read(url)?.generation == generation(), "only its header written again")
        #expect(try SnapshotHeader.inode(url) == changed, "in place")
        #expect(try await library.numbers(reopened().ids("flag:pick")).sorted() == [1, 7])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func `a write by another process leaves the snapshot to be set aside, never saved over`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let url = ColumnSnapshot.url(forIndex: library.index.url)
        let engine = QueryEngine(index: library.index, timeZone: .gmt, now: { QueryTestLibrary.now }, saving: nil)
        try await engine.load()
        try await engine.saveSnapshot()
        let saved = try #require(try SnapshotHeader.read(url)).generation

        let other = try await LibraryIndex.open(at: library.index.url, readers: 1)
        try await other.write { try $0.setOrganising([.rating(1)], forPhotos: [library.ids[2]]) }
        await other.close()
        try await library.index.write { try $0.setOrganising([.rating(2)], forPhotos: [library.ids[6]]) }
        try await engine.update(photos: [library.ids[6]])
        #expect(engine.reflects == nil, "the other process's write leaves a gap")
        try await engine.saveSnapshot()
        #expect(try SnapshotHeader.read(url)?.generation == saved, "nothing saved")

        let launched = QueryEngine(index: library.index, timeZone: .gmt, now: { QueryTestLibrary.now }, saving: nil)
        try await launched.load()
        #expect(!launched.isMapped)
        #expect(try await library.numbers(launched.ids("rating:1..2")).sorted() == [3, 4, 6, 7])
    }
}

/// A library for comparing stores: photos over 20 years from eight cameras in six folders, with
/// creators, places, custom labels, keywords, collections, edits, portraits, and raw and JPEG pairs.
struct SnapshotLibrary {
    let sandbox: IndexSandbox
    let ids: [Int64]

    var index: LibraryIndex {
        sandbox.index
    }

    static let queries = [
        "rating>=3", "flag:pick", "-flag:reject", "label:red", "label:Hero", "camera:Canon", "lens:35", "iso<=800",
        "f:1.4..2.8", "focal:24..70", "date:2010..2015", "in:Algarve", "type:raw", "kw:Places", "collection:Portfolio",
        "has:gps", "creator:Silva", "city:Lisboa", "country:Portugal", "megapixels>=20", "orientation:portrait",
        "is:low-light", "edited:yes", "tram", "li", "DSC", "rating:0 camera:Nikon OR label:Client",
    ]
    static let sorts = QuerySort.Key.allCases.flatMap { [QuerySort($0), QuerySort($0, ascending: false)] }

    static func make(photos count: Int, extras: Bool = true) async throws -> SnapshotLibrary {
        let sandbox = try await IndexSandbox.make()
        let folders = try await Array(sandbox.addFolders([
            "2019", "2019/Algarve", "2024", "2024/Lisbon Trip", "Clients", "Clients/Acme",
        ]).values).sorted()
        var ids: [Int64] = []
        var number = 0
        while number < count {
            let batch = min(1000, count - number)
            let first = number
            ids += try await sandbox.index.write { writer in
                let cameras = try SyntheticIndexPhotos.cameras.prefix(8).map { try writer.cameraID(for: $0) }
                let lenses = try SyntheticIndexPhotos.lenses.prefix(8).map { try writer.lensID(for: $0) }
                var synthetic = SyntheticIndexPhotos(seed: UInt64(first + 1), cameraIDs: cameras, lensIDs: lenses)
                var records: [PhotoRecord] = []
                for index in first ..< first + batch {
                    var photo = synthetic.photo(index, in: folders[index % folders.count])
                    if extras {
                        decorate(&photo, index)
                        if index % 50 == 0 {
                            var jpeg = photo
                            jpeg.name = (photo.name as NSString).deletingPathExtension + ".JPG"
                            jpeg.kind = .jpeg
                            records.append(jpeg)
                        }
                    }
                    records.append(photo)
                }
                let ids = try writer.upsertPhotos(records)
                if extras {
                    for (offset, id) in ids.enumerated() where offset % 9 == 0 {
                        try writer.setKeywords(
                            offset % 2 == 0 ? ["Places/Portugal/Lisbon", "Animals/Birds"] : ["sunset"], forPhoto: id,
                        )
                    }
                }
                return ids
            }
            number += batch
        }
        if extras {
            let picked = ids
            try await sandbox.index.write { writer in
                try writer.database.execute("""
                INSERT INTO collections (id, parent, name, kind, path) VALUES (1, NULL, 'Portfolio', 0, 'Portfolio'),
                  (2, 1, '2024', 1, 'Portfolio/2024');
                """)
                for id in picked.enumerated().filter({ $0.offset % 13 == 0 }).map(\.element) {
                    try writer.database.execute("INSERT INTO collection_photos (collection, photo) VALUES (2, \(id))")
                }
            }
        }
        return SnapshotLibrary(sandbox: sandbox, ids: ids)
    }

    /// The fields the synthetic photos don't vary.
    private static func decorate(_ photo: inout PhotoRecord, _ index: Int) {
        let creators = ["Ana Silva", "João Costa", "Élodie Tremblay", nil, nil]
        photo.creator = creators[index % creators.count]
        photo.copyright = index % 7 == 0 ? "© Acme Corp" : nil
        photo.customLabel = index % 31 == 0 ? "Hero" : index % 37 == 0 ? "Client" : nil
        if index % 4 == 0 {
            photo.location = PhotoLocation(
                country: index % 8 == 0 ? "Portugal" : "Canada", state: nil,
                city: index % 8 == 0 ? "Lisboa" : "Montréal", sublocation: nil,
                countryCode: index % 8 == 0 ? "PT" : "CA",
            )
        }
        if index % 6 == 0 {
            (photo.width, photo.height) = (4000, 6000)
        }
        if index % 10 == 3 {
            photo.edited = true
            photo.sidecarModified = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        }
        photo.marked = index % 41 == 0
        if index % 23 == 0 {
            photo.title = "Tram 28"
        }
    }

    func engine() -> QueryEngine {
        QueryEngine(index: index, timeZone: .gmt, now: { QueryTestLibrary.now }, saving: nil)
    }

    func remove() {
        sandbox.remove()
    }

    /// Each section of the store's snapshot, as bytes.
    static func sections(of store: ColumnStore) throws -> [ColumnSnapshot.Section: Data] {
        var sections: [ColumnSnapshot.Section: Data] = [:]
        try store.withSections { section, bytes in
            sections[section] = Data(bytes)
        }
        return sections
    }

    static func pages(of store: ColumnStore) throws -> Int {
        let page = Int(getpagesize())
        var pages = 0
        try store.withSections { section, bytes in
            if section != .live {
                pages += (bytes.count + page - 1) / page
            }
        }
        return pages
    }

    static func facet(_ facet: Facet, of query: LibraryQuery, in engine: QueryEngine) async throws -> FacetCounts? {
        var counts: FacetCounts?
        for try await found in engine.facets([facet], for: query) {
            counts = found
        }
        return counts
    }
}

/// The fields of a snapshot's header a test reads or changes.
struct SnapshotHeader {
    var generation: IndexGeneration
    var pageSize: Int

    var schema: Int {
        get { generation.schema }
        set { generation.schema = newValue }
    }

    static func read(_ url: URL) throws -> SnapshotHeader? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 72 else { return nil }
        func load<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        return SnapshotHeader(
            generation: IndexGeneration(
                schema: Int(load(16, Int64.self)), counter: load(24, Int64.self), token: load(32, Int64.self),
            ),
            pageSize: Int(load(12, UInt32.self)),
        )
    }

    /// Changes the header at `url` as `change` does, with its checksum made again to match.
    static func patch(_ url: URL, _ change: (inout SnapshotHeader) -> Void) throws {
        var header = try #require(try read(url))
        change(&header)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var page = try #require(try handle.read(upToCount: 16384))
        let sections = page.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(
            fromByteOffset: 56,
            as: UInt32.self,
        ))) }
        page.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(header.pageSize).littleEndian, toByteOffset: 12, as: UInt32.self)
            bytes.storeBytes(of: Int64(header.generation.schema).littleEndian, toByteOffset: 16, as: Int64.self)
            bytes.storeBytes(of: header.generation.counter.littleEndian, toByteOffset: 24, as: Int64.self)
            bytes.storeBytes(of: header.generation.token.littleEndian, toByteOffset: 32, as: Int64.self)
            bytes.storeBytes(of: UInt64(0), toByteOffset: 64, as: UInt64.self)
            let sum = ColumnSnapshot.checksum(UnsafeRawBufferPointer(rebasing: bytes[..<(72 + sections * 40)]))
            bytes.storeBytes(of: sum.littleEndian, toByteOffset: 64, as: UInt64.self)
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: page)
    }

    static func inode(_ url: URL) throws -> UInt64 {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
    }
}
