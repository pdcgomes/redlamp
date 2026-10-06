import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct ImportRecoveryTests {
    private static let shots = (1 ... 12).map { number in
        SimulatedCard.Shot(
            name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number)), padding: 50000,
        )
    }

    @Test func `an import a forced quit stopped halfway is finished on the next run, keeping what was verified`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Self.shots)
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(names: "Trip-{sequence:3}"))
        let importer = session.importer()
        importer.interruption.withLock { $0 = .afterPhotos(4) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.run(plan) }
        let unfinished = try #require(try await importer.unfinishedEntries().first)
        #expect(unfinished.id == plan.id && unfinished.done < 12)
        let placed = try Self.photos(in: sandbox.destination).keys.map { path in
            try (path, LocalFileSystem().attributes(of: sandbox.destination.appending(path: path)).fileIdentifier)
        }
        #expect(placed.count >= 4 && placed.count < 12)

        // Another import waits for it; the next launch finishes it.
        await #expect(throws: ImportError.unfinished(plan.id)) { try await session.importer().run(plan) }
        let launch = Importer(library: sandbox.library, fileSystem: sandbox.fileSystem)
        let outcomes = try await launch.recover()
        let outcome = try #require(outcomes.first)
        #expect(outcome.state == .finished && outcome.verified == 12 && outcome.isSafeToErase)
        #expect(outcome.recoveredFrom == unfinished.done)
        #expect(try await launch.unfinishedEntries().isEmpty)
        let card = ImportSandbox.files(in: source.photosFolder.appending(path: "100CANON"))
        for root in [sandbox.destination, sandbox.backup] {
            let files = Self.photos(in: root)
            #expect(files.count == 12)
            for (number, shot) in Self.shots.enumerated() {
                #expect(files[String(format: "2026/2026-10-05/Trip-%03d.JPG", number + 1)] == card[shot.name])
            }
            #expect(ImportSandbox.leftovers(in: root).isEmpty)
        }
        // What was in place before the quit wasn't copied again.
        for (path, file) in placed {
            #expect(try LocalFileSystem().attributes(of: sandbox.destination.appending(path: path))
                .fileIdentifier == file)
        }
        #expect(try await sandbox.rows(below: sandbox.destination).count == 12)
        // Each renamed photo's sidecar records the name it had on the card.
        #expect(SidecarStore().load(for: sandbox.destination.appending(path: "2026/2026-10-05/Trip-012.JPG"))?
            .metadata?.originalName == "IMG_0012.JPG")
    }

    /// The photos below `root`, without the sidecars the import wrote.
    private static func photos(in root: URL) -> [String: Data] {
        ImportSandbox.files(in: root).filter { !$0.key.contains(".redlamp") }
    }

    @Test func `a photo verified but not yet in place when the quit came is finished from the journal`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(3)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(folders: ""))
        let importer = session.importer()
        importer.interruption.withLock { $0 = .beforePlacing(1) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.run(plan) }
        // Its copies are under their hidden names, verified and logged, but not in place.
        #expect(ImportSandbox.files(in: sandbox.destination)["IMG_0002.JPG"] == nil)
        #expect(ImportSandbox.leftovers(in: sandbox.backup).contains(".IMG_0002.JPG.redlamp-import"))
        let outcome = try #require(try await Importer(library: sandbox.library, fileSystem: sandbox.fileSystem)
            .recover().first)
        #expect(outcome.verified == 3 && outcome.isSafeToErase)
        for root in [sandbox.destination, sandbox.backup] {
            #expect(ImportSandbox.files(in: root).count == 3 && ImportSandbox.leftovers(in: root).isEmpty)
        }
    }
}
