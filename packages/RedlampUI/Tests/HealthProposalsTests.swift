import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library Health in the app (LIB-40): each check's proposals as marks the grid draws, legible at every size and
/// style; the sheet's words; and with a library, the marks following the check shown, Keep Anyway on Library's
/// Undo in turn with culling's, and a batch to the Trash taken back.
@MainActor
@Suite(.serialized)
struct HealthProposalsTests {
    // MARK: - Marks and words

    @Test func `each finding's mark says what the check found and what it proposes`() {
        func mark(
            _ reason: HealthReason, _ proposal: HealthProposal?, apart: HealthApart? = nil, check: HealthCheck.Kind,
        ) -> HealthMark {
            HealthMark(HealthFinding(photo: 1, check: check, reason: reason, proposal: proposal, apart: apart))
        }
        let copy = mark(.duplicate(of: "/Photos/A/IMG_1.JPG"), .trash, check: .duplicates)
        #expect(copy.proposal == .trash && copy.word == "To Trash" && copy.isFramed)
        #expect(copy.sentence == "byte-identical to /Photos/A/IMG_1.JPG: to the Trash")
        let kept = mark(.duplicate(of: ""), .keep, check: .duplicates)
        #expect(kept.proposal == .keep && kept.word == "Keep" && !kept.isFramed)
        let rated = mark(.duplicate(of: "/Photos/A/IMG_1.JPG"), .trash, apart: .decided, check: .duplicates)
        #expect(rated.proposal == .leftOut && rated.word == "Left Out" && !rated.isFramed)
        #expect(rated.sentence.hasSuffix("left out of the batch, as it's rated, flagged or labelled"))

        let half = mark(.pairHalf(.jpeg, beside: "IMG_1.ARW"), .trash, check: .pairs)
        #expect(half.word == "To Trash" && half
            .sentence == "the JPEG beside IMG_1.ARW: to the Trash, and IMG_1.ARW stays")
        let own = mark(.pairHalf(.jpeg, beside: "IMG_1.ARW"), .trash, apart: .own([.edit, .keywords]), check: .pairs)
        #expect(own.word == "Left Out" && own.sentence.hasSuffix("as it has its own edit and keywords"))

        let empty = mark(.damage(.empty), .trash, check: .damaged)
        #expect(empty.word == "Empty" && empty.isFramed)
        #expect(mark(.damage(.endsEarly(missing: 120)), .trash, check: .damaged).word == "Ends Early")
        #expect(mark(.damage(.unrecognised), .trash, check: .damaged).word == "Not an Image")
        #expect(mark(.damage(.unreadable("Input/output error")), .trash, check: .damaged).word == "Unreadable")
        let locked = mark(.damage(.unreadable(String(cString: strerror(EACCES)))), nil, check: .damaged)
        #expect(locked.word == "No Access" && locked.proposal == .none && !locked.isFramed)
        let decided = mark(.damage(.empty), .trash, apart: .decided, check: .damaged)
        #expect(decided.word == "Empty" && decided.proposal == .leftOut, "the damage said, left out")

