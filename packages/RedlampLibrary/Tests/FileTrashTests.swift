import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Moves to the Trash, on a simulated volume whose Trash is a folder of the sandbox's.
struct FileTrashTests {
    private static func sandbox(onThisMac: Bool = false) async throws -> (FileSandbox, SimulatedFileSystem, URL) {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make([
            .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
            .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0)),
            .init("Shoot/IMG_0002.ARW", captured: FileSandbox.date(1), sidecar: true, xmp: .name),
            .init("Shoot/Day 2/IMG_0003.ARW", captured: FileSandbox.date(2), sidecar: true),
        ], onThisMac: onThisMac, fileSystem: simulated)
        let trash = sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory)
        simulated.useTrash(trash)
        return (sandbox, simulated, trash)
    }

    @Test func `photos go to the Trash with their sidecars, out of the index, and Undo puts them back`() async throws {
        for onThisMac in [false, true] {
            let (sandbox, _, trash) = try await Self.sandbox(onThisMac: onThisMac)
            defer { sandbox.remove() }
            let before = sandbox.files()
            let ids = try await sandbox.rows()
            let keywords = ["Places/Portugal", "Clients/Acme"]
            try await sandbox.index.write { try $0.setKeywords(keywords, forPhoto: ids["Shoot/IMG_0002.ARW"]!) }
            let engine = QueryEngine(index: sandbox.index)
            try await engine.load()
            let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
            var all = live.open(.allPhotographs).makeAsyncIterator()
            #expect(try #require(await all.next()).list.count == 4)
            let operations = sandbox.operations(live: live)

            let batch = try await operations.planTrash(photos: [
                #require(ids["Shoot/IMG_0001.ARW"]),
                #require(ids["Shoot/IMG_0002.ARW"]),
            ])
            #expect(batch.title == "Move 2 photos to the Trash")
            #expect(try await operations.run(batch).isFinished)
            let left = Set(sandbox.files().keys)
            #expect(left.allSatisfy { !$0.contains("IMG_0002") }, "\(left)")
            #expect(
                left.contains("Shoot/IMG_0001.JPG") && left.contains("Shoot/IMG_0001.xmp"),
                "the JPEG keeps the stem's xmp",
            )
            let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
            #expect(trashed.contains("IMG_0002.ARW") && trashed.contains("IMG_0002.ARW.xmp"))
            #expect(trashed.contains("IMG_0002.ARW.redlamp") && trashed.contains("IMG_0001.ARW.redlamp"))
            let rows = try await sandbox.rows()
            #expect(rows.count == 2 && rows["Shoot/IMG_0001.JPG"] == ids["Shoot/IMG_0001.JPG"])
            await live.settle()
            #expect(try #require(await all.next()).list.count == 2)

            #expect(try await operations.undo().isFinished)
            #expect(sandbox.files() == before)
            #expect(try await sandbox.rows() == ids, "the rows came back under their IDs")
            #expect(try await sandbox.index.read { try $0.keywords(forPhoto: ids["Shoot/IMG_0002.ARW"]!) } == keywords
                .sorted())
            await live.settle()
            #expect(try #require(await all.next()).list.count == 4)
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        }
    }

    @Test func `a plan made elsewhere goes through the same Trash step, its photos named with their files`(
    ) async throws {
        let (sandbox, _, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let duplicates = try [
            PhotoFiles(
                id: #require(ids["Shoot/Day 2/IMG_0003.ARW"]),
                files: [sandbox.url("Shoot/Day 2/IMG_0003.ARW")],
            ),
            PhotoFiles(id: #require(ids["Shoot/IMG_0001.JPG"])),
        ]
        #expect(try await operations.run(operations.planTrash(duplicates)).isFinished)
        let trashed = try Set(FileManager.default.contentsOfDirectory(atPath: trash.path))
        #expect(trashed == ["IMG_0003.ARW", "IMG_0003.ARW.redlamp", "IMG_0001.JPG"])
        #expect(try await sandbox.rows().count == 2)
    }

    @Test func `photos the index no longer has are left out of the batch, which says which`() async throws {
        let (sandbox, _, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let (kept, gone) = try (#require(ids["Shoot/IMG_0002.ARW"]), #require(ids["Shoot/Day 2/IMG_0003.ARW"]))
        try await sandbox.index.write { try $0.deletePhotos([gone]) }

        let batch = try await operations.planTrash(photos: [kept, gone])
        #expect(batch.notInIndex == [gone] && batch.title == "Move 1 photo to the Trash")
        let outcome = try await operations.run(batch)
        #expect(outcome.isFinished && outcome.photos == 1 && outcome.notInIndex == [gone])
        let trashed = try Set(FileManager.default.contentsOfDirectory(atPath: trash.path))
        #expect(trashed == ["IMG_0002.ARW", "IMG_0002.ARW.redlamp", "IMG_0002.ARW.xmp"])
        #expect(FileManager.default.fileExists(atPath: sandbox.url("Shoot/Day 2/IMG_0003.ARW").path))

        let nothing = try await operations.planTrash(photos: [gone])
        #expect(nothing.steps.isEmpty && nothing.notInIndex == [gone])
        #expect(try await operations.run(nothing).notInIndex == [gone])
    }

    @Test func `undoing puts back what's still in the Trash and says what isn't`() async throws {
        let (sandbox, _, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        try await operations.run(operations.planTrash(photos: [
            #require(ids["Shoot/IMG_0002.ARW"]),
            #require(ids["Shoot/Day 2/IMG_0003.ARW"]),
        ]))
        try FileManager.default.removeItem(at: trash.appending(path: "IMG_0003.ARW"))
        let undone = try await operations.undo()
        #expect(undone.isFinished && undone.gone == [sandbox.rootPath + "/Shoot/Day 2/IMG_0003.ARW"])
        let files = Set(sandbox.files().keys)
        #expect(files.contains("Shoot/IMG_0002.ARW") && files.contains("Shoot/IMG_0002.ARW.redlamp/edit.json"))
        #expect(!files.contains("Shoot/Day 2/IMG_0003.ARW"))
        #expect(try await sandbox.rows()["Shoot/IMG_0002.ARW"] == ids["Shoot/IMG_0002.ARW"])
    }

    @Test func `a Trash that can't be listed still gives back what's in it, and an Undo left nothing changes nothing`(
    ) async throws {
        let (sandbox, _, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        try await operations.run(operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])]))
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: trash.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) }
        #expect(throws: (any Error).self) { try FileManager.default.contentsOfDirectory(atPath: trash.path) }
        #expect(try await operations.undo().isFinished)
        #expect(try await sandbox.rows()["Shoot/IMG_0002.ARW"] == ids["Shoot/IMG_0002.ARW"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path)

        try await operations.run(operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])]))
        for name in try FileManager.default.contentsOfDirectory(atPath: trash.path) {
            try FileManager.default.removeItem(at: trash.appending(path: name))
        }
        let trashed = try await operations.lastUndoable()
        await #expect(throws: FileOperationError.self) { try await operations.undo() }
        #expect(try await operations.lastUndoable()?.id == trashed?.id, "it can be undone once the files are back")
    }

    @Test func `a folder goes to the Trash with its photos' rows, and comes back with them`() async throws {
        let (sandbox, _, trash) = try await Self.sandbox(onThisMac: true)
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let folder = try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/Shoot/Day 2") }
        #expect(try await operations.run(operations.planTrash(folder: sandbox.url("Shoot/Day 2"))).isFinished)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 2,
            "the folder and its sidecars",
        )
        #expect(try await sandbox.rows().count == 3)
        #expect(try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/Shoot/Day 2") } == nil)
        #expect(try await operations.undo().isFinished)
        #expect(sandbox.files() == before)
        #expect(try await sandbox.rows() == ids)
        #expect(try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/Shoot/Day 2") }?.id == folder?
            .id)
        await #expect(throws: FileOperationError.isRoot(sandbox.rootPath)) {
            try await operations.planTrash(folder: sandbox.root)
        }
    }

    /// `row` with a value other than its default in every field the file operations don't check
    /// against the file.
    private static func filled(_ row: PhotoRecord) -> PhotoRecord {
        var row = row
        row.captured = FileSandbox.date(7)
        row.capturedOffset = 3600
        row.camera = row.camera ?? 1
        row.lens = row.lens ?? 1
        row.iso = 400
        row.aperture = 2.8
        row.shutter = 1 / 250
        row.focal = 35
        row.width = 6000
        row.height = 4000
        row.orientation = 6
        row.latitude = 38.7
        row.longitude = -9.1
        row.rating = 4
        row.flag = .pick
        row.label = .green
        row.marked = true
        row.edited = true
        row.sidecarModified = FileSandbox.date(8)
        row.xmpModified = FileSandbox.date(9)
        row.title = "Tram 28"
        row.caption = "Alfama, before the rain"
        row.state = [.settling]
        row.indexed = 3
        row.customLabel = "Urgent"
        row.creator = "Ana Sousa"
        row.copyright = "© Ana Sousa"
        row.location = PhotoLocation(
            country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Alfama", countryCode: "PT",
        )
        row.stack = PhotoStack(id: UUID(), top: true, position: 0)
        row.otherFields = [.creator, .location]
        row.xmpSignature = 42
        row.cameraCaptured = FileSandbox.date(10)
        row.cameraOffset = -18000
        return row
    }

    @Test func `every field of a photo's row is carried through the journal and back`() throws {
        let row = Self.filled(PhotoRecord(
            id: 9, folder: 3, name: "IMG_0009.ARW", kind: .raw, size: 25_000_000, modified: FileSandbox.date(6),
            fileID: 77, contentKey: Data(repeating: 5, count: 16),
        ))
        let unset = PhotoRecord(folder: 0, name: "")
        let defaults = Dictionary(uniqueKeysWithValues: Mirror(reflecting: unset).children.map {
            ($0.label ?? "", String(describing: $0.value))
        })
        for field in Mirror(reflecting: row).children {
            #expect(
                String(describing: field.value) != defaults[field.label ?? ""],
                "\(field.label ?? "?") is left at its default: give it a value here, and carry it in IndexedPhoto",
            )
        }
        #expect(IndexedPhoto(row).record(inFolder: row.folder) == row)
        let journaled = try JSONDecoder().decode(IndexedPhoto.self, from: JSONEncoder().encode(IndexedPhoto(row)))
        #expect(journaled.record(inFolder: row.folder) == row)
    }

    @Test func `a photo brought back by Undo or Put Back has its whole row back`() async throws {
        let (sandbox, _, _) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let id = try #require(ids["Shoot/IMG_0002.ARW"])
        let row = try await sandbox.index.write { writer in
            var row = try Self.filled(#require(try writer.photo(id: id)))
            // A camera and a lens the index has: one it doesn't was another index's, and has the photo read again.
            row.camera = try writer.cameraID(for: "Sony ILCE-7RM5")
            row.lens = try writer.lensID(for: "FE 35mm F1.4 GM")
            _ = try writer.upsertPhotos([row])
            return try writer.photo(id: id)
        }
        #expect(row != nil && row?.stack != nil && row?.location != nil)
        let operations = sandbox.operations()

        let trash = try await operations.planTrash(photos: [id])
        try await operations.run(trash)
        #expect(try await operations.undo().isFinished)
        #expect(try await sandbox.index.read { try $0.photo(id: id) } == row)

        let again = try await operations.planTrash(photos: [id])
        try await operations.run(again)
        #expect(try await operations.run(operations.planPutBack(batch: again.id)).isFinished)
        #expect(try await sandbox.index.read { try $0.photo(id: id) } == row)
    }

    @Test func `a photo trashed from the middle of a reordered stack comes back to its place, by Undo and by Put Back`(
    ) async throws {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let names = ["A", "B", "C", "D"].map { "Shoot/\($0).ARW" }
        let sandbox = try await FileSandbox.make(
            names.enumerated().map { .init($1, captured: FileSandbox.date(Double($0))) }, fileSystem: simulated,
        )
        defer { sandbox.remove() }
        simulated.useTrash(sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory))
        let ids = try await sandbox.rows()
        let photos = try names.map { try #require(ids[$0]) }
        func stacks() async throws -> Stacks {
            let engine = QueryEngine(index: sandbox.index)
            try await engine.load()
            return try await StackFinder.find(in: sandbox.index, store: engine.store ?? ColumnStore())
        }
        /// The stack's photos by name, in its order.
        func order() async throws -> [String] {
            let stack = try await stacks().first { $0.kind == .manual }?.photos ?? []
            return try await sandbox.index.read { reader in try stack.compactMap { try reader.photo(id: $0)?.name } }
        }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.run(metadata.plan(.stack(photos, top: photos[0]), in: stacks()))
        try await metadata.run(metadata.plan(.move(photos[3], by: -3), in: stacks()))
        let reordered = ["D.ARW", "A.ARW", "B.ARW", "C.ARW"]
        #expect(try await order() == reordered)
        let middle = photos[1]
        func place() async throws -> Int? {
            try await sandbox.index.read { try $0.photo(id: middle)?.stack?.position }
        }
        #expect(try await place() == 2)
        let operations = sandbox.operations()

        try await operations.run(operations.planTrash(photos: [middle]))
        #expect(try await order() == ["D.ARW", "A.ARW", "C.ARW"], "the others keep their places")
        #expect(try await operations.undo().isFinished)
        #expect(try await order() == reordered, "Undo puts it back in its place")
        #expect(try await place() == 2)

        let trashed = try await operations.planTrash(photos: [middle])
        try await operations.run(trashed)
        #expect(try await operations.run(operations.planPutBack(batch: trashed.id)).isFinished)
        #expect(try await order() == reordered, "Put Back puts it back in its place")
        #expect(try await place() == 2)
        #expect(try await sandbox.sidecar("Shoot/B.ARW")?.metadata?.stack?.position == 2, "its sidecar keeps it too")

        // A batch an older build journaled has no places: the photo comes back in its stack, after the others.
        let older = try await operations.planTrash(photos: [middle])
        try await operations.run(older)
        let file = operations.journal.folder.appending(path: FileJournal.fileName(of: older) + ".batch")
        let journaled = try String(contentsOf: file, encoding: .utf8)
        #expect(journaled.contains("\"stackPosition\":2"))
        try Data(journaled.replacingOccurrences(of: ",\"stackPosition\":2", with: "").utf8).write(to: file)
        #expect(try await sandbox.operations().undo().isFinished)
        #expect(try await order() == ["D.ARW", "A.ARW", "C.ARW", "B.ARW"])
        #expect(try await place() == nil)
    }

    @Test func `a Trash batch journaled before rows kept stacks and other apps' fields still undoes`() async throws {
        let (sandbox, _, _) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let id = try #require(ids["Shoot/IMG_0002.ARW"])
        let trashed = try await sandbox.operations().planTrash(photos: [id])
        try await sandbox.operations().run(trashed)

        let added = [
            "customLabel", "creator", "copyright", "sublocation", "city", "province", "country", "countryCode",
            "stack", "stackTop", "otherFields", "xmpSignature", "stackPosition",
        ]
        func old(_ value: Any) -> Any {
            if let array = value as? [Any] {
                return array.map(old)
            }
            guard var object = value as? [String: Any] else { return value }
            if object["indexed"] != nil, object["state"] != nil {
                for key in added {
                    object[key] = nil
                }
            }
            return object.mapValues(old)
        }
        let folder = sandbox.operations().journal.folder
        let file = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "batch" })
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            try String(decoding: JSONSerialization.data(
                withJSONObject: old(JSONSerialization.jsonObject(with: Data(line.utf8))),
                options: [.sortedKeys, .withoutEscapingSlashes],
            ), as: UTF8.self)
        }
        let rewritten = lines.joined(separator: "\n") + "\n"
        #expect(added.allSatisfy { !rewritten.contains("\"\($0)\"") }, "\(rewritten)")
        try Data(rewritten.utf8).write(to: file)

        let launch = sandbox.operations()
        let removed = try #require(try launch.journal.load(trashed.id).batch.steps.first { $0.kind == .trash }?.removed
            .first)
        #expect(removed.photo.stackTop == nil && removed.photo.otherFields == nil && removed.photo.creator == nil)
        #expect(try await launch.undo().isFinished)
        let row = try #require(try await sandbox.index.read { try $0.photo(id: id) })
        #expect(row.name == "IMG_0002.ARW" && row.stack == nil && row.otherFields.isEmpty && row.contentKey != nil)
    }
}
