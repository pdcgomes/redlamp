import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct FileMoveTests {
    private static let photos: [FileSandbox.Photo] = [
        .init("Inbox/IMG_0001.CR3", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
        .init("Inbox/IMG_0001.JPG", captured: FileSandbox.date(0)),
        .init("Inbox/IMG_0002.CR3", captured: FileSandbox.date(1), sidecar: true),
        .init("Inbox/IMG_0003.CR3", captured: FileSandbox.date(2)),
    ]

    /// The sandbox with `Archive` on a simulated volume of its own.
    private static func acrossVolumes() async throws -> (FileSandbox, SimulatedFileSystem) {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make(Self.photos, folders: ["Archive"], fileSystem: simulated)
        simulated.mount(sandbox.url("Archive"), uuid: "ARCHIVE-VOLUME")
        return (sandbox, simulated)
    }

    @Test func `photos move to another folder with their pair and files, keeping their rows`() async throws {
        let sandbox = try await FileSandbox.make(Self.photos, folders: ["Kept"])
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let batch = try await operations.planMove(
            photos: [#require(ids["Inbox/IMG_0001.CR3"])],
            to: sandbox.url("Kept"),
        )
        #expect(batch.title == "Move 2 photos to Kept")
        #expect(try await operations.run(batch).isFinished)
        let after = sandbox.files()
        for name in ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp", "IMG_0001.CR3.redlamp/edit.json"] {
            #expect(after["Kept/" + name] == before["Inbox/" + name] && after["Inbox/" + name] == nil, "\(name)")
        }
        let rows = try await sandbox.rows()
        #expect(rows["Kept/IMG_0001.CR3"] == ids["Inbox/IMG_0001.CR3"] && rows["Kept/IMG_0001.JPG"] ==
            ids["Inbox/IMG_0001.JPG"])

        // A name taken in the folder stops the move.
        try Data("theirs".utf8).write(to: sandbox.url("Kept/IMG_0002.CR3"))
        let blocked = try await operations.planMove(
            photos: [#require(ids["Inbox/IMG_0002.CR3"])],
            to: sandbox.url("Kept"),
        )
        await #expect(throws: FileOperationError.self) { try await operations.run(blocked) }
        #expect(sandbox.files()["Inbox/IMG_0002.CR3.redlamp/edit.json"] != nil)
        await #expect(throws: FileOperationError.notInLibrary(sandbox.folder.url.path)) {
            try await operations.planMove(photos: [#require(ids["Inbox/IMG_0003.CR3"])], to: sandbox.folder.url)
        }
    }

    @Test func `across volumes each file is copied and checked before its original is removed`() async throws {
        let (sandbox, simulated) = try await Self.acrossVolumes()
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let records = try await sandbox.index.read { reader in try ids.values.compactMap { try reader.photo(id: $0) } }
        let operations = sandbox.operations()
        let batch = try await operations.planMove(photos: Array(ids.values), to: sandbox.url("Archive"))
        #expect(batch.steps.allSatisfy { $0.items.allSatisfy(\.copies) })
        #expect(try await operations.run(batch).isFinished)
        let after = sandbox.files()
        for (path, data) in before {
            #expect(after[path.replacingOccurrences(of: "Inbox/", with: "Archive/")] == data, "\(path)")
            #expect(after[path] == nil, "\(path)")
        }
        // Each file: copied under a hidden name, put in place, and only then its original removed.
        let writes = simulated.writes.filter { $0.contains("IMG_0002.CR3 ") || $0.hasSuffix("IMG_0002.CR3") }
        #expect(writes.map { $0.split(separator: " ")[0] } == ["copy", "move", "remove"])
        #expect(sandbox.leftovers().isEmpty)
        let moved = try await sandbox.index.read { reader in try ids.values.compactMap { try reader.photo(id: $0) } }
        for record in moved {
            let original = try #require(records.first { $0.id == record.id })
            let file = try LocalFileSystem().attributes(of: sandbox.url("Archive/" + record.name))
            #expect(record.fileID == file.fileIdentifier && record.fileID != original.fileID)
            #expect(record.size == original.size && record.modified == original.modified)
            #expect(abs(file.modified.timeIntervalSince(original.modified)) < 1e-3, "the copy keeps its date")
            #expect(record.contentKey == original.contentKey)
        }
        #expect(try await operations.undo().isFinished)
        #expect(sandbox.files() == before)
    }

    @Test func `a failed copy leaves every photo where it was, and a bad one is caught before the original goes`(
    ) async throws {
        let (sandbox, simulated) = try await Self.acrossVolumes()
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let order = ["Inbox/IMG_0001.CR3", "Inbox/IMG_0002.CR3", "Inbox/IMG_0003.CR3"].compactMap { ids[$0] }

        simulated.inject(.init(.copy, name: "IMG_0002.CR3", effect: .error(.EIO)))
        await #expect(throws: FileOperationError.self) {
            try await operations.run(operations.planMove(photos: order, to: sandbox.url("Archive")))
        }
        #expect(sandbox.files() == before && sandbox.leftovers().isEmpty)
        #expect(try await sandbox.rows() == ids)
        #expect(try await operations.entries().last?.state == .rolledBack)

        simulated.inject(.init(.copy, name: "IMG_0003.CR3", effect: .corruptCopy))
        do {
            try await operations.run(operations.planMove(photos: order, to: sandbox.url("Archive")))
            Issue.record("a corrupt copy went through")
        } catch let FileOperationError.failed(path, message) {
            #expect(path.hasSuffix("IMG_0003.CR3") && message.contains("isn't the same"))
        }
        #expect(sandbox.files() == before && sandbox.leftovers().isEmpty)
        #expect(simulated.writes.last?.hasPrefix("remove") == true)
        #expect(!simulated.writes.contains { $0 == "remove " + sandbox.url("Inbox/IMG_0003.CR3").path })
    }

    @Test func `a folder moves on its volume as a rename, its rows kept, and across volumes a file at a time`(
    ) async throws {
        let (sandbox, _) = try await Self.acrossVolumes()
        defer { sandbox.remove() }
        let before = sandbox.files()
        let ids = try await sandbox.rows()
        let operations = sandbox.operations()
        let folderID = try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/Inbox")?.id }

        let renamed = try await operations.planMove(folder: sandbox.url("Inbox"), to: sandbox.url("Trips/Lisbon"))
        await #expect(throws: FileOperationError.self) { try await operations.run(renamed) }
        try FileManager.default.createDirectory(at: sandbox.url("Trips"), withIntermediateDirectories: true)
        #expect(try await operations.run(operations.planMove(
            folder: sandbox.url("Inbox"), to: sandbox.url("Trips/Lisbon"),
        )).isFinished)
        #expect(try await sandbox.index
            .read { try $0.folder(path: sandbox.rootPath + "/Trips/Lisbon")?.id } == folderID)
        let rows = try await sandbox.rows()
        #expect(rows["Trips/Lisbon/IMG_0002.CR3"] == ids["Inbox/IMG_0002.CR3"] && rows.count == ids.count)

        let across = try await operations.planMove(
            folder: sandbox.url("Trips/Lisbon"),
            to: sandbox.url("Archive/Lisbon"),
        )
        #expect(across.steps.contains { $0.kind == .createFolder } && across.steps
            .contains { $0.kind == .removeFolder })
        #expect(try await operations.run(across).isFinished)
        let archived = sandbox.files()
        for (path, data) in before {
            #expect(archived[path.replacingOccurrences(of: "Inbox/", with: "Archive/Lisbon/")] == data, "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("Trips/Lisbon").path))
        let moved = try await sandbox.rows()
        #expect(moved["Archive/Lisbon/IMG_0001.JPG"] == ids["Inbox/IMG_0001.JPG"] && moved.count == ids.count)

        #expect(try await operations.undo().isFinished)
        #expect(try await operations.undo().isFinished)
        #expect(sandbox.files() == before)
        #expect(try await sandbox.rows() == ids)
    }

    @Test func `a new folder is made, given a row, and undone while it's empty`() async throws {
        let sandbox = try await FileSandbox.make([.init("A/IMG_0001.JPG")])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        #expect(try await operations.run(operations.planNewFolder(sandbox.url("A/Picks"))).isFinished)
        let folder = try #require(try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/A/Picks") })
        #expect(folder.isIndexed)
        await #expect(throws: FileOperationError.conflicts([
            FileConflict(path: sandbox.rootPath + "/A/Picks", reason: .taken),
        ])) { try await operations.run(operations.planNewFolder(sandbox.url("A/Picks"))) }
        #expect(try await operations.undo().isFinished)
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("A/Picks").path))
        #expect(try await sandbox.index.read { try $0.folder(path: sandbox.rootPath + "/A/Picks") } == nil)
    }
}
