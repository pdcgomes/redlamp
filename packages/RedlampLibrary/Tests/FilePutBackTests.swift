import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Put Back (LIB-26): photos from Recently Trashed back where they were, as a batch of the file
/// operations, journaled and undoable; and how long the journal keeps what's in the Trash.
struct FilePutBackTests {
    /// The files below the root and on this Mac, and those in the Trash, as `Trash/…`.
    private static func state(_ sandbox: FileSandbox, trash: URL) -> [String: Data] {
        sandbox.files().merging(FileSandbox.contents(of: trash).map { ("Trash/" + $0.key, $0.value) }) { $1 }
    }

    @Test func `Put Back restores each photo with its sidecar, .xmp and pair, and the index has them again with their content keys`(
    ) async throws {
        for onThisMac in [false, true] {
            var watched: WatchedFileSystem?
            let (sandbox, trash) = try await FileTrashedTests.sandbox(onThisMac: onThisMac) { simulated in
                let fileSystem = WatchedFileSystem(simulated)
                watched = fileSystem
                return fileSystem
            }
            defer { sandbox.remove() }
            let reading = try #require(watched)
            let before = sandbox.files()
            let ids = try await sandbox.rows()
            let keywords = ["Clients/Acme", "Places/Portugal"]
            try await sandbox.index.write { try $0.setKeywords(keywords, forPhoto: ids["Shoot/IMG_0002.ARW"]!) }
            let keys = try await sandbox.index.read { reader in
                try ids.compactMapValues { try reader.photo(id: $0)?.contentKey }
            }
            let engine = QueryEngine(index: sandbox.index)
            try await engine.load()
            let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
            var all = live.open(.allPhotographs).makeAsyncIterator()
            #expect(try #require(await all.next()).list.count == 4)
            let operations = sandbox.operations(live: live)
            try await operations.run(operations.planTrash(photos: [
                #require(ids["Shoot/IMG_0001.ARW"]),
                #require(ids["Shoot/IMG_0001.JPG"]),
            ]))
            let single = try await operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])])
            try await operations.run(single)
            let alone = try await operations.planTrash(photos: [#require(ids["Shoot/Day 2/IMG_0003.ARW"])])
            try await operations.run(alone)
            // Its folder, left empty, removed since, as change tracking would find it.
            try FileManager.default.removeItem(at: sandbox.url("Shoot/Day 2"))
            try await sandbox.index.write { try $0.removeFolderIfEmpty(sandbox.rootPath + "/Shoot/Day 2") }
            await live.settle()
            #expect(try #require(await all.next()).list.isEmpty)

            let raw = try #require(try await operations.trashed().first { $0.original.hasSuffix("/IMG_0001.ARW") })
            let batch = try await operations.planPutBack([raw.id])
            #expect(batch.kind == .putBack && batch.title == "Put back 2 photos", "the raw with its JPEG")
            #expect(try await operations.check(batch).isEmpty)
            let reads = reading.reads
            #expect(try await operations.run(batch).isFinished)
            #expect(try await operations.run(operations.planPutBack(batch: single.id)).isFinished)
            #expect(try await operations.run(operations.planPutBack(batch: alone.id)).isFinished)
            #expect(reading.reads == reads, "no photo was read again")

            #expect(sandbox.files() == before)
            #expect(FileSandbox.contents(of: trash).isEmpty)
            #expect(try await sandbox.rows() == ids, "the rows came back under their IDs")
            #expect(try await sandbox.index.read { reader in
                try ids.compactMapValues { try reader.photo(id: $0)?.contentKey }
            } == keys)
            #expect(try await sandbox.index.read { try $0.keywords(forPhoto: ids["Shoot/IMG_0002.ARW"]!) } == keywords)
            #expect(try await operations.trashed().isEmpty)
            await live.settle()
            #expect(try #require(await all.next()).list.count == 4)
        }
    }

    @Test func `a name taken at the original place stops Put Back before anything moves`() async throws {
        let (sandbox, trash) = try await FileTrashedTests.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let trashing = try await operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])])
        try await operations.run(trashing)

        for taken in ["Shoot/IMG_0002.ARW", "Shoot/IMG_0002.ARW.xmp"] {
            try Data("another file, under its name".utf8).write(to: sandbox.url(taken))
            let batch = try await operations.planPutBack(batch: trashing.id)
            let conflict = FileConflict(path: sandbox.rootPath + "/" + taken, reason: .taken)
            #expect(try await operations.check(batch) == [conflict])
            let before = Self.state(sandbox, trash: trash)
            let entries = try await operations.entries()
            await #expect(throws: FileOperationError.conflicts([conflict]), "\(taken)") {
                try await operations.run(batch)
            }
            #expect(Self.state(sandbox, trash: trash) == before, "\(taken)")
            #expect(try await operations.entries() == entries, "nothing was written to the journal")
            try FileManager.default.removeItem(at: sandbox.url(taken))
        }
        #expect(try await operations.run(operations.planPutBack(batch: trashing.id)).isFinished)
        #expect(FileSandbox.contents(of: trash).isEmpty)
    }

    @Test func `a file that took the place of one of a photo's in the Trash since Put Back was planned stays there`(
    ) async throws {
        let (sandbox, trash) = try await FileTrashedTests.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let trashing = try await operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])])
        try await operations.run(trashing)
        let batch = try await operations.planPutBack(batch: trashing.id)
        let place = trash.appending(path: "IMG_0002.ARW.xmp")
        try FileManager.default.removeItem(at: place)
        try Data("another app's, since".utf8).write(to: place)

        #expect(try await operations.run(batch).isFinished)
        #expect(FileSandbox.contents(of: trash) == ["IMG_0002.ARW.xmp": Data("another app's, since".utf8)])
        let files = Set(sandbox.files().keys)
        #expect(files.contains("Shoot/IMG_0002.ARW") && files.contains("Shoot/IMG_0002.ARW.redlamp/edit.json"))
        #expect(!files.contains("Shoot/IMG_0002.ARW.xmp"))
    }

    @Test(arguments: [FileRecovery.finish, .rollBack])
    func `Put Back's Undo, and a forced quit during it, finish or roll back`(_ choice: FileRecovery) async throws {
        let (sandbox, trash) = try await FileTrashedTests.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        try await operations.run(operations.planTrash(photos: [
            #require(ids["Shoot/IMG_0001.ARW"]),
            #require(ids["Shoot/IMG_0001.JPG"]),
            #require(ids["Shoot/IMG_0002.ARW"]),
        ]))
        let inTrash = Self.state(sandbox, trash: trash)
        let trashedRows = try await sandbox.rows()
        let putBack = try await operations.planPutBack(operations.trashed().map(\.id))
        #expect(try await operations.run(putBack).isFinished)
        let back = Self.state(sandbox, trash: trash)
        let backRows = try await sandbox.rows()
        #expect(backRows == ids)
        #expect(try await operations.undo().isFinished)
        #expect(Self.state(sandbox, trash: trash) == inTrash)
        #expect(try await sandbox.rows() == trashedRows)
        let again = try await operations.trashed()
        #expect(again.count == 3 && again.allSatisfy { $0.title == "Undo " + putBack.title }, "listed from the Undo")

        var interruptions: [FileOperations.Interruption] = []
        for (index, step) in putBack.steps.enumerated() {
            interruptions += [.afterStep(index), .beforeLogging(index)]
            if step.items.count > 1 {
                interruptions.append(.withinStep(index, items: 1))
            }
        }
        #expect(interruptions.count == 8)
        for interruption in interruptions {
            let killed = sandbox.operations()
            killed.interruption.withLock { $0 = interruption }
            await #expect(throws: FileOperations.ForcedQuit.self, "\(interruption)") {
                try await killed.run(killed.planPutBack(killed.trashed().map(\.id)))
            }
            let launch = sandbox.operations()
            let outcomes = try await launch.recover(choice)
            #expect(outcomes.map(\.state) == [choice == .finish ? .finished : .rolledBack], "\(interruption)")
            let found = Self.state(sandbox, trash: trash)
            let expected = choice == .finish ? back : inTrash
            #expect(
                found == expected,
                "\(interruption): \(found.filter { expected[$0.key] != $0.value }.keys.sorted())",
            )
            #expect(try await sandbox.rows() == (choice == .finish ? backRows : trashedRows), "\(interruption)")
            #expect(sandbox.leftovers().isEmpty, "\(interruption)")
            if choice == .finish {
                #expect(try await launch.undo().isFinished, "\(interruption)")
                #expect(Self.state(sandbox, trash: trash) == inTrash, "\(interruption)")
            } else {
                #expect(try await launch.trashed().count == 3, "\(interruption)")
            }
        }
    }

    @Test func `Put Back of a photo of a folder that went to the Trash whole brings the folder back`() async throws {
        let (sandbox, trash) = try await FileTrashedTests.sandbox(onThisMac: true)
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let path = sandbox.rootPath + "/Shoot/Day 2"
        let folder = try await sandbox.index.read { try $0.folder(path: path) }
        let operations = sandbox.operations()
        try await operations.run(operations.planTrash(folder: sandbox.url("Shoot/Day 2")))

        let batch = try await operations.planPutBack(operations.trashed().map(\.id))
        #expect(batch.steps.map { $0.items.map(\.role) } == [[.folder, .sidecarOnThisMac]])
        #expect(try await operations.run(batch).isFinished)
        #expect(sandbox.files() == before && FileSandbox.contents(of: trash).isEmpty)
        #expect(try await sandbox.rows() == ids)
        #expect(try await sandbox.index.read { try $0.folder(path: path) }?.id == folder?.id)
    }
}
