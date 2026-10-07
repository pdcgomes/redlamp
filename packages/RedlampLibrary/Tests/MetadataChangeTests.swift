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

    /// The photos' culling fields in their rows, and what their sidecars hold of them.
    static func culling(_ sandbox: KeywordSandbox, _ paths: [String]) async throws -> [String] {
        var shown: [String] = []
        for path in paths {
            let id = try await sandbox.id(path)
            let row = try #require(try await sandbox.index.read { try $0.photo(id: id) })
            let sidecar = sandbox.sidecar(path)
            shown.append(
                "\(path): row \(row.rating) \(String(describing: row.flag)) \(row.marked) \(row.sidecarModified != nil), "
                    + "sidecar \(sidecar.map { "\($0.metadata ?? PhotoMetadata())" } ?? "none")",
            )
        }
        return shown
    }

    @Test func `an Undo that can't read a sidecar leaves it, reports it and shows what it holds`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let before = try await Self.culling(sandbox, paths)
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.apply(.set([.rating(3)], on: ids))
        // The indexer reads the sidecars the batch wrote, as change tracking does.
        try await sandbox.indexAll()
        // A sidecar the batch made, for a photo that had none, can't be read while Undo runs.
        let locked = SidecarStore().editURL(for: sandbox.url(paths[1]))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let undone = try await metadata.undo()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        #expect(undone.skipped == [LibraryIndexer.path(sandbox.url(paths[1]))], "reported, not taken for none")
        #expect(undone.reasons.values.first == "its sidecar can't be read")
        #expect(sandbox.sidecar(paths[1])?.metadata?.rating == 3)
        let row = try await sandbox.index.read { [id = ids[1]] in try $0.photo(id: id) }
        #expect(row?.rating == 3, "its row shows what its sidecar holds")
        var after = try await Self.culling(sandbox, paths)
        after[1] = before[1]
        #expect(after == before, "every other sidecar and row as before")
    }

    @Test func `a change that would leave a sidecar it can't read as it is fails, and its row shows what it holds`(
    ) async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let locked = SidecarStore().editURL(for: sandbox.url(paths[0]))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let outcome = try await metadata.apply(.set([.rating(0)], on: Array(ids.prefix(4))))
        #expect(outcome.skipped == [LibraryIndexer.path(sandbox.url(paths[0]))])
        let rows = try await sandbox.index.read { reader in try ids.prefix(4).map { try reader.photo(id: $0)?.rating } }
        #expect(rows == [2, 0, 0, 0], "the photo whose sidecar holds 2 stars still shows them")
    }

    @Test func `each photo's own fields are one batch, and its Undo gives each its own value back`() async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        // As `]` does: each photo's own rating, one up.
        let fields = Dictionary(uniqueKeysWithValues: ids.enumerated().map { place, id in
            (id, [MetadataField.rating(place % 2 == 0 ? 3 : 1)])
        })
        let before = try await metadata.entries().count
        let outcome = try await metadata.apply(.each(fields))
        #expect(outcome.title == "Set the rating of 40 photos" && outcome.photos == 40)
        #expect(try await metadata.entries().count == before + 1, "one batch")
        #expect(paths.indices.allSatisfy { sandbox.sidecar(paths[$0])?.metadata?.rating == ($0 % 2 == 0 ? 3 : 1) })
        try await metadata.undo()
        for (number, path) in paths.enumerated() {
            #expect(sandbox.sidecar(path)?.metadata?.rating == (number % 2 == 0 ? 2 : nil), "\(path)")
        }
    }

    @Test func `a photo whose row already shows its fields is in the batch, its sidecar written if it doesn't hold them`(
    ) async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        // The row shows three stars where the sidecar holds two.
        try await sandbox.index.write { [id = ids[0]] writer in try writer.setMetadata(
            ["rating": .number(3)],
            forPhoto: id,
        ) }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let outcome = try await metadata.apply(.each([ids[0]: [.rating(3)], ids[2]: [.rating(2)]]))
        #expect(outcome.written == 2 && outcome.skipped.isEmpty)
        #expect(sandbox.sidecar(paths[0])?.metadata?.rating == 3, "the sidecar gets what its row showed")
        #expect(sandbox.sidecar(paths[2])?.metadata?.rating == 2, "one that holds it already is left as it is")
        try await metadata.undo()
        #expect(sandbox.sidecar(paths[0])?.metadata?.rating == 2 && sandbox.sidecar(paths[2])?.metadata?.rating == 2)
    }

    @Test func `Redo is the Undo of the Undo: a photo changed since keeps its change, and Redo has an Undo of its own`(
    ) async throws {
        let (sandbox, paths, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let made = try await metadata.apply(.set([.rating(4)], on: Array(ids.prefix(4))))
        let undone = try await metadata.undo()
        // Rated by hand since the Undo, and indexed.
        try sandbox.sidecar(paths[1], PhotoMetadata(rating: 5))
        try await sandbox.indexAll()

        let redone = try await metadata.run(metadata.planRedo(undone.batch))
        #expect(redone.title == made.title && redone.state == .finished)
        #expect(paths.prefix(4).map { sandbox.sidecar($0)?.metadata?.rating } == [4, 5, 4, 4], "the hand's five stay")
        let rows = try await sandbox.index.read { reader in try ids.prefix(4).map { try reader.photo(id: $0)?.rating } }
        #expect(rows == [4, 5, 4, 4])
        let entries = try await metadata.entries()
        #expect(entries.first { $0.id == undone.batch }?.state == .undone, "its Undo is taken back")
        #expect(try await metadata.lastUndoable()?.id == redone.batch)
        await #expect(throws: MetadataError.nothingToRedo(undone.batch)) { try await metadata.planRedo(undone.batch) }
        await #expect(throws: MetadataError.nothingToRedo(made.batch)) { try await metadata.planRedo(made.batch) }

        try await metadata.undo()
        #expect(sandbox.sidecar(paths[0])?.metadata == PhotoMetadata(rating: 2, caption: "Before 0"))
        #expect(sandbox.sidecar(paths[1])?.metadata?.rating == 5 && sandbox.sidecar(paths[3]) == nil)
    }

    @Test func `the library's custom labels are listed with how many photos have each`() async throws {
        let (sandbox, _, ids) = try await Self.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        #expect(try await metadata.customLabels().isEmpty)
        try await metadata.apply(.set([.namedLabel("Second Look")], on: Array(ids.prefix(3))))
        try await metadata.apply(.set([.namedLabel("Client 2")], on: [ids[5]]))
        try await metadata.apply(.set([.namedLabel("Client 10")], on: [ids[6], ids[7]]))
        try await metadata.apply(.set([.namedLabel("Red")], on: [ids[8]]))
        #expect(try await metadata.customLabels() == [
            CustomLabelCount(name: "Client 2", photos: 1), CustomLabelCount(name: "Client 10", photos: 2),
            CustomLabelCount(name: "Second Look", photos: 3),
        ])
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
