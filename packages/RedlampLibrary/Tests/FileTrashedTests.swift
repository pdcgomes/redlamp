import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Recently Trashed (LIB-26): what the batches moved to the Trash that's still there, from the
/// journal, on a simulated volume whose Trash is a folder of the sandbox's.
struct FileTrashedTests {
    /// A raw and its JPEG, the raw with a sidecar and a `.xmp` named after them both; a raw with a
    /// sidecar and a `.xmp` of its own; and a raw in a folder of its own.
    static let photos: [FileSandbox.Photo] = [
        .init("Shoot/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
        .init("Shoot/IMG_0001.JPG", captured: FileSandbox.date(0)),
        .init("Shoot/IMG_0002.ARW", captured: FileSandbox.date(1), sidecar: true, xmp: .name),
        .init("Shoot/Day 2/IMG_0003.ARW", captured: FileSandbox.date(2), sidecar: true),
    ]

    /// The photos, and the Trash their simulated volume keeps in the sandbox's folder.
    static func sandbox(
        onThisMac: Bool = false, through wrap: (SimulatedFileSystem) -> any LibraryFileSystem = { $0 },
    ) async throws -> (FileSandbox, URL) {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make(photos, onThisMac: onThisMac, fileSystem: wrap(simulated))
        let trash = sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory)
        simulated.useTrash(trash)
        return (sandbox, trash)
    }

    @Test func `a batch's trashed photos are listed, newest first, with their sidecars, .xmp and pairs`() async throws {
        for onThisMac in [false, true] {
            let (sandbox, trash) = try await Self.sandbox(onThisMac: onThisMac)
            defer { sandbox.remove() }
            let ids = try await sandbox.rows()
            let keys = try await sandbox.index.read { reader in
                try ids.compactMapValues { try reader.photo(id: $0)?.contentKey }
            }
            let operations = sandbox.operations()
            let first = try await operations.planTrash(photos: [#require(ids["Shoot/IMG_0002.ARW"])])
            #expect(try await operations.run(first).isFinished)
            let second = try await operations.planTrash(photos: [
                #require(ids["Shoot/IMG_0001.ARW"]),
                #require(ids["Shoot/IMG_0001.JPG"]),
            ])
            #expect(try await operations.run(second).isFinished)

            let listed = try await operations.trashed()
            let paths = ["Shoot/IMG_0001.ARW", "Shoot/IMG_0001.JPG", "Shoot/IMG_0002.ARW"]
            #expect(listed.map(\.original) == paths.map { sandbox.rootPath + "/" + $0 })
            #expect(listed.map(\.place) == paths.map { trash.appending(path: FilePlanner.split($0).name).path })
            #expect(listed.map(\.id.photo) == paths.map { ids[$0] })
            #expect(listed.map(\.id.batch) == [second.id, second.id, first.id])
            #expect(listed.map(\.title) == [second.title, second.title, first.title])
            #expect(abs(listed[0].trashed.timeIntervalSince(second.created)) < 1e-3)
            #expect(abs(listed[2].trashed.timeIntervalSince(first.created)) < 1e-3)
            #expect(listed.map(\.photo.photo.contentKey) == paths.map { keys[$0] }, "the rows as they were")

            let sidecar: FileItem.Role = onThisMac ? .sidecarOnThisMac : .sidecar
            #expect(listed.map { $0.files.map(\.role) } == [[sidecar, .otherApp], [], [sidecar, .otherApp]])
            #expect(listed.map { $0.files.map { FilePlanner.split($0.original).name } } == [
                ["IMG_0001.ARW.redlamp", "IMG_0001.xmp"], [], ["IMG_0002.ARW.redlamp", "IMG_0002.ARW.xmp"],
            ])
            #expect(listed.flatMap(\.files).allSatisfy { FilePlanner.split($0.place).folder == trash.path })
            #expect(listed[0].pair == [listed[1].id] && listed[1].pair == [listed[0].id] && listed[2].pair.isEmpty)
            #expect(listed.allSatisfy { $0.folder == nil })
        }
    }

