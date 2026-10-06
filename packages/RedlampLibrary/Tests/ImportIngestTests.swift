import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct ImportIngestTests {
    @Test func `each new file is put where the templates say, numbered on from the last, as an import would`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        // Frames as a tethered camera hands them over, into a folder of their own.
        let arrivals = sandbox.folder.url.appending(path: "Arrivals", directoryHint: .isDirectory)
        try SimulatedCard.write([
            SimulatedCard.Shot(name: "DSC_0101.JPG", captured: cameraTime(1)),
            SimulatedCard.Shot(
                name: "DSC_0102.JPG",
                captured: cameraTime(2),
                sidecars: ["DSC_0102.xmp": Data("<x/>".utf8)],
            ),
            SimulatedCard.Shot(name: "DSC_0103.JPG", captured: cameraTime(86400)),
        ], to: arrivals)
        let frames = arrivals.appending(path: "DCIM/100CANON")
        var settings = try sandbox.settings(folders: "{date:yyyy-MM-dd}", names: "{text:shoot}-{sequence:3}")
        settings.texts = ["shoot": "Studio"]
        let ingest = ImportIngest(settings: settings, library: sandbox.library)

        var rated = ImportChoices()
        rated.rate(3)
        let first = try await ingest.ingest(frames.appending(path: "DSC_0101.JPG"), choices: rated)
        #expect(first.photo?.path == sandbox.destination.path + "/2026-10-05/Studio-001.JPG")
        #expect(first.backups.map(\.path) == [sandbox.backup.path + "/2026-10-05/Studio-001.JPG"])
        #expect(first.outcome.isSafeToErase && first.outcome.indexed == 1)
        #expect(try SidecarStore().load(for: #require(first.photo))?.metadata?.rating == 3)
        #expect(try SidecarStore().load(for: #require(first.photo))?.metadata?.originalName == "DSC_0101.JPG")

        let second = try await ingest.ingest(frames.appending(path: "DSC_0102.JPG"))
        #expect(second.files.map(\.lastPathComponent) == ["Studio-002.JPG", "Studio-002.xmp"])
        // Another day's folder, and the sequence goes on.
        let third = try await ingest.ingest(frames.appending(path: "DSC_0103.JPG"))
        #expect(third.photo?.path == sandbox.destination.path + "/2026-10-06/Studio-003.JPG")
        #expect(try await sandbox.rows(below: sandbox.destination).count == 3)

        // A frame that's there already is recognised, not copied again.
        await #expect(throws: ImportCopyError.self) { try await ingest.ingest(frames.appending(path: "DSC_0101.JPG")) }
        await #expect(throws: ImportCopyError.self) { try await ingest.ingest(frames.appending(path: "DSC_0102.xmp")) }
        #expect(ImportSandbox.files(in: sandbox.destination).count { !$0.key.contains(".redlamp") } == 4)
    }
}
