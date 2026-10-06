import Foundation
import Testing
@testable import RedlampLibrary

/// What `redlamp library import` prints, the report's lines or its JSON, on a small card.
struct ImportReportTests {
    @Test func `on a small card it shows the plan as a dry run, then what was copied and verified, then nothing new`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        var shots = (1 ... 5).map { number in
            SimulatedCard.Shot(name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number)))
        }
        shots.append(SimulatedCard.Shot(name: "IMG_0006.CR3", captured: cameraTime(6), contents: Data("raw".utf8)))
        shots.append(SimulatedCard.Shot(name: "IMG_0006.JPG", captured: cameraTime(6)))
        shots.append(SimulatedCard.Shot(name: "MVI_0007.MP4", captured: cameraTime(7), contents: Data("video".utf8)))
        let source = try sandbox.card("EOS_DIGITAL", shots)
        let settings = try sandbox.settings(metadata: ImportMetadata(keywords: ["Trips", "Places/Lisbon"]))
        let destination = LibraryIndexer.path(sandbox.destination)

        let (dry, _) = try await ImportReport.importing(
            [source], settings: settings, library: sandbox.library, fileSystem: sandbox.fileSystem, dryRun: true,
        )
        let lines = dry.lines()
        let card = LibraryIndexer.path(source.photosFolder) + "/100CANON"
        #expect(lines.first == "\(card)/IMG_0001.JPG → \(destination)/2026/2026-10-05/IMG_0001.JPG")
        #expect(lines
            .contains("\(card)/IMG_0006.CR3 → \(destination)/2026/2026-10-05/IMG_0006.CR3  (with IMG_0006.JPG)"))
        #expect(
            lines.contains { $0.hasPrefix("6 photos, 7 files, ") && $0.contains(
                "from EOS_DIGITAL (card) to \(destination), "
                    +
                    "with a backup at \(LibraryIndexer.path(sandbox.backup)): 2 folders, 0 numbered to tell them apart.",
            )
            },
        )
        #expect(lines.contains("EOS_DIGITAL also holds 1 file that isn't a photo, left where it is."))
        #expect(lines.last == "A dry run: nothing was copied.")
        #expect(!FileManager.default.fileExists(atPath: sandbox.destination.path))
        let json = try #require(try JSONSerialization.jsonObject(with: dry.json()) as? [String: Any])
        #expect(json["tool"] as? String == "redlamp library import" && json["dryRun"] as? Bool == true)
        #expect((json["photos"] as? [[String: Any]])?.count == 6 && json["keywords"] as? [String] == [
            "Trips",
            "Places/Lisbon",
        ])

        let (copied, _) = try await ImportReport.importing(
            [source], settings: settings, library: sandbox.library, fileSystem: sandbox.fileSystem,
        )
        let done = copied.lines()
        #expect(done.contains { $0.hasPrefix("Copied and verified 6 of 6 photos (7 files, ") && $0.hasSuffix(
            ", at the destination and the backup.",
        ) })
        #expect(done
            .contains("7 sidecars written with the choices made and the metadata; 7 photos added to the index."))
        #expect(done.last == "EOS_DIGITAL: safe to erase: every photo copied from it is verified at every destination.")
        let output = try #require(try JSONSerialization.jsonObject(with: copied.json()) as? [String: Any])
        #expect(output["dryRun"] as? Bool == false && output["safeToErase"] as? Bool == true &&
            output["verified"] as? Int == 6)

        let (again, _) = try await ImportReport.importing(
            [source], settings: settings, library: sandbox.library, fileSystem: sandbox.fileSystem,
        )
        #expect(again.plan.items.isEmpty)
        #expect(again.lines().contains("Left on the sources: 7 already in the library."))
    }
}
