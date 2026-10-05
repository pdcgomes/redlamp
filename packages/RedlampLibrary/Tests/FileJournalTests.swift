import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

struct FileJournalTests {
    @Test func `the journal holds the whole batch, synced, before anything moves`() async throws {
        // At each write, the steps of the newest batch in the journal, -1 for none.
        let seen = Mutex<[Int]>([])
        let journal = Mutex<FileJournal?>(nil)
        let watched = WatchedFileSystem { _ in
            guard let journal = journal.withLock({ $0 }) else { return }
            let steps = (try? journal.entries().last).flatMap { entry in
                try? journal.load(entry.id).batch.steps.count
            } ?? -1
            seen.withLock { $0.append(steps) }
        }
        let sandbox = try await FileSandbox.make(
            [.init("A/IMG_0001.ARW", sidecar: true), .init("A/IMG_0002.ARW", xmp: .stem)], fileSystem: watched,
        )
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        journal.withLock { $0 = operations.journal }
        let preview = try await operations.renamePreview(
            NamingTemplate(parsing: "B-{sequence}"), photos: Array(sandbox.rows().values),
        )
        let batch = try await operations.planRename(preview)
        #expect(try await operations.run(batch).isFinished)
        let counts = seen.withLock { $0 }
        #expect(counts.count == watched.writes && counts.allSatisfy { $0 == batch.steps.count }, "\(counts)")
        let files = try FileManager.default.contentsOfDirectory(atPath: operations.journal.folder.path)
        #expect(files.filter { $0.hasSuffix(".batch") }.count == 1 && files.filter { $0.hasSuffix(".log") }.count == 1)
        #expect(files.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func `the journal lists each batch with what became of it, and reads past a line cut short`() async throws {
        let sandbox = try await FileSandbox.make([.init("A/IMG_0001.ARW"), .init("A/IMG_0002.ARW")])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let ids = try await sandbox.rows()
        try await operations.run(operations.planRename(operations.renamePreview(
            NamingTemplate(parsing: "C-{sequence}"), photos: [#require(ids["A/IMG_0001.ARW"])],
        )))
        try await operations.run(operations.planNewFolder(sandbox.url("A/New")))
        try await operations.undo()
        let entries = try await operations.entries()
        #expect(entries.map(\.kind) == [.rename, .newFolder, .undo])
        #expect(entries.map(\.state) == [.finished, .undone, .finished])
        #expect(entries[0].title == "Rename 1 photo" && entries[0].photos == 1 && entries[0].done == entries[0].steps)
        #expect(entries[2].undoes == entries[1].id && entries[2].title == "Undo New folder New")
        #expect(try await operations.lastUndoable()?.id == entries[0].id)

        let log = try #require(try FileManager.default.contentsOfDirectory(
            at: operations.journal.folder, includingPropertiesForKeys: nil,
        ).filter { $0.pathExtension == "log" }.sorted { $0.path < $1.path }.first)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"state\":\"rolledB".utf8))
        try handle.close()
        #expect(try await operations.entries().first?.state == .finished)
    }

    @Test func `an unfinished batch keeps others from starting until it's recovered`() async throws {
        let sandbox = try await FileSandbox.make([.init("A/IMG_0001.ARW"), .init("A/IMG_0002.ARW")])
        defer { sandbox.remove() }
        let killed = sandbox.operations()
        killed.interruption.withLock { $0 = .afterStep(0) }
        let ids = try await sandbox.rows()
        let preview = try await killed.renamePreview(NamingTemplate(parsing: "D-{sequence}"), photos: Array(ids.values))
        await #expect(throws: FileOperations.ForcedQuit.self) { try await killed.run(killed.planRename(preview)) }
        let launch = sandbox.operations()
        let unfinished = try #require(try await launch.unfinishedEntries().first)
        #expect(unfinished.state == .running && unfinished.done == 1)
        await #expect(throws: FileOperationError.unfinished(unfinished.id)) {
            try await launch.run(launch.planNewFolder(sandbox.url("A/New")))
        }
        try await launch.recover()
        #expect(try await launch.run(launch.planNewFolder(sandbox.url("A/New"))).isFinished)
    }
}
