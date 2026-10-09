import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Copies (LIB-26): photos copied into a folder with their pairs and files, each copy a photo of its own under a
/// new ID with its original's sidecar but none of its collections and not its stack; a name that's held given a
/// number, as the Finder numbers a copy; Undo moving the copies to the Trash, a folder of the sandbox's on its
/// simulated volume; and a copy a forced quit cut short finished or rolled back at the next launch.
struct FileCopyTests {
    private static func sandbox(
        _ photos: [FileSandbox.Photo], folders: [String] = ["Picked"], onThisMac: Bool = false,
    ) async throws -> (FileSandbox, URL) {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make(photos, onThisMac: onThisMac, folders: folders, fileSystem: simulated)
        let trash = sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory)
        simulated.useTrash(trash)
        return (sandbox, trash)
    }

    /// Puts the photo at `path` in the collection Selects and a stack, with a keyword, in its sidecar and its row.
    private static func organise(_ path: String, in sandbox: FileSandbox) async throws -> Int64 {
        let store = try await sandbox.store()
        let url = sandbox.url(path)
        var sidecar = store.load(for: url) ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        metadata.keywords = ["Places/Lisbon"]
        metadata.collections = ["Selects"]
        metadata.stack = PhotoStack(id: UUID(), top: true)
        sidecar.metadata = metadata
        try store.save(sidecar, for: url)
        let id = try #require(try await sandbox.rows()[path])
        let (stack, rating) = (metadata.stack, metadata.rating)
        try await sandbox.index.write { writer in
            try writer.setKeywords(["Places/Lisbon"], forPhoto: id)
            try writer.setCollections(["Selects"], forPhoto: id)
            guard var record = try writer.photo(id: id) else { return }
            record.stack = stack
            record.rating = rating
            try writer.upsertPhotos([record])
        }
        return id
    }

    @Test func `photos copied into a folder take their pair, sidecars and other apps' files, as photos of their own in no collection or stack, and Undo moves the copies to the Trash`(
    ) async throws {
        for onThisMac in [false, true] {
            let (sandbox, trash) = try await Self.sandbox([
                .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
                .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0), sidecar: true),
                .init("Shoot/IMG_0002.ARW", captured: FileSandbox.date(1)),
            ], onThisMac: onThisMac)
            defer { sandbox.remove() }
            let raw = try await Self.organise("Shoot/IMG_0001.ARW", in: sandbox)
            let rows = try await sandbox.rows()
            let jpeg = try #require(rows["Shoot/IMG_0001.JPG"])
            let before = sandbox.files()
            let operations = sandbox.operations()

            let batch = try await operations.planCopy(photos: [raw], to: sandbox.url("Picked"))
            #expect(batch.kind == .copy && batch.title == "Copy 2 photos to Picked", "the pair goes with the raw")
            let outcome = try await operations.run(batch)
            #expect(outcome.isFinished && outcome.photos == 2 && Set(outcome.photoIDs) == [raw, jpeg])
            #expect(outcome.copiesNotDetached.isEmpty)

            let after = sandbox.files()
            for (path, data) in before {
                #expect(after[path] == data, "\(path) is as it was")
            }
            for name in ["IMG_0001.ARW", "IMG_0001.JPG", "IMG_0001.xmp"] {
                #expect(after["Picked/" + name] == before["Shoot/" + name], "\(name) is copied byte for byte")
            }
            let copies = try await sandbox.rows()
            #expect(copies.count == rows.count + 2)
            let copyRaw = try #require(copies["Picked/IMG_0001.ARW"])
            let copyJPEG = try #require(copies["Picked/IMG_0001.JPG"])
            #expect(Set([copyRaw, copyJPEG]).isDisjoint(with: rows.values), "the copies have IDs of their own")
            #expect(copies.filter { !$0.key.hasPrefix("Picked/") } == rows, "the originals keep theirs")

            let copied = try #require(try await sandbox.sidecar("Picked/IMG_0001.ARW")?.metadata)
            #expect(copied.rating == 3 && copied.label == .green && copied.keywords == ["Places/Lisbon"])
            #expect(copied.collections.isEmpty && copied.stack == nil && copied.originalName == nil)
            #expect(try await sandbox.sidecar("Picked/IMG_0001.JPG")?.metadata?.rating == 3)
            let original = try #require(try await sandbox.sidecar("Shoot/IMG_0001.ARW")?.metadata)
            #expect(original.collections == ["Selects"] && original.stack != nil, "the original keeps its own")

            let (row, originalRow, keywords, collections, text) = try await sandbox.index.read { reader in
                let text = try reader.database.prepare("SELECT count(*) FROM photo_text WHERE rowid = ?")
                try text.bind(copyRaw, at: 1)
                return try (
                    reader.photo(id: copyRaw), reader.photo(id: raw), reader.keywords(forPhoto: copyRaw),
                    reader.collections(ofPhoto: copyRaw), text.first { $0.int64(at: 0) } ?? 0,
                )
            }
            let copyRow = try #require(row)
            #expect(copyRow.contentKey == originalRow?.contentKey, "the store's thumbnails serve the copy")
            #expect(copyRow.rating == 3 && copyRow.stack == nil && keywords == ["Places/Lisbon"])
            #expect(collections.isEmpty, "a copy isn't in its original's collections")
            #expect(text == 1, "the copy is in the text index")
            let file = try sandbox.fileSystem.attributes(of: sandbox.url("Picked/IMG_0001.ARW"))
            #expect(copyRow.fileID == file.fileIdentifier && copyRow.fileID != originalRow?.fileID)

            #expect(try await operations.undo().isFinished)
            #expect(sandbox.files() == before, "the copies left, the originals as they were")
            #expect(try await sandbox.rows() == rows)
            let trashed = FileSandbox.contents(of: trash)
            #expect(trashed["IMG_0001.ARW"] == before["Shoot/IMG_0001.ARW"] && trashed["IMG_0001.xmp"] != nil)
            #expect(try await Set(operations.trashed().map(\.photo.photo.id)) == [copyRaw, copyJPEG])
            #expect(try await operations.entries().map(\.state) == [.undone, .finished])
        }
    }

    @Test func `a copy whose name is held gets a number, its pair and sidecars with it, and its original's name`(
    ) async throws {
        let (sandbox, _) = try await Self.sandbox([
            .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true),
            .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0)),
            .init("Shoot/Photo 2.JPG", captured: FileSandbox.date(1)),
            .init("Card/IMG_0001.JPG", captured: FileSandbox.date(2)),
            .init("Picked/IMG_0001.JPG", captured: FileSandbox.date(3)),
            .init("Picked/Photo 2.JPG", captured: FileSandbox.date(4)),
        ])
        defer { sandbox.remove() }
        try Data("another app's".utf8).write(to: sandbox.url("Picked/IMG_0001 2.xmp"))
        let rows = try await sandbox.rows()
        let operations = sandbox.operations()
        let ids = try ["Shoot/IMG_0001.ARW", "Card/IMG_0001.JPG", "Shoot/Photo 2.JPG"].map { try #require(rows[$0]) }
        #expect(try await operations.run(operations.planCopy(photos: ids, to: sandbox.url("Picked"))).isFinished)

        let picked = Set(sandbox.photoFiles().keys.filter { $0.hasPrefix("Picked/") })
        #expect(picked == [
            "Picked/IMG_0001.JPG", "Picked/Photo 2.JPG", "Picked/IMG_0001 3.ARW", "Picked/IMG_0001 3.JPG",
            "Picked/IMG_0001 4.JPG", "Picked/Photo 3.JPG",
        ], "IMG_0001 2 is held by another app's sidecar; a name ending in a number goes on from it")
        #expect(sandbox.photoFiles()["Picked/IMG_0001 3.ARW"] == sandbox.photoFiles()["Shoot/IMG_0001.ARW"])
        let raw = try #require(try await sandbox.sidecar("Picked/IMG_0001 3.ARW")?.metadata)
        #expect(raw.originalName == "IMG_0001.ARW" && raw.rating == 3, "its sidecar with it, and its original's name")
        for (copy, original) in [
            ("Picked/IMG_0001 3.JPG", "IMG_0001.JPG"), ("Picked/IMG_0001 4.JPG", "IMG_0001.JPG"),
            ("Picked/Photo 3.JPG", "Photo 2.JPG"),
        ] {
            #expect(try await sandbox.sidecar(copy)?.metadata?.originalName == original, "\(copy)")
        }
        #expect(try await sandbox.sidecar("Picked/IMG_0001.JPG") == nil, "the photo already there is left alone")

        // Into the folder they're in.
        #expect(try await operations.run(operations.planCopy(photos: [ids[0]], to: sandbox.url("Shoot"))).isFinished)
        let shoot = Set(sandbox.photoFiles().keys.filter { $0.hasPrefix("Shoot/") })
        #expect(shoot.isSuperset(of: ["Shoot/IMG_0001 2.ARW", "Shoot/IMG_0001 2.JPG"]) && shoot.count == 5)
        #expect(try await sandbox.rows().count == rows.count + 6)
    }

    /// Names, bytes, and each photo's rating, collections and original name.
    private static func state(_ sandbox: FileSandbox) async throws -> [String: String] {
        var state: [String: String] = [:]
        for (path, data) in sandbox.files() {
            state[path] = path.contains(".redlamp/") ? "sidecar" : String(decoding: data, as: UTF8.self)
        }
        for path in try await sandbox.rows().keys {
            let metadata = try await sandbox.sidecar(path)?.metadata
            state["metadata of " + path] = "\(metadata?.rating ?? 0) \(metadata?.collections ?? []) "
                + "\(metadata?.originalName ?? "-")"
        }
        return state
    }

    @Test(arguments: [FileRecovery.finish, .rollBack])
    func `a copy a forced quit cut short is finished or rolled back at the next launch, each copy whole or not there`(
        _ choice: FileRecovery,
    ) async throws {
        let (sandbox, _) = try await Self.sandbox([
            .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
            .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0), sidecar: true),
            .init("Shoot/IMG_0002.ARW", captured: FileSandbox.date(1), xmp: .name),
            .init("Picked/IMG_0002.ARW", captured: FileSandbox.date(2)),
        ])
        defer { sandbox.remove() }
        _ = try await Self.organise("Shoot/IMG_0001.ARW", in: sandbox)
        let rows = try await sandbox.rows()
        let ids = try ["Shoot/IMG_0001.ARW", "Shoot/IMG_0002.ARW"].map { try #require(rows[$0]) }
        let original = try await Self.state(sandbox)
        let operations = sandbox.operations()
        let batch = try await operations.planCopy(photos: ids, to: sandbox.url("Picked"))
        #expect(batch.steps.map(\.kind) == [.copy, .copy, .detachCopies])
        #expect(try await operations.run(batch).isFinished)
        let copied = try await Self.state(sandbox)
        let copiedPaths = try await Set(sandbox.rows().keys)
        #expect(copied["metadata of Picked/IMG_0001.ARW"] == "3 [] -")
        #expect(copied["metadata of Picked/IMG_0002 2.ARW"] == "0 [] IMG_0002.ARW")
        #expect(try await operations.undo().isFinished)
        #expect(try await Self.state(sandbox) == original)

        var interruptions: [FileOperations.Interruption] = []
        for (index, step) in batch.steps.enumerated() {
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
                try await killed.run(killed.planCopy(photos: ids, to: sandbox.url("Picked")))
            }
            let launch = sandbox.operations()
            #expect(try await launch.unfinishedEntries().count == 1)
            let outcomes = try await launch.recover(choice)
            #expect(outcomes.first?.state == (choice == .finish ? .finished : .rolledBack), "\(interruption)")
            let expected = choice == .finish ? copied : original
            let found = try await Self.state(sandbox)
            #expect(
                found == expected,
                "\(interruption): \(found.filter { expected[$0.key] != $0.value }.keys.sorted())",
            )
            #expect(try await Set(sandbox.rows().keys) == (choice == .finish ? copiedPaths : Set(rows.keys)))
            #expect(try await sandbox.rows().filter { rows[$0.key] != nil } == rows, "\(interruption)")
            #expect(sandbox.leftovers().isEmpty, "\(interruption): \(sandbox.leftovers())")
            if choice == .finish {
                #expect(try await launch.undo().isFinished, "\(interruption)")
                #expect(try await Self.state(sandbox) == original, "\(interruption)")
            }
        }
    }
}
