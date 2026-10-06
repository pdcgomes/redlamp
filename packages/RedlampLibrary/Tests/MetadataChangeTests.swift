import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Ratings, flags, labels, custom labels and marks (LIB-15), and IPTC Core's fields (LIB-22), changed on
/// many photos as one batch with Undo, each photo's sidecar keeping everything else it holds.
struct MetadataChangeTests {
    /// 40 photos in two folders: every other one with a sidecar holding an edit, a rating of 2 and a
    /// caption; the rest without one.
    static func library() async throws -> (sandbox: KeywordSandbox, paths: [String], ids: [Int64]) {
        let sandbox = try await KeywordSandbox.make()
        let paths = (0 ..< 40).map { String(format: "Day %d/IMG_%04d.ARW", $0 / 20 + 1, $0) }
        for (number, path) in paths.enumerated() {
            try sandbox.photo(path)
            if number % 2 == 0 {
                try sandbox.sidecar(path, PhotoMetadata(rating: 2, caption: "Before \(number)"))
            }
        }
        try await sandbox.indexAll()
        return try await (sandbox, paths, sandbox.ids(paths))
    }

    @Test func `rating, flag, label and mark on many photos, and their Undo`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let outcome = try await metadata.apply(.set([.rating(4), .flag(.pick), .label(.red), .mark(true)], on: ids))
        #expect(outcome.title == "Set the rating, the flag, the label and the mark of 40 photos")
        #expect(outcome.photos == 40 && outcome.written == 40 && outcome.skipped.isEmpty)
        for path in paths {
            let id = try await sandbox.id(path)
            let row = try await sandbox.index.read { try $0.photo(id: id) }
            #expect(row?.rating == 4 && row?.flag == .pick && row?.label == .red && row?.marked == true, "\(path)")
            let sidecar = try #require(sandbox.sidecar(path))
            #expect(sidecar.metadata?.rating == 4 && sidecar.metadata?.flag == .pick && sidecar.metadata?.mark == true)
        }
        // Everything else the sidecars held is kept.
        let kept = try #require(sandbox.sidecar(paths[0]))
        #expect(kept.recipe[.exposure] == 0.35 && kept.metadata?.caption == "Before 0")
        #expect(kept.unknownFields["fromTheFuture"] == .string("kept"))

