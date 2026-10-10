import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The write a test holds, chosen once its sandbox has its paths.
private final class Hold: Sendable {
    private let write = Mutex<HeldWrite?>(nil)

    func hold(_ prefix: String) -> HeldWrite {
        let held = HeldWrite(prefix)
        write.withLock { $0 = held }
        return held
    }

    func before(_ operation: String) {
        write.withLock { $0 }?.before(operation)
    }
}

/// Batches stopped partway (LIB-26): cancelled, a rename, move or copy finishes the photo in hand, writes the
/// sidecars of the photos done that a sidecar step to come would have written, and stops, journaled as stopped;
/// its Undo takes back what it did. An Undo stopped partway leaves each photo whole, where it is, and Undo again
/// takes back the rest. A write is held where the stop comes, as a press of Stop would find it.
struct FileStopTests {
    /// A sandbox of `count` JPEGs in Shoot, the odd ones with sidecars, and an empty Picked, on a simulated volume
    /// whose Trash is a folder of the sandbox's, its writes waiting for `hold`'s.
    private static func sandbox(_ count: Int, _ hold: Hold) async throws -> FileSandbox {
        let simulated = SimulatedFileSystem(profile: .ssd)
        let sandbox = try await FileSandbox.make(
            (1 ... count).map { .init(Self.name($0), captured: FileSandbox.date(Double($0)), sidecar: $0 % 2 == 1) },
            folders: ["Picked"], fileSystem: WatchedFileSystem(simulated, beforeWrite: hold.before),
        )
        simulated.useTrash(sandbox.folder.url.appending(path: "Trash", directoryHint: .isDirectory))
        return sandbox
    }

    private static func name(_ number: Int) -> String {
        "Shoot/IMG_000\(number).JPG"
    }

    /// The names and bytes, sidecars apart, and each photo's rating and original name.
    private static func state(_ sandbox: FileSandbox) async throws -> [String: String] {
        var state: [String: String] = [:]
        for (path, data) in sandbox.files() {
            state[path] = path.contains(".redlamp/") ? "sidecar" : String(decoding: data, as: UTF8.self)
        }
        for path in try await sandbox.rows().keys {
            let metadata = try await sandbox.sidecar(path)?.metadata
            state["metadata of " + path] = "\(metadata?.rating ?? 0) \(metadata?.originalName ?? "-")"
        }
        return state
    }

    /// Runs `batch` until `held`'s write is reached, then cancels it and lets the write go.
    private static func stop(
        _ batch: @escaping @Sendable () async throws -> FileOutcome, at held: HeldWrite,
    ) async throws -> FileOutcome {
        let task = Task { try await batch() }
        await held.reached.wait()
        task.cancel()
        held.release()
        return try await task.value
    }

