import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Forced quits, simulated where the runner would be killed: after a step, after its files moved but
/// before it's logged, and between a step's files. The next launch's `recover` finishes the batch or
/// rolls it back, and every photo is there with its sidecar either way.
struct FileRecoveryTests {
    /// Photos whose rename has everything: two that swap names, one with its sidecar and the other
    /// with another app's sidecar named after it, and a raw and JPEG pair with sidecars and a stem
    /// `.xmp`.
    private static let photos: [FileSandbox.Photo] = [
        .init("Card/DSC_0003.NEF", captured: FileSandbox.date(0), sidecar: true, xmp: .stem),
        .init("Card/DSC_0003.JPG", captured: FileSandbox.date(0), sidecar: true),
        .init("Card/Shot-1.NEF", captured: FileSandbox.date(20), sidecar: true),
        .init("Card/Shot-2.NEF", captured: FileSandbox.date(10), xmp: .name),
    ]

    /// Shot-2 to Shot-1 and Shot-1 to Shot-2, and the pair to Shot-3.
    private static func plan(_ operations: FileOperations, _ sandbox: FileSandbox) async throws -> FileBatch {
        let rows = try await sandbox.rows()
        let ids = ["Card/Shot-2.NEF", "Card/Shot-1.NEF", "Card/DSC_0003.NEF"].compactMap { rows[$0] }
        let preview = try await operations.renamePreview(NamingTemplate(parsing: "Shot-{sequence}"), photos: ids)
        return try await operations.planRename(preview)
    }

    /// The names, the photos' and other apps' bytes, and each photo's rating and original name.
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

    @Test(arguments: [FileRecovery.finish, .rollBack])
    func `a forced quit at any point leaves a journal the next launch finishes or rolls back`(
        _ choice: FileRecovery,
    ) async throws {
        let sandbox = try await FileSandbox.make(Self.photos)
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let original = try await Self.state(sandbox)
        let originalRows = try await sandbox.rows()
        let batch = try await Self.plan(operations, sandbox)
        #expect(try await operations.run(batch).isFinished)
        let renamed = try await Self.state(sandbox)
        let renamedRows = try await sandbox.rows()
        #expect(batch.steps
            .contains { !$0.isSafe && $0.items.contains { $0.destination?.contains("renaming") == true } })
        #expect(renamed["Card/Shot-1.NEF"] == original["Card/Shot-2.NEF"])
        #expect(renamed["Card/Shot-2.NEF"] == original["Card/Shot-1.NEF"])
        #expect(renamed["Card/Shot-3.NEF"] == original["Card/DSC_0003.NEF"])
        #expect(renamed["Card/Shot-1.NEF.xmp"] == original["Card/Shot-2.NEF.xmp"])
        #expect(renamed["Card/Shot-3.xmp"] == original["Card/DSC_0003.xmp"])
        #expect(renamed["metadata of Card/Shot-2.NEF"] == "3 Shot-1.NEF")
        #expect(renamed["metadata of Card/Shot-1.NEF"] == "0 Shot-2.NEF")
        #expect(try await operations.undo().isFinished)
        #expect(try await Self.state(sandbox) == original)

        var interruptions: [FileOperations.Interruption] = []
        for (index, step) in batch.steps.enumerated() {
            interruptions += [.afterStep(index), .beforeLogging(index)]
            if step.items.count > 1 {
                interruptions.append(.withinStep(index, items: 1))
            }
        }
        #expect(interruptions.count > 12)
        for interruption in interruptions {
            let killed = sandbox.operations()
            killed.interruption.withLock { $0 = interruption }
            await #expect(throws: FileOperations.ForcedQuit.self, "\(interruption)") {
                try await killed.run(Self.plan(killed, sandbox))
            }
            let launch = sandbox.operations()
            #expect(try await launch.unfinishedEntries().count == 1)
            let outcomes = try await launch.recover(choice)
            #expect(outcomes.count == 1 && outcomes.first?.state == (choice == .finish ? .finished : .rolledBack))
            #expect(try await launch.unfinishedEntries().isEmpty)
            let expected = choice == .finish ? renamed : original
            let found = try await Self.state(sandbox)
            #expect(
                found == expected,
                "\(interruption): \(found.filter { expected[$0.key] != $0.value }.keys.sorted())",
            )
            #expect(try await sandbox.rows() == (choice == .finish ? renamedRows : originalRows), "\(interruption)")
            #expect(sandbox.leftovers().isEmpty, "\(interruption)")
            if choice == .finish {
                #expect(try await launch.undo().isFinished)
                #expect(try await Self.state(sandbox) == original, "\(interruption)")
            }
        }
    }

    @Test func `an undo a forced quit interrupted is finished, and its batch counts as undone`() async throws {
        let sandbox = try await FileSandbox.make(Self.photos)
        defer { sandbox.remove() }
        let operations = sandbox.operations()
        let original = try await Self.state(sandbox)
        let batch = try await Self.plan(operations, sandbox)
        try await operations.run(batch)
        let killed = sandbox.operations()
        killed.interruption.withLock { $0 = .afterStep(1) }
        await #expect(throws: FileOperations.ForcedQuit.self) { try await killed.undo() }
        let launch = sandbox.operations()
        await #expect(throws: FileOperationError.self) { try await launch.run(Self.plan(launch, sandbox)) }
        try await launch.recover()
        #expect(try await Self.state(sandbox) == original)
        #expect(try await launch.entries().map(\.state) == [.undone, .finished])
    }

    @Test func `a power cut that lost the log's last lines is recovered from where the files are`() async throws {
        let sandbox = try await FileSandbox.make(Self.photos)
        defer { sandbox.remove() }
        let killed = sandbox.operations()
        let batch = try await Self.plan(killed, sandbox)
        killed.interruption.withLock { $0 = .afterStep(batch.steps.count - 2) }
        await #expect(throws: FileOperations.ForcedQuit.self) { try await killed.run(batch) }
        let log = try #require(try FileManager.default.contentsOfDirectory(
            at: killed.journal.folder, includingPropertiesForKeys: nil,
        ).first { $0.pathExtension == "log" })
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        try (lines.prefix(1).joined(separator: "\n") + "\n{\"do").write(to: log, atomically: true, encoding: .utf8)
        let outcome = try #require(try await sandbox.operations().recover().first)
        #expect(outcome.isFinished && (outcome.recoveredFrom ?? 0) >= batch.steps.count - 1)
        #expect(Set(sandbox.photoFiles().keys) == [
            "Card/Shot-1.NEF",
            "Card/Shot-2.NEF",
            "Card/Shot-3.NEF",
            "Card/Shot-3.JPG",
        ])
        #expect(try await sandbox.sidecar("Card/Shot-1.NEF")?.metadata?.originalName == "Shot-2.NEF")
        #expect(sandbox.leftovers().isEmpty)
    }
}