        let undone = try await metadata.undo()
        #expect(undone.title == "Undo Set the rating, the flag, the label and the mark of 40 photos")
        for (number, path) in paths.enumerated() {
            let id = try await sandbox.id(path)
            let row = try await sandbox.index.read { try $0.photo(id: id) }
            #expect(row?.rating == (number % 2 == 0 ? 2 : 0) && row?.flag == nil && row?.label == nil, "\(path)")
            #expect(row?.marked == false)
            if number % 2 == 0 {
                #expect(sandbox.sidecar(path)?.metadata == PhotoMetadata(rating: 2, caption: "Before \(number)"))
            } else {
                #expect(!FileManager.default.fileExists(atPath: SidecarStore().url(for: sandbox.url(path)).path))
            }
        }
        await #expect(throws: MetadataError.nothingToUndo) { try await metadata.undo() }
    }

    @Test func `a label by name is a colour in any set, or else a custom label, never both`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.apply(.set([.label(.blue)], on: Array(ids.prefix(4))))
        try await metadata.apply(.set([.namedLabel("Urgent")], on: Array(ids.prefix(2))))
        try await metadata.apply(.set([.namedLabel("Approved")], on: [ids[2]]))
        let rows = try await sandbox.index.read { reader in try ids.prefix(4).map { try reader.photo(id: $0) } }
        #expect(rows.map { $0?.label } == [nil, nil, .green, .blue])
        #expect(rows.map { $0?.customLabel } == ["Urgent", "Urgent", nil, nil])
        #expect(sandbox.sidecar(paths[0])?.metadata?.label == nil)
        #expect(sandbox.sidecar(paths[0])?.metadata?.customLabel == "Urgent")
        #expect(sandbox.sidecar(paths[2])?.metadata?.customLabel == nil)
        try await metadata.undo()
        let label = try await sandbox.index.read { try $0.photo(id: ids[2])?.label }
        #expect(label == .blue)
    }

    @Test func `IPTC Core's fields on many photos, and Undo keeps a field changed since`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let place = PhotoLocation(country: "Portugal", state: "Lisboa", city: "Lisbon", countryCode: "PT")
        try await metadata.apply(.set([
            .title("Tram 28"), .caption("The tram climbing to Graça."), .creator("Ana Sousa"),
            .copyright("© 2026 Ana Sousa"), .location(place), .sublocation("Graça"),
        ], on: ids))
        var expected = place
        expected.sublocation = "Graça"
        for path in paths {
            let id = try await sandbox.id(path)
            let row = try await sandbox.index.read { try $0.photo(id: id) }
            #expect(row?.title == "Tram 28" && row?.caption == "The tram climbing to Graça.", "\(path)")
            #expect(row?.creator == "Ana Sousa" && row?.copyright == "© 2026 Ana Sousa" && row?.location == expected)
            #expect(sandbox.sidecar(path)?.metadata?.location == expected)
        }
        #expect(try await sandbox.search("caption:graça").count == 40)

        // One photo's caption changed by hand since: Undo leaves it, and takes back the rest.
        let photo = sandbox.url(paths[3])
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.caption = "By hand"
        try SidecarStore().save(sidecar, for: photo)
        try await metadata.undo()
        #expect(sandbox.sidecar(paths[3])?.metadata?.caption == "By hand")
        #expect(sandbox.sidecar(paths[3])?.metadata?.title == nil)
        #expect(sandbox.sidecar(paths[2])?.metadata == PhotoMetadata(rating: 2, caption: "Before 2"))
        #expect(!FileManager.default.fileExists(atPath: SidecarStore().url(for: sandbox.url(paths[1])).path))
        let row = try await sandbox.index.read { [id = ids[2]] reader in try reader.photo(id: id) }
        #expect(row?.caption == "Before 2" && row?.title == nil && row?.location == nil)
    }

    @Test func `a field cleared is written empty, so other apps' value doesn't come back`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.ARW")
        try sandbox.write("IMG_0001.xmp", MetadataIndexTests.otherApp, modified: -600)
        try await sandbox.indexAll()
        #expect(try await sandbox.row("IMG_0001.ARW").title == "Ribeira")
        let metadata = LibraryMetadata(index: sandbox.index)
        try await metadata.apply(.set([.title(nil), .location(nil)], on: [sandbox.id("IMG_0001.ARW")]))
        #expect(sandbox.metadata("IMG_0001.ARW")?.title == "")
        #expect(sandbox.metadata("IMG_0001.ARW")?.location == PhotoLocation())
        for _ in 0 ..< 2 {
            let row = try await sandbox.row("IMG_0001.ARW")
            #expect(row.title == nil && row.location == nil && row.customLabel == "Urgent")
            #expect(row.caption == "Boats on the Douro." && row.rating == 3)
            // Read again from the files: the .redlamp's empty fields stand.
            try sandbox.setModified("IMG_0001.ARW", -60)
            try await sandbox.indexAll()
        }
    }

    @Test func `Undo shows other apps' values as theirs again, so a change only the sidecar has reads nothing`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0001.ARW")
        try sandbox.write("IMG_0001.xmp", MetadataIndexTests.otherApp, modified: -600)
        try sandbox.sidecar("IMG_0001.ARW", PhotoMetadata(rating: 1))
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let others = try await sandbox.row("IMG_0001.ARW").otherFields
        #expect(others.contains(.caption) && !others.contains(.rating))

        let metadata = LibraryMetadata(index: sandbox.index)
        try await metadata.apply(.set([.caption("Ours")], on: [sandbox.id("IMG_0001.ARW")]))
        #expect(try await !sandbox.row("IMG_0001.ARW").otherFields.contains(.caption))
        try await metadata.undo()
        #expect(try await sandbox.row("IMG_0001.ARW").otherFields == others)
        #expect(try await sandbox.row("IMG_0001.ARW").caption == "Boats on the Douro.")

        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.keywords = ["Places/Porto"]
        try SidecarStore().save(sidecar, for: photo)
        try sandbox.setModified("IMG_0001.ARW.redlamp", 60)
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(files.counts.reads[LibraryIndexer.path(photo)] == 1)
        #expect(try await sandbox.row("IMG_0001.ARW").caption == "Boats on the Douro.")
    }

    @Test func `a sidecar a batch leaves as it is keeps the date the index has for it, so indexing again reads nothing`(
    ) async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.apply(.set([.caption("Halfway")], on: Array(ids.prefix(2))))
        // Put back by hand since, and indexed: the Undo leaves its sidecar as it is.
        try sandbox.sidecar(paths[0], PhotoMetadata(rating: 2, caption: "Before 0"))
        try await sandbox.indexAll()
        let undone = try await metadata.undo()
        #expect(undone.written == 2 && sandbox.sidecar(paths[1]) == nil)
        #expect(sandbox.sidecar(paths[0])?.metadata == PhotoMetadata(rating: 2, caption: "Before 0"))

        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(run.failures.isEmpty)
        #expect(run.summary?.photosUpdated == 0 && run.summary?.headsRead == 0, "\(String(describing: run.summary))")
        #expect(files.counts.reads.isEmpty, "\(files.counts.reads)")
    }

    @Test func `a batch a forced quit stopped is finished or rolled back at the next launch`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        for choice in [FileRecovery.finish, .rollBack] {
            let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
            metadata.interruption.withLock { $0 = 10 }
            await #expect(throws: LibraryMetadata.ForcedQuit.self) {
                try await metadata.apply(.set([.caption("Halfway")], on: ids))
            }
            let again = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
            await #expect(throws: MetadataError.self) { try await again.apply(.set([.rating(1)], on: ids)) }
            let outcomes = try await again.recover(choice)
            #expect(outcomes.count == 1 && (outcomes[0].recoveredFrom ?? 0) >= 10)
            let captions = paths.map { sandbox.sidecar($0)?.metadata?.caption }
            if choice == .finish {
                #expect(captions.allSatisfy { $0 == "Halfway" })
                try await again.undo()
            } else {
                #expect(captions == paths.indices.map { $0 % 2 == 0 ? "Before \($0)" : nil })
            }
        }
    }
}
