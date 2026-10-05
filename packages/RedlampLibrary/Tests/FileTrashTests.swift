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

    @Test func `Undo puts back what's still in the Trash and says what isn't`() async throws {
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
}
