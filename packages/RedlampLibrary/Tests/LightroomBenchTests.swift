import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// A Lightroom Classic catalog's report and import at size (LIB-29): a catalog of 100,000 photos reported in
/// seconds and imported in parts with progress. The full size runs with `REDLAMP_LIGHTROOM_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_LIGHTROOM_BENCH=1` through `xcodebuild`), `REDLAMP_LIGHTROOM_BENCH_PHOTOS` setting
/// how many; every run measures 5,000.
struct LightroomBenchTests {
    /// The library's photos as rows of an index, in folders of 1,000 on disk where their sidecars go, and a
    /// catalog of them: a third rated, a tenth picked and a twentieth rejected, a fifth labelled, three keywords
    /// each from a list of 2,000 in a hierarchy, a fifth in one of 50 collections in 5 sets, 10 smart
    /// collections, captions on a third, and XMP for every photo, Develop settings in it and a title in a fifth.
    struct Library {
        let photos: TemporaryFolder
        let library: TemporaryFolder
        let index: LibraryIndex
        let catalog: URL

        var paths: LibraryPaths {
            LibraryPaths(root: library.url)
        }
    }

    static func library(photos count: Int) async throws -> Library {
        let photos = try TemporaryFolder()
        let library = try TemporaryFolder()
        let index = try await LibraryIndex.open(at: library.url.appending(path: "Index.sqlite"))
        let root = LibraryIndexer.path(photos.url)
        let folders = (count + 999) / 1000
        for folder in 0 ..< folders {
            try FileManager.default.createDirectory(
                at: photos.url.appending(path: String(format: "Shoot %03d", folder)), withIntermediateDirectories: true,
            )
        }
        try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH-VOLUME", name: "Bench", kind: .ssd))
            let rootID = try writer.upsertRoot(RootRecord(volume: volume, path: root))
            let top = try writer.upsertFolder(FolderRecord(root: rootID, parent: nil, path: root))
            for folder in 0 ..< folders {
                let id = try writer.upsertFolder(FolderRecord(
                    root: rootID, parent: top, path: root + String(format: "/Shoot %03d", folder),
                ))
                let names = (folder * 1000 ..< min((folder + 1) * 1000, count))
                _ = try writer.upsertPhotos(names.map { number in
                    PhotoRecord(folder: id, name: String(format: "IMG_%06d.CR3", number), size: 1000)
                })
            }
        }

        let maker = try LightroomCatalogMaker(at: library.url.appending(path: "Lightroom Catalog.lrcat"))
        try maker.transaction {
            let top = try maker.root(root + "/")
            var keywords: [Int64] = []
            var parents: [Int64] = []
            for group in 0 ..< 40 {
                let parent = try maker.keyword("Group \(group)", synonyms: group % 4 == 0 ? ["G\(group)"] : [])
                parents.append(parent)
                for child in 0 ..< 49 {
                    try keywords.append(maker.keyword(
                        "Keyword \(group)-\(child)",
                        parent: parent,
                        includeOnExport: child % 10 != 0,
                    ))
                }
            }
            var members: [[Int64]] = Array(repeating: [], count: 50)
            var folderIDs: [Int64] = []
            for folder in 0 ..< folders {
                try folderIDs.append(maker.folder(top, String(format: "Shoot %03d/", folder)))
            }
            for number in 0 ..< count {
                let photo = try maker.photo(
                    folderIDs[number / 1000], String(format: "IMG_%06d.CR3", number),
                    rating: number % 3 == 0 ? number % 5 + 1 : nil,
                    pick: number % 10 == 0 ? 1 : number % 20 == 1 ? -1 : 0,
                    label: number % 5 == 0 ? ["Red", "Yellow", "Green", "Blue", "Purple"][number / 5 % 5] : "",
                )
                for step in 0 ..< 3 {
                    try maker.tag(photo, keywords[(number * 7 + step * 131) % keywords.count])
                }
                if number % 5 == 0 {
                    members[number / 5 % 50].append(photo)
                }
                if number % 3 == 0 {
                    try maker.iptc(photo, caption: "Caption of photo \(number)")
                }
                try maker.xmp(photo, title: number % 5 == 0 ? "Title \(number)" : nil, settings: 150)
            }
            for set in 0 ..< 5 {
                let parent = try maker.collection("Set \(set)", kind: LightroomCatalogMaker.setKind)
                for collection in 0 ..< 10 {
                    try maker.collection(
                        "Collection \(set)-\(collection)",
                        parent: parent,
                        photos: members[set * 10 + collection],
                    )
                }
            }
            for rating in 0 ..< 10 {
                try maker.collection("Smart \(rating)", kind: LightroomCatalogMaker.smartKind, rules: """
                s = { { criteria = "rating", operation = ">=", value = \(rating % 5 + 1), value2 = 0, },
                      { criteria = "keywords", operation = "any", value = "Keyword \(rating)-1", value2 = "", },
                      combine = "intersect", }
                """)
            }
        }
        maker.close()
        return Library(photos: photos, library: library, index: index, catalog: maker.url)
    }

    struct Measured {
        var read: Duration
        var plan: Duration
        var run: Duration
        var undo: Duration
        var parts: Int
        var progress: Int
    }

    static func measure(photos count: Int) async throws -> Measured {
        let library = try await Self.library(photos: count)
        defer { library.index.closeAndWait() }
        let clock = ContinuousClock()
        var started = clock.now
        let catalog = try LightroomCatalog.read(library.catalog)
        let read = clock.now - started
        started = clock.now
        let plan = try await LightroomPlan.make(catalog, index: library.index, paths: library.paths)
        let planned = clock.now - started
        #expect(plan.report.found == count && plan.report.notFound == 0)
        #expect(plan.report.fields.ratings == (count + 2) / 3)
        #expect(plan.report.smartMapped.count == 10 && plan.report.collections == 50)
        #expect(plan.report.keywords == 40 * 50)

        let progress = ProgressLog()
        let importer = LightroomImport(index: library.index, paths: library.paths)
        started = clock.now
        let outcome = try await importer.run(plan) { progress.add($0) }
        let ran = clock.now - started
        #expect(outcome.record.photos == count && outcome.skipped.isEmpty)
        #expect(progress.last?.done == count)
        started = clock.now
        try await importer.undo()
        let undone = clock.now - started
        let parts = (count + importer.partSize - 1) / importer.partSize
        print("LIGHTROOM-BENCH \(count) photos: read \(read), report \(planned), import \(ran) in \(parts) parts "
            + "(\(outcome.written) sidecars written, \(progress.count) progress reports), undo \(undone)")
        return Measured(read: read, plan: planned, run: ran, undo: undone, parts: parts, progress: progress.count)
    }

    @Test(.measuresSpeed)
    func `a catalog of 5,000 photos is reported in under a second and imported with progress`() async throws {
        let measured = try await Self.measure(photos: 5000)
        #expect(measured.read + measured.plan < .seconds(1))
        #expect(measured.progress >= measured.parts)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_LIGHTROOM_BENCH"] == "1"), .measuresSpeed)
    func `a catalog of 100,000 photos is reported in seconds and imported in parts with progress`() async throws {
        let photos = ProcessInfo.processInfo.environment["REDLAMP_LIGHTROOM_BENCH_PHOTOS"].flatMap { Int($0) }
            ?? 100_000
        let measured = try await Self.measure(photos: photos)
        #expect(measured.read + measured.plan < .seconds(10))
        #expect(measured.parts == (photos + LightroomImport.standardPartSize - 1) / LightroomImport.standardPartSize)
    }
}
