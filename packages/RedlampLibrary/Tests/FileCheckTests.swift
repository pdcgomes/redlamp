import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// What stops a batch before anything moves, as its files are when it runs, and the check a caller
/// runs in the batch's turn (LIB-26).
struct FileCheckTests {
    /// Adds a byte to the file at `relative`, in place: the same file, of another size and date.
    private static func rewrite(_ relative: String, in sandbox: FileSandbox) throws {
        let handle = try FileHandle(forWritingTo: sandbox.url(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
    }

    @Test func `a file rewritten in place between planning and running stops the batch`() async throws {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make([
            .init("A/IMG_0001.ARW", captured: FileSandbox.date(0), sidecar: true),
            .init("A/IMG_0002.ARW", captured: FileSandbox.date(1), sidecar: true, xmp: .name),
        ], folders: ["B"], fileSystem: simulated)
        defer { sandbox.remove() }
        simulated.useTrash(sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory))
        let operations = sandbox.operations()
        let ids = try await sandbox.rows()
        let photo = try #require(ids["A/IMG_0002.ARW"])
        let preview = try await operations.renamePreview(NamingTemplate(parsing: "Trip-{sequence}"), photos: [photo])
        let batches = try await [
            operations.planRename(preview),
            operations.planMove(photos: [photo], to: sandbox.url("B")),
            operations.planTrash(photos: [photo]),
        ]
        let file = sandbox.url("A/IMG_0002.ARW")
        let planned = try LocalFileSystem().attributes(of: file)
        try Self.rewrite("A/IMG_0002.ARW", in: sandbox)
        let rewritten = try LocalFileSystem().attributes(of: file)
        #expect(rewritten.fileIdentifier == planned.fileIdentifier && rewritten.size == planned.size + 1)

        let before = sandbox.files()
        let conflict = FileConflict(path: sandbox.rootPath + "/A/IMG_0002.ARW", reason: .changed)
        for batch in batches {
            await #expect(throws: FileOperationError.conflicts([conflict]), "\(batch.title)") {
                try await operations.run(batch)
            }
        }
        #expect(sandbox.files() == before && simulated.writes.isEmpty)
        #expect(try await operations.entries().isEmpty, "nothing was written to the journal")
        #expect(try await sandbox.rows() == ids)
        #expect(conflict.description == sandbox.rootPath + "/A/IMG_0002.ARW has changed since the batch was planned")
    }

    @Test func `sidecars written since the batch was planned go with their photos as they are now`() async throws {
        let sandbox = try await FileSandbox.make([
            .init("A/IMG_0001.ARW", sidecar: true, xmp: .name),
            .init("A/IMG_0002.ARW", xmp: .stem),
        ], folders: ["B"])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let batch = try await operations.planMove(photos: Array(sandbox.rows().values), to: sandbox.url("B"))
        // Another app writes one .xmp in place and replaces the other; Redlamp saves a sidecar again.
        try Self.rewrite("A/IMG_0001.ARW.xmp", in: sandbox)
        try Data("theirs, again".utf8).write(to: sandbox.url("A/IMG_0002.xmp"), options: .atomic)
        try await sandbox.store().save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 5)), for: sandbox.url("A/IMG_0001.ARW"),
        )
        let written = sandbox.files()

        #expect(try await operations.run(batch).isFinished)
        #expect(sandbox.files() == Dictionary(uniqueKeysWithValues: written.map { path, data in
            ("B/" + path.dropFirst("A/".count), data)
        }))
        #expect(try await sandbox.sidecar("B/IMG_0001.ARW")?.metadata?.rating == 5)
        #expect(try await operations.undo().isFinished)
        #expect(sandbox.files() == written)
    }

    @Test func `a check run in its batch's turn sees what the batches before it did and holds back those after it`(
    ) async throws {
        let held = HeldWrite("move ")
        let sandbox = try await FileSandbox.make(
            [.init("A/IMG_0001.JPG"), .init("A/IMG_0002.JPG")], folders: ["B", "C"],
            fileSystem: WatchedFileSystem(beforeWrite: held.before),
        )
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let ids = try await sandbox.rows()
        let (first, second) = try (#require(ids["A/IMG_0001.JPG"]), #require(ids["A/IMG_0002.JPG"]))
        let ahead = try await operations.planMove(photos: [first], to: sandbox.url("B"))
        let checked = try await operations.planMove(photos: [second], to: sandbox.url("C"))
        let behind = try await operations.planMove(photos: [second], to: sandbox.url("B"))

        // The batch ahead is held partway through its move.
        let running = Task { try await operations.run(ahead) }
        await held.reached.wait()
        let seen = Mutex<Bool?>(nil)
        let asked = Signal()
        let late = Mutex<Task<FileOutcome, any Error>?>(nil)
        let checking = Task {
            try await operations.run(checked, checkedBy: {
                seen.withLock { $0 = FileManager.default.fileExists(atPath: sandbox.url("A/IMG_0001.JPG").path) }
                late.withLock { late in
                    late = Task {
                        asked.fire()
                        return try await operations.run(behind)
                    }
                }
                await asked.wait()
            })
        }
        // Long enough for a check that didn't wait its turn to have looked.
        try await Task.sleep(for: .milliseconds(100))
        held.release()

        #expect(try await running.value.isFinished)
        #expect(try await checking.value.isFinished)
        #expect(seen.withLock { $0 } == false, "the check came after the batch ahead had moved its photo")
        let behindRun = try #require(late.withLock { $0 })
        await #expect(throws: FileOperationError.conflicts([
            FileConflict(path: sandbox.rootPath + "/A/IMG_0002.JPG", reason: .gone),
        ]), "the batch asked for during the check ran after the batch checked") { try await behindRun.value }
        #expect(Set(sandbox.files().keys) == ["B/IMG_0001.JPG", "C/IMG_0002.JPG"])
    }

    @Test func `a check that throws stops its batch before anything moves`() async throws {
        let sandbox = try await FileSandbox.make([.init("A/IMG_0001.JPG")], folders: ["B"])
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let batch = try await operations.planMove(photos: Array(sandbox.rows().values), to: sandbox.url("B"))
        let before = sandbox.files()
        struct Refused: Error, Equatable {}
        await #expect(throws: Refused()) { try await operations.run(batch, checkedBy: { throw Refused() }) }
        #expect(sandbox.files() == before)
        #expect(try await operations.entries().isEmpty, "nothing was written to the journal")
        #expect(try await operations.run(batch, checkedBy: {}).isFinished)
    }
}