    @Test func `an item emptied from the Trash, put back by Finder or replaced there isn't listed`() async throws {
        let (sandbox, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        try await operations.run(operations.planTrash(photos: Self.photos.compactMap { ids[$0.path] }))
        #expect(try await operations.trashed().count == 4)

        try FileManager.default.removeItem(at: trash.appending(path: "IMG_0002.ARW"))
        try FileManager.default.removeItem(at: trash.appending(path: "IMG_0001.JPG"))
        try Data("another photo, under its name".utf8).write(to: trash.appending(path: "IMG_0001.JPG"))
        try FileManager.default.moveItem(
            at: trash.appending(path: "IMG_0003.ARW"), to: sandbox.url("Shoot/Day 2/IMG_0003.ARW"),
        )
        var listed = try await operations.trashed()
        #expect(listed.map(\.original) == [sandbox.rootPath + "/Shoot/IMG_0001.ARW"])
        #expect(listed.first?.pair == [], "its JPEG isn't in the Trash any more")

        try FileManager.default.removeItem(at: trash.appending(path: "IMG_0001.ARW.redlamp"))
        listed = try await operations.trashed()
        #expect(listed.first?.files.map { FilePlanner.split($0.original).name } == ["IMG_0001.xmp"])

        let handle = try FileHandle(forWritingTo: trash.appending(path: "IMG_0001.ARW"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
        #expect(try await operations.trashed().isEmpty, "written in place, it isn't the photo the batch moved")
    }

    @Test func `a folder that went to the Trash whole lists the photos still in it`() async throws {
        let (sandbox, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        #expect(try await operations.run(operations.planTrash(folder: sandbox.url("Shoot/Day 2"))).isFinished)

        let listed = try await operations.trashed()
        #expect(listed.map(\.original) == [sandbox.rootPath + "/Shoot/Day 2/IMG_0003.ARW"])
        #expect(listed.map(\.place) == [trash.appending(path: "Day 2/IMG_0003.ARW").path])
        #expect(listed.map(\.folder) == [sandbox.rootPath + "/Shoot/Day 2"])
        #expect(listed.map(\.id.photo) == [ids["Shoot/Day 2/IMG_0003.ARW"]])
        try FileManager.default.removeItem(at: trash.appending(path: "Day 2/IMG_0003.ARW"))
        #expect(try await operations.trashed().isEmpty)
    }

    @Test func `its followers hear when Recently Trashed changes, after each batch and when its Trash does`(
    ) async throws {
        let (sandbox, trash) = try await Self.sandbox()
        defer { sandbox.remove() }
        let events = ScriptedEvents()
        let operations = sandbox.operations(trashEvents: events)
        let ids = try await sandbox.rows()
        var updates = operations.trashedUpdates().makeAsyncIterator()
        #expect(try #require(await updates.next()).isEmpty)

        try await operations.run(operations.planTrash(photos: [
            #require(ids["Shoot/IMG_0002.ARW"]),
            #require(ids["Shoot/Day 2/IMG_0003.ARW"]),
        ]))
        let trashed = try #require(await updates.next())
        #expect(trashed.map(\.id.photo) == [ids["Shoot/IMG_0002.ARW"], ids["Shoot/Day 2/IMG_0003.ARW"]])
        try await operations.run(operations.planPutBack([trashed[0].id]))
        #expect(try #require(await updates.next()).map(\.id) == [trashed[1].id])

        // Emptied from the Trash, as the Trash folder's events say.
        let deadline = ContinuousClock.now + .seconds(30)
        while events.subscriptions == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events.subscriptions == 1, "the Trash folder is followed")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: trashed[1].place))
        events.send([(trash.path, [])])
        #expect(try #require(await updates.next()).isEmpty)

        // Or when asked, as when the app becomes active.
        try await operations.run(operations.planTrash(photos: [#require(ids["Shoot/IMG_0001.JPG"])]))
        let again = try #require(await updates.next())
        #expect(again.map(\.id.photo) == [ids["Shoot/IMG_0001.JPG"]])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: again[0].place))
        operations.checkTrash()
        #expect(try #require(await updates.next()).isEmpty)
    }
}
