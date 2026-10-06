import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

struct FileRenameTests {
    /// The photos of `sandbox` renamed by `template`, in the order given.
    private static func rename(
        _ sandbox: FileSandbox, _ paths: [String], _ template: String, operations: FileOperations? = nil,
    ) async throws -> (FileBatch, FileOutcome) {
        let operations = operations ?? sandbox.operations()
        let rows = try await sandbox.rows()
        let preview = try await operations.renamePreview(
            NamingTemplate(parsing: template), photos: paths.compactMap { rows[$0] },
        )
        let batch = try await operations.planRename(preview)
        return try await (batch, operations.run(batch))
    }

    @Test func `a raw and its JPEG are renamed together, with their sidecars and other apps' xmp`() async throws {
        let sandbox = try await FileSandbox.make([
            .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
            .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0), sidecar: true),
            .init("Shoot/IMG_0002.JPG", captured: FileSandbox.date(5), xmp: .name),
        ])
        defer { sandbox.remove() }
        let before = sandbox.photoFiles()
        let ids = try await sandbox.rows()
        let (batch, outcome) = try await Self.rename(sandbox, ["Shoot/IMG_0001.ARW"], "Wedding-{sequence:3}")
        #expect(outcome.isFinished && outcome.photos == 2, "the JPEG goes with its raw")
        #expect(batch.steps.filter { $0.kind == .move }.count == 1)

        let files = Set(sandbox.files().keys)
        #expect(files == [
            "Shoot/Wedding-001.ARW", "Shoot/Wedding-001.JPG", "Shoot/Wedding-001.xmp",
            "Shoot/Wedding-001.ARW.redlamp/edit.json", "Shoot/Wedding-001.JPG.redlamp/edit.json",
            "Shoot/IMG_0002.JPG", "Shoot/IMG_0002.JPG.xmp",
        ])
        #expect(sandbox.photoFiles()["Shoot/Wedding-001.ARW"] == before["Shoot/IMG_0001.ARW"])
        #expect(sandbox.photoFiles()["Shoot/Wedding-001.JPG"] == before["Shoot/IMG_0001.JPG"])
        let rows = try await sandbox.rows()
        #expect(rows["Shoot/Wedding-001.ARW"] == ids["Shoot/IMG_0001.ARW"])
        #expect(rows["Shoot/Wedding-001.JPG"] == ids["Shoot/IMG_0001.JPG"])
        #expect(rows["Shoot/IMG_0002.JPG"] == ids["Shoot/IMG_0002.JPG"] && rows.count == 3)

        let sidecar = try #require(try await sandbox.sidecar("Shoot/Wedding-001.ARW"))
        #expect(sidecar.metadata?.rating == 3 && sidecar.metadata?.label == .green)
        #expect(sidecar.metadata?.originalName == "IMG_0001.ARW")
        #expect(try await sandbox.sidecar("Shoot/Wedding-001.JPG")?.metadata?.originalName == "IMG_0001.JPG")
        #expect(sandbox.leftovers().isEmpty)

        // A name-form xmp follows its photo.
        let (_, second) = try await Self.rename(sandbox, ["Shoot/IMG_0002.JPG"], "Party")
        #expect(second.isFinished)
        #expect(Set(sandbox.files().keys).isSuperset(of: ["Shoot/Party.JPG", "Shoot/Party.JPG.xmp"]))
    }

    @Test func `sidecars kept on this Mac move with their photos`() async throws {
        let sandbox = try await FileSandbox.make(
            [.init("A/DSC_0001.NEF", sidecar: true), .init("A/DSC_0002.NEF", sidecar: true, xmp: .stem)],
            onThisMac: true,
        )
        defer { sandbox.remove() }
        let mac = Set(sandbox.files().keys.filter { $0.hasPrefix("mac/") })
        #expect(mac.count == 2 && mac.allSatisfy { $0.contains("/Photos/A/DSC_000") })
        let (_, outcome) = try await Self.rename(sandbox, ["A/DSC_0001.NEF", "A/DSC_0002.NEF"], "Lisbon-{sequence}")
        #expect(outcome.isFinished)
        let files = Set(sandbox.files().keys)
        #expect(files.isSuperset(of: ["A/Lisbon-1.NEF", "A/Lisbon-2.NEF", "A/Lisbon-2.xmp"]))
        #expect(files.contains { $0.hasPrefix("mac/") && $0.hasSuffix("/Photos/A/Lisbon-1.NEF.redlamp/edit.json") })
        #expect(!files.contains { $0.contains("DSC_000") })
        #expect(!files.contains { !$0.hasPrefix("mac/") && $0.contains(".redlamp") }, "nothing written beside them")
        #expect(try await sandbox.sidecar("A/Lisbon-2.NEF")?.metadata?.originalName == "DSC_0002.NEF")
    }

    @Test func `photos that swap names go through a temporary name, and so does a cycle of three`() async throws {
        let sandbox = try await FileSandbox.make([
            .init("IMG_1.JPG", captured: FileSandbox.date(30), sidecar: true),
            .init("IMG_2.JPG", captured: FileSandbox.date(20), xmp: .stem),
            .init("IMG_3.JPG", captured: FileSandbox.date(10), sidecar: true),
        ])
        defer { sandbox.remove() }
        let before = sandbox.photoFiles()
        let ids = try await sandbox.rows()
        // In the order taken, IMG_3 becomes IMG_1, IMG_2 stays, IMG_1 becomes IMG_3: a swap of two.
        let (swap, swapped) = try await Self.rename(sandbox, ["IMG_3.JPG", "IMG_2.JPG", "IMG_1.JPG"], "IMG_{sequence}")
        #expect(swapped.isFinished)
        #expect(swap.steps.contains { step in
            step.items.contains { $0.destination?.contains("Redlamp-renaming-") == true }
        })
        #expect(sandbox.photoFiles()["IMG_1.JPG"] == before["IMG_3.JPG"])
        #expect(sandbox.photoFiles()["IMG_3.JPG"] == before["IMG_1.JPG"])
        #expect(sandbox.photoFiles()["IMG_2.JPG"] == before["IMG_2.JPG"])
        var rows = try await sandbox.rows()
        #expect(rows["IMG_1.JPG"] == ids["IMG_3.JPG"] && rows["IMG_3.JPG"] == ids["IMG_1.JPG"])
        #expect(try await sandbox.sidecar("IMG_1.JPG")?.metadata?.originalName == "IMG_3.JPG")
        #expect(sandbox.files()["IMG_2.xmp"] != nil && sandbox.leftovers().isEmpty)

        // Each one along: IMG_1 to IMG_2, IMG_2 to IMG_3, IMG_3 to IMG_1.
        let (_, rotated) = try await Self.rename(sandbox, ["IMG_3.JPG", "IMG_1.JPG", "IMG_2.JPG"], "IMG_{sequence}")
        #expect(rotated.isFinished)
        rows = try await sandbox.rows()
        #expect(rows["IMG_1.JPG"] == ids["IMG_1.JPG"] && rows["IMG_2.JPG"] == ids["IMG_3.JPG"])
        #expect(rows["IMG_3.JPG"] == ids["IMG_2.JPG"])
        #expect(sandbox.photoFiles()["IMG_2.JPG"] == before["IMG_3.JPG"])
        #expect(sandbox.photoFiles()["IMG_1.JPG"] == before["IMG_1.JPG"])
        #expect(sandbox.files()["IMG_3.xmp"] != nil, "the stem's xmp went with its photo")
        #expect(Set(sandbox.files().keys).allSatisfy { !$0.contains("Redlamp-renaming-") })
    }

    @Test func `photos given names of their own swap through a temporary name and keep their original names`(
    ) async throws {
        let sandbox = try await FileSandbox.make([
            .init("A/IMG_1.JPG", captured: FileSandbox.date(0), sidecar: true),
            .init("A/IMG_2.JPG", captured: FileSandbox.date(1), xmp: .stem),
        ])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let ids = try await sandbox.rows()
        let before = sandbox.photoFiles()
        func renaming(_ relative: String, to name: String) throws -> PhotoRename {
            try PhotoRename(id: #require(ids[relative]), path: LibraryIndexer.path(sandbox.url(relative)), name: name)
        }
        let batch = try await operations.planRename([
            renaming("A/IMG_1.JPG", to: "IMG_2.JPG"), renaming("A/IMG_2.JPG", to: "IMG_1.JPG"),
        ])
        #expect(batch.kind == .rename && batch.title == "Rename 2 photos")
        #expect(batch.steps.contains { step in
            step.items.contains { $0.destination?.contains("Redlamp-renaming-") == true }
        })
        #expect(try await operations.run(batch).isFinished)
        #expect(sandbox.photoFiles()["A/IMG_2.JPG"] == before["A/IMG_1.JPG"])
        let rows = try await sandbox.rows()
        #expect(rows["A/IMG_2.JPG"] == ids["A/IMG_1.JPG"] && rows["A/IMG_1.JPG"] == ids["A/IMG_2.JPG"])
        #expect(try await sandbox.sidecar("A/IMG_2.JPG")?.metadata?.originalName == "IMG_1.JPG")
        #expect(sandbox.files()["A/IMG_1.xmp"] != nil, "the stem's xmp went with its photo")

        let titled = try await operations.planRename([renaming("A/IMG_1.JPG", to: "Beach.JPG")], title: "Beach")
        #expect(titled.title == "Beach")
    }

    @Test func `a name taken since the preview, or a photo gone, stops the batch before anything moves`() async throws {
        let sandbox = try await FileSandbox.make([
            .init("A/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true),
            .init("A/IMG_0002.ARW", captured: FileSandbox.date(1)),
        ])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let rows = try await sandbox.rows()
        let preview = try await operations.renamePreview(
            NamingTemplate(parsing: "Trip-{sequence}"), photos: [
                #require(rows["A/IMG_0001.ARW"]),
                #require(rows["A/IMG_0002.ARW"]),
            ],
        )
        let batch = try await operations.planRename(preview)
        let before = sandbox.files()

        // A file of one of the new names arrives.
        try Data("theirs".utf8).write(to: sandbox.url("A/Trip-2.ARW"))
        await #expect(throws: FileOperationError.conflicts([
            FileConflict(path: sandbox.rootPath + "/A/Trip-2.ARW", reason: .taken),
        ])) { try await operations.run(batch) }
        var after = sandbox.files()
        after.removeValue(forKey: "A/Trip-2.ARW")
        #expect(after == before)
        #expect(try await operations.entries().isEmpty, "nothing was written to the journal")

        try FileManager.default.removeItem(at: sandbox.url("A/Trip-2.ARW"))
        try FileManager.default.removeItem(at: sandbox.url("A/IMG_0002.ARW"))
        await #expect(throws: FileOperationError.conflicts([
            FileConflict(path: sandbox.rootPath + "/A/IMG_0002.ARW", reason: .gone),
        ])) { try await operations.run(batch) }
        #expect(sandbox.files()["A/IMG_0001.ARW"] != nil)
    }

    @Test func `a photo's original name is recorded the first time, kept after, and taken out by its Undo`(
    ) async throws {
        let sandbox = try await FileSandbox.make([
            .init("IMG_0007.CR3", sidecar: true), .init("IMG_0008.CR3"),
        ])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        _ = try await Self.rename(sandbox, ["IMG_0007.CR3", "IMG_0008.CR3"], "First-{sequence}", operations: operations)
        #expect(try await sandbox.sidecar("First-1.CR3")?.metadata?.originalName == "IMG_0007.CR3")
        #expect(
            try await sandbox.sidecar("First-2.CR3")?.metadata?.originalName == "IMG_0008.CR3",
            "a sidecar made for it",
        )
        _ = try await Self.rename(sandbox, ["First-1.CR3", "First-2.CR3"], "{original|lower}", operations: operations)
        #expect(Set(sandbox.photoFiles().keys) == ["img_0007.CR3", "img_0008.CR3"])
        #expect(try await sandbox.sidecar("img_0007.CR3")?.metadata?.originalName == "IMG_0007.CR3")

        #expect(try await operations.undo().isFinished)
        #expect(Set(sandbox.photoFiles().keys) == ["First-1.CR3", "First-2.CR3"])
        #expect(try await sandbox.sidecar("First-1.CR3")?.metadata?.originalName == "IMG_0007.CR3")
        #expect(try await operations.undo().isFinished)
        #expect(Set(sandbox.photoFiles().keys) == ["IMG_0007.CR3", "IMG_0008.CR3"])
        let kept = try #require(try await sandbox.sidecar("IMG_0007.CR3"))
        #expect(kept.metadata?.originalName == nil && kept.metadata?.rating == 3)
        #expect(
            sandbox.files().keys.allSatisfy { !$0.hasPrefix("IMG_0008.CR3.redlamp") },
            "the sidecar made for it is gone",
        )
        await #expect(throws: FileOperationError.nothingToUndo) { try await operations.undo() }
        #expect(try await operations.entries().map(\.state) == [.undone, .undone, .finished, .finished])
    }

    @Test func `a rename of hundreds of photos cancelled partway records the names it renamed, which Undo takes out`(
    ) async throws {
        let photos = (0 ..< 300).map { number in
            FileSandbox.Photo(
                String(format: "IMG_%04d.JPG", number), captured: FileSandbox.date(Double(number)),
                sidecar: number.isMultiple(of: 2),
            )
        }
        let sandbox = try await FileSandbox.make(photos)
        defer { sandbox.remove() }
        let before = Set(sandbox.files().keys)
        let operations = sandbox.operations()
        let rows = try await sandbox.rows()
        let preview = try await operations.renamePreview(
            NamingTemplate(parsing: "Shoot-{sequence:4}"), photos: photos.compactMap { rows[$0.path] },
        )
        let batch = try await operations.planRename(preview)
        let running = Mutex<Task<FileOutcome, any Error>?>(nil)
        let task = Task {
            try await operations.run(batch) { progress in
                if progress.done >= 100 {
                    running.withLock { $0?.cancel() }
                }
            }
        }
        running.withLock { $0 = task }
        let outcome = try await task.value
        #expect(outcome.state == .stopped && outcome.done < batch.steps.count)

        var renamed = 0
        let files = Set(sandbox.photoFiles().keys)
        for (number, photo) in photos.enumerated() {
            let name = String(format: "Shoot-%04d.JPG", number + 1)
            if files.contains(name) {
                renamed += 1
                #expect(try await sandbox.sidecar(name)?.metadata?.originalName == photo.path, "\(name)")
            } else {
                let sidecar = try await sandbox.sidecar(photo.path)
                #expect(photo.sidecar ? sidecar?.metadata?.originalName == nil : sidecar == nil, "\(photo.path)")
            }
        }
        #expect(renamed == outcome.originalNamesRecorded && renamed == FileOperations.namesPerStep, "a step's names")
        #expect(sandbox.leftovers().isEmpty)

        #expect(try await operations.undo().isFinished)
        #expect(Set(sandbox.files().keys) == before, "the sidecars made for the names are gone")
        #expect(sandbox.leftovers().isEmpty)
        for photo in photos where photo.sidecar {
            #expect(try await sandbox.sidecar(photo.path)?.metadata?.originalName == nil, "\(photo.path)")
        }
    }

    @Test func `the index, its lists and the store follow, and no photo is read again`() async throws {
        let watched = WatchedFileSystem()
        let sandbox = try await FileSandbox.make(
            [
                .init("Day 1/DSCF0001.RAF", captured: FileSandbox.date(0)),
                .init("Day 1/DSCF0002.RAF", captured: FileSandbox.date(9)),
            ],
            folders: ["Day 2"], fileSystem: watched,
        )
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
        var dayOne = live.open(.folder(sandbox.url("Day 1"), includingSubfolders: false), sort: QuerySort(.name))
            .makeAsyncIterator()
        var dayTwo = live.open(.folder(sandbox.url("Day 2"), includingSubfolders: false)).makeAsyncIterator()
        let first = try #require(await dayOne.next())
        #expect(try #require(await dayTwo.next()).list.isEmpty)
        let store = PhotoStore(root: sandbox.paths.store)
        defer { store.close() }
        let records = try await sandbox.index
            .read { reader in try first.list.ids.compactMap { try reader.photo(id: $0) } }
        for record in records {
            let key = try #require(record.contentKey.flatMap(ContentKey.init(data:)))
            #expect(store.store(
                Data("thumbnail".utf8),
                for: key,
                tier: .grid,
                size: record.size,
                modified: record.modified,
            ))
        }

        let operations = sandbox.operations(live: live)
        let preview = try await operations.renamePreview(
            NamingTemplate(parsing: "Z-{sequence}"),
            photos: Array(first.list.ids),
        )
        _ = try await operations.run(operations.planRename(preview))
        await live.settle()
        let renamed = try #require(await dayOne.next())
        #expect(Set(renamed.list.ids) == Set(first.list.ids))
        let names = try await engine.list(
            .folder(sandbox.url("Day 1"), includingSubfolders: false),
            sort: QuerySort(.name),
        )
        #expect(names.ids == first.list.ids)

        _ = try await operations.run(operations.planMove(photos: Array(first.list.ids), to: sandbox.url("Day 2")))
        await live.settle()
        #expect(try #require(await dayOne.next()).list.isEmpty)
        #expect(try Set(#require(await dayTwo.next()).list.ids) == Set(first.list.ids))
        #expect(watched.reads == 0 && watched.writes > 0, "no photo was read")
        for record in try await sandbox.index
            .read({ reader in try first.list.ids.compactMap { try reader.photo(id: $0) } }) {
            let key = try #require(record.contentKey.flatMap(ContentKey.init(data:)))
            #expect(store.data(for: key, tier: .grid, size: record.size, modified: record.modified) != nil)
            #expect(record.name.hasPrefix("Z-"))
        }
        let found = try await engine.search(LibraryQuery(parsing: "name:Z-"))
            .reduce(into: [Int64]()) { $0 = Array($1.ids) }
        #expect(Set(found) == Set(first.list.ids))
    }
}