        let renamed = mark(.wrongExtension(named: "JPG", holds: .heif), .rename(to: "IMG_1.HEIC"), check: .extensions)
        #expect(renamed.word == "→ .HEIC" && renamed.proposal == .rename && renamed.isFramed)
        #expect(renamed.sentence == "named .JPG, holds HEIC: renamed IMG_1.HEIC")
        let taken = mark(.wrongExtension(named: "JPG", holds: .heif), nil, check: .extensions)
        #expect(taken.word == "Name Taken" && !taken.isFramed)
    }

    @Test func `a proposal's badge fits inside its thumbnail at every size and style, and its frame inside the cell`() {
        let wrong = HealthReason.wrongExtension(named: "JPG", holds: .heif)
        let findings: [(HealthReason, HealthProposal?, HealthApart?)] = [
            (.duplicate(of: ""), .trash, nil), (.duplicate(of: ""), .keep, nil), (.duplicate(of: ""), .trash, .decided),
            (.damage(.unreadable("Input/output error")), .trash, nil),
            (.damage(.unreadable(String(cString: strerror(EACCES)))), nil, nil), (.damage(.empty), .trash, nil),
            (.damage(.unrecognised), .trash, nil), (.damage(.endsEarly(missing: nil)), .trash, nil), (wrong, nil, nil),
            (wrong, .rename(to: "IMG_1.HEIC"), nil),
        ]
        let marks = findings.map {
            HealthMark(HealthFinding(photo: 1, check: .damaged, reason: $0.0, proposal: $0.1, apart: $0.2))
        }
        #expect(Set(marks.map(\.word)) == [
            "To Trash", "Keep", "Left Out", "Unreadable", "No Access", "Empty", "Not an Image", "Ends Early",
            "Name Taken", "→ .HEIC",
        ])
        for style in GridCellStyle.allCases {
            for size in GridSize.steps {
                let geometry = GridCellGeometry(size: CGFloat(size), style: style)
                let cell = LibraryGridCell()
                cell.place(CGRect(origin: .zero, size: geometry.cellSize), geometry: geometry, scale: 2)
                cell.configure(LibraryItem(url: URL(fileURLWithPath: "/Photos/IMG_1.JPG")), row: 0, image: nil, edge: 0)
                for mark in marks {
                    cell.healthMark = mark
                    let frames = cell.proposalFrames
                    #expect(cell.proposalShown != nil, "\(mark.word) at \(size) in \(style)")
                    let badge = frames?.badge ?? .null
                    #expect(geometry.image.contains(badge), "\(mark.word) at \(size) in \(style): \(badge)")
                    #expect((frames?.frame != nil) == mark.isFramed, "\(mark.word)'s frame at \(size) in \(style)")
                    if let frame = frames?.frame {
                        #expect(CGRect(origin: .zero, size: geometry.cellSize).contains(frame))
                    }
                }
                cell.healthMark = nil
                #expect(cell.proposalShown == nil && cell.proposalFrames == nil, "gone at \(size) in \(style)")
            }
        }
        let wide = HealthMark(HealthFinding(
            photo: 1,
            check: .damaged,
            reason: .damage(.unrecognised),
            proposal: .trash,
        ))
        #expect(GridBadges.proposal(wide, width: 300) == .proposal(.trash, "Not an Image", compact: false))
        #expect(GridBadges.proposal(wide, width: 68) == .proposal(.trash, "Not an Image", compact: true))
    }

    @Test func `the sheet asks in words how many photos go, what happens and what stays`() {
        #expect(HealthWords.question(.duplicates, count: 14) == "Move 14 copies to the Trash?")
        #expect(HealthWords.question(.duplicates, count: 1) == "Move 1 copy to the Trash?")
        #expect(HealthWords.question(.pairs(.keepRaw), count: 2310, kinds: [.jpeg]) == "Move 2,310 JPEGs to the Trash?")
        #expect(HealthWords.question(.pairs(.keepJPEG), count: 1, kinds: [.raw]) == "Move 1 raw to the Trash?")
        #expect(HealthWords.question(.pairs(.keepRaw), count: 3, kinds: [.jpeg, .heic])
            == "Move 3 halves of raw and JPEG pairs to the Trash?")
        #expect(HealthWords.question(.damaged, count: 3) == "Move 3 damaged files to the Trash?")
        #expect(HealthWords.question(.extensions, count: 2) == "Rename 2 photos to their formats' extensions?")
        #expect(HealthWords.menuTitle(.duplicates, count: 14) == "Move 14 Copies to the Trash…")
        #expect(HealthWords.menuTitle(.pairs(.keepRaw), count: 3, kinds: [.jpeg, .heic])
            == "Move 3 Halves of Raw and JPEG Pairs to the Trash…")
        #expect(HealthWords.menuTitle(.extensions, count: 1) == "Rename 1 Photo…")
        #expect(HealthWords.count(.duplicates, count: 14, groups: 9, bytes: 0).hasPrefix("14 copies in 9 groups, "))
        #expect(HealthWords.undo(.duplicates).hasPrefix("Nothing is deleted: Undo (⌘Z) brings them back"))

        let findings = HealthFindings(check: .duplicates, findings: [
            HealthFinding(photo: 1, check: .duplicates, reason: .duplicate(of: ""), proposal: .keep),
            HealthFinding(photo: 2, check: .duplicates, reason: .duplicate(of: ""), proposal: .trash),
            HealthFinding(photo: 3, check: .duplicates, reason: .duplicate(of: ""), proposal: .trash, apart: .decided),
            HealthFinding(photo: 4, check: .duplicates, reason: .duplicate(of: ""), proposal: .trash, apart: .decided),
        ])
        #expect(HealthWords.leftOut(findings) == "2 stay where they are: 2 are rated, flagged or labelled, and a "
            + "proposal never acts on a photo you've decided on.")
        #expect(HealthWords.leftOut(findings, choosing: [3]).hasPrefix("1 stays where it is: 1 is rated"))
        #expect(HealthWords.leftOut(findings, choosing: [3, 4]).isEmpty)
        #expect(HealthWords.choice(.duplicates, count: 2) == "Also move the 2 selected photos listed apart")
    }

    // MARK: - With a library

    @Test func `the duplicates are confirmed in the background, and their marks follow the check shown`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG"])
        try FileManager.default.createDirectory(at: sandbox.folder("Copies"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.photo("Shoot/A.JPG"), to: sandbox.photo("Copies/A copy.JPG"))
        let model = try await sandbox.open()
        let sources = model.librarySources
        let proposals = model.healthProposals

        // No one confirmed them: counting finds candidates unread, and reads them whole.
        try await sandbox.counts(seconds: 30) { $0.count(of: .health(.duplicates)) == 2 }
        #expect(sources.count(of: .health(.duplicates)) == 2)

        #expect(sources.show(.health(.duplicates)))
        try await sandbox.eventually { !sources.isListing && proposals.marked == 2 && !proposals.isReading }
        let marks = model.items.compactMap { proposals.mark(for: $0.url) }
        #expect(Set(marks.map(\.word)) == ["Keep", "To Trash"])
        #expect(proposals.offer == HealthProposals.Offer(check: .duplicates, proposed: 1, apart: 0, found: 2))
        #expect(model.canPerform(.acceptHealthProposals) && !model.canPerform(.listAgain))

        #expect(sources.show(.allPhotographs))
        try await sandbox.eventually { !sources.isListing && model.items.count == 3 }
        #expect(proposals.marked == 0 && proposals.offer == nil, "marks only on a check's list")
        #expect(!model.canPerform(.acceptHealthProposals) && !model.canPerform(.keepAnyway))
    }

    @Test func `Keep Anyway leaves the check until ⌘Z, in turn with culling's changes, and ⇧⌘Z keeps it again`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG"])
        try Data().write(to: sandbox.photo("Shoot/Empty.JPG"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: sandbox.photo("Shoot/Empty.JPG").path,
        )
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.count(of: .health(.damaged)) == 1 }
        #expect(sources.show(.health(.damaged)))
        try await sandbox
            .eventually { !sources.isListing && model.items.count == 1 && model.healthProposals.marked == 1 }
        model.select(sandbox.photo("Shoot/Empty.JPG"))
        #expect(model.perform(.keepAnyway))
        await model.healthChangesMade()
        try await sandbox.eventually { model.items.isEmpty }
        #expect(model.items.isEmpty && model.healthUndoCount == 1)
        try await sandbox.counts { $0.count(of: .keptAnyway) == 1 }

        // A rating after it goes back first.
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 2 }
        try await sandbox.cull(.rating3, [sandbox.photo("Shoot/A.JPG")])
        #expect(model.perform(.undo))
        try await sandbox.eventually { !model.isWritingCulling }
        await sandbox.service?.settled()
        #expect(model.items.first { $0.name == "A.JPG" }?.metadata.rating == 0, "the rating taken back first")
        #expect(model.healthUndoCount == 1)

        // Then Keep Anyway: the file is listed again; ⇧⌘Z keeps it anyway again, the rating's Redo staying behind.
        #expect(model.perform(.undo))
        await model.healthChangesMade()
        try await sandbox.counts { $0.count(of: .health(.damaged)) == 1 && $0.count(of: .keptAnyway) == nil }
        #expect(sources.count(of: .health(.damaged)) == 1)
        #expect(model.perform(.redo))
        await model.healthChangesMade()
        try await sandbox.counts { $0.count(of: .health(.damaged)) == nil }
        #expect(sources.count(of: .keptAnyway) == 1)

        // List Again from Kept Anyway.
        #expect(sources.show(.keptAnyway))
        try await sandbox.eventually { !sources.isListing && model.items.count == 1 }
        model.select(sandbox.photo("Shoot/Empty.JPG"))
        #expect(model.perform(.listAgain))
        await model.healthChangesMade()
        try await sandbox.counts { $0.count(of: .health(.damaged)) == 1 }
        #expect(sources.count(of: .keptAnyway) == nil)
    }

    @Test func `the duplicates' batch moves the copy proposed to the Trash, and ⌘Z brings it back`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        do {
            try await batchTakenBack(sandbox)
        } catch {
            await Self.emptyTrash(of: sandbox)
            throw error
        }
        await Self.emptyTrash(of: sandbox)
    }

    /// Removes from the Trash what the sandbox's batches left there.
    private static func emptyTrash(of sandbox: SourcesSandbox) async {
        for place in await sandbox.service?.trashedPlaces() ?? [] {
            try? FileManager.default.removeItem(atPath: place)
        }
    }

    private func batchTakenBack(_ sandbox: SourcesSandbox) async throws {
        try sandbox.photos(["Shoot/A.JPG"])
        try FileManager.default.createDirectory(at: sandbox.folder("Copies"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.photo("Shoot/A.JPG"), to: sandbox.photo("Copies/A copy.JPG"))
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts(seconds: 30) { $0.count(of: .health(.duplicates)) == 2 }
        #expect(sources.show(.health(.duplicates)))
        try await sandbox.eventually { !sources.isListing && model.healthProposals.marked == 2 }
        let findings = try #require(model.healthProposals.findings)
        let core = try #require(sandbox.service?.core)
        let sheet = HealthSheetModel(
            findings: findings, selectedApart: [], health: model.healthProposals.library(core),
        )
        sheet.makePlan()
        try await sandbox.eventually(seconds: 20) { sheet.canAccept }
        #expect(sheet.heading == "Move 1 copy to the Trash?")
        #expect(sheet.countLine.hasPrefix("1 copy in 1 group, "))
        #expect(sheet.leftOut.isEmpty)
        let proposed = try #require(findings.findings.first { $0.proposal == .trash })
        let photo = try URL(fileURLWithPath: #require(sheet.plan?.path(of: proposed.photo)))
        #expect(await model.acceptHealthPlan(sheet))
        #expect(!FileManager.default.fileExists(atPath: photo.path), "in the Trash")
        #expect(model.healthUndoCount == 1)
        try await sandbox.counts { $0.count(of: .health(.duplicates)) == nil }

        #expect(model.perform(.undo))
        await model.healthChangesMade()
        #expect(FileManager.default.fileExists(atPath: photo.path), "back where it was")
        try await sandbox.counts { $0.count(of: .health(.duplicates)) == 2 }
        #expect(sources.count(of: .health(.duplicates)) == 2)

        // ⇧⌘Z plans it again for the same copy and moves it, checked again as the first was.
        #expect(model.perform(.redo))
        await model.healthChangesMade()
        #expect(!FileManager.default.fileExists(atPath: photo.path), "in the Trash again")
        #expect(model.perform(.undo))
        await model.healthChangesMade()
        #expect(FileManager.default.fileExists(atPath: photo.path), "back again")
    }
}