    @Test func `a copy stopped partway keeps the copies made, each with its sidecars made its own, and its Undo takes those to the Trash`(
    ) async throws {
        let hold = Hold()
        let sandbox = try await Self.sandbox(6, hold)
        defer { sandbox.remove() }
        let store = try await sandbox.store()
        let first = sandbox.url(Self.name(1))
        var sidecar = try #require(store.load(for: first))
        sidecar.metadata?.collections = ["Selects"]
        try store.save(sidecar, for: first)
        let rows = try await sandbox.rows()
        let ids = (1 ... 6).compactMap { rows[Self.name($0)] }
        let operations = sandbox.operations()
        let batch = try await operations.planCopy(photos: ids, to: sandbox.url("Picked"))
        #expect(batch.steps.map(\.kind) == Array(repeating: .copy, count: 6) + [.detachCopies])
        let held = hold.hold("clone " + sandbox.url(Self.name(3)).path)

        let outcome = try await Self.stop({ try await operations.run(batch) }, at: held)
        #expect(outcome.state == .stopped && outcome.photoIDs == Array(ids.prefix(3)), "the photo in hand finished")
        #expect(Set(sandbox.photoFiles().keys.filter { $0.hasPrefix("Picked/") }) == [
            "Picked/IMG_0001.JPG", "Picked/IMG_0002.JPG", "Picked/IMG_0003.JPG",
        ])
        let copy = try #require(try await sandbox.sidecar("Picked/IMG_0001.JPG")?.metadata)
        #expect(copy.collections.isEmpty && copy.rating == 3, "its sidecar made its own before the batch stopped")
        #expect(try await sandbox.sidecar("Picked/IMG_0003.JPG")?.metadata?.rating == 3)
        #expect(try await sandbox.rows().count == rows.count + 3)
        #expect(try await operations.entries().last?.state == .stopped)

        #expect(try await operations.undo().isFinished)
        #expect(sandbox.photoFiles().keys.allSatisfy { !$0.hasPrefix("Picked/") })
        #expect(try await sandbox.rows() == rows)
    }

    @Test func `a rename stopped partway records the original names of the photos it renamed, and its Undo puts every name back`(
    ) async throws {
        let hold = Hold()
        let sandbox = try await Self.sandbox(5, hold)
        defer { sandbox.remove() }
        let rows = try await sandbox.rows()
        let ids = (1 ... 5).compactMap { rows[Self.name($0)] }
        let before = try await Self.state(sandbox)
        let operations = sandbox.operations()
        let preview = try await operations.renamePreview(NamingTemplate(parsing: "Trip-{sequence}"), photos: ids)
        let batch = try await operations.planRename(preview)
        #expect(batch.steps.last?.kind == .recordOriginalNames && batch.steps.dropLast().allSatisfy { !$0.isSafe })
        let held = hold.hold("move " + sandbox.url(Self.name(3)).path)

        let outcome = try await Self.stop({ try await operations.run(batch) }, at: held)
        #expect(outcome.state == .stopped && outcome.photoIDs == Array(ids.prefix(3)))
        #expect(Set(sandbox.photoFiles().keys) == [
            "Shoot/Trip-1.JPG", "Shoot/Trip-2.JPG", "Shoot/Trip-3.JPG", "Shoot/IMG_0004.JPG", "Shoot/IMG_0005.JPG",
        ])
        for (number, renamed) in ["Trip-1", "Trip-2", "Trip-3"].enumerated() {
            #expect(
                try await sandbox.sidecar("Shoot/\(renamed).JPG")?.metadata?.originalName == "IMG_000\(number + 1).JPG",
                "\(renamed)'s original name, recorded before the batch stopped",
            )
        }
        #expect(try await sandbox.sidecar(Self.name(4)) == nil, "no sidecar for a photo the batch didn't rename")
        #expect(try await sandbox.sidecar(Self.name(5))?.metadata?.originalName == nil)

        #expect(try await operations.undo().isFinished)
        #expect(try await Self.state(sandbox) == before, "every name back, and the original names taken out")
        #expect(try await sandbox.rows() == rows)
    }

    @Test func `a rename's Undo stopped partway takes the original names out of the photos it put back alone, and Undo again the rest`(
    ) async throws {
        let hold = Hold()
        let sandbox = try await Self.sandbox(5, hold)
        defer { sandbox.remove() }
        let rows = try await sandbox.rows()
        let ids = (1 ... 5).compactMap { rows[Self.name($0)] }
        let before = try await Self.state(sandbox)
        let operations = sandbox.operations()
        let preview = try await operations.renamePreview(NamingTemplate(parsing: "Trip-{sequence}"), photos: ids)
        #expect(try await operations.run(operations.planRename(preview)).isFinished)
        let renamed = try #require(try await operations.lastUndoable())
        let undo = try await operations.planUndo(renamed.id)
        #expect(undo.steps.last?.kind == .clearOriginalNames && undo.steps.dropLast().allSatisfy { !$0.isSafe })
        #expect(undo.steps.filter { $0.kind == .clearOriginalNames }.count == 1, "the names go after the moves")
        let held = hold.hold("move " + sandbox.url("Shoot/Trip-3.JPG").path)

        let undone = try await Self.stop({ try await operations.undo() }, at: held)
        #expect(undone.state == .stopped)
        let back = Set(undone.photoIDs)
        #expect(!back.isEmpty && back.count < ids.count, "\(back)")
        for (number, id) in zip(1 ... 5, ids) {
            let original = "IMG_000\(number).JPG"
            if back.contains(id) {
                #expect(sandbox.files()["Shoot/" + original] != nil, "\(original) is back")
                #expect(try await sandbox.sidecar("Shoot/" + original)?.metadata?.originalName == nil)
            } else {
                let metadata = try await sandbox.sidecar("Shoot/Trip-\(number).JPG")?.metadata
                #expect(metadata?.originalName == original, "Trip-\(number) keeps its original name")
            }
        }

        let rest = try await operations.undo()
        #expect(rest.isFinished && Set(rest.photoIDs) == Set(ids).subtracting(back))
        #expect(try await Self.state(sandbox) == before, "every name back, and the original names taken out")
        #expect(try await sandbox.rows() == rows)
    }

    @Test func `an Undo stopped partway leaves each photo whole where it is, and Undo again takes back the rest`(
    ) async throws {
        let hold = Hold()
        let sandbox = try await Self.sandbox(4, hold)
        defer { sandbox.remove() }
        let rows = try await sandbox.rows()
        let ids = (1 ... 4).compactMap { rows[Self.name($0)] }
        let before = sandbox.files()
        let operations = sandbox.operations()
        #expect(try await operations.run(operations.planMove(photos: ids, to: sandbox.url("Picked"))).isFinished)
        let held = hold.hold("move " + sandbox.url("Picked/IMG_0002.JPG").path)

        let undone = try await Self.stop({ try await operations.undo() }, at: held)
        #expect(undone.state == .stopped && undone.photoIDs == Array(ids.prefix(2)))
        let files = sandbox.files()
        #expect(Set(sandbox.photoFiles().keys) == [
            "Shoot/IMG_0001.JPG", "Shoot/IMG_0002.JPG", "Picked/IMG_0003.JPG", "Picked/IMG_0004.JPG",
        ])
        #expect(
            files["Shoot/IMG_0001.JPG.redlamp/edit.json"] != nil && files["Picked/IMG_0003.JPG.redlamp/edit.json"] !=
                nil,
        )
        let found = try await sandbox.rows()
        #expect(Set(found.keys) == Set(sandbox.photoFiles().keys), "the index has each photo where it is")
        #expect(Set(found.values) == Set(rows.values), "under its own ID")

        let rest = try await operations.undo()
        #expect(rest.isFinished && rest.gone.isEmpty && rest.photoIDs == Array(ids.suffix(2)))
        #expect(sandbox.files() == before)
        #expect(try await sandbox.rows() == rows)
        #expect(try await operations.entries().map(\.state) == [.undone, .stopped, .finished])
    }
}
