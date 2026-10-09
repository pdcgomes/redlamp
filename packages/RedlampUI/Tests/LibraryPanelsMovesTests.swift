import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The panels' photos as renames and moves go and are taken back (LIB-21, LIB-26): the photos a move's Undo brings
/// back into the folder shown, selected as they were, are the panels' selection again, so a keyword reaches them.
@MainActor
@Suite(.serialized)
struct LibraryPanelsMovesTests {
    @Test func `the panels have the photos a move's Undo brings back, and a keyword reaches them`() async throws {
        try await LibraryUndoOrderTests.Sandbox.with { sandbox in
            let model = try #require(sandbox.model)
            let panels = model.libraryPanels
            let core = try #require(sandbox.service.core)
            let (a, b) = (sandbox.photo("A.JPG"), sandbox.photo("B.JPG"))
            let found = await LibraryService.indexIDs(of: [a, b], in: core.index)
            let expected = [a, b].compactMap { found[$0] }.sorted()
            try #require(expected.count == 2)
            model.select(a)
            model.click(b, toggling: true)
            try await sandbox.eventually { panels.selection.ids == expected }

            #expect(await model.movePhotos([a, b], to: sandbox.picked) == nil)
            await sandbox.settled()
            try await sandbox.eventually { model.items.count == 2 }
            #expect(model.perform(.undo))
            await sandbox.settled()
            await panels.refreshed()
            #expect(Set(model.selectedPhotos) == [a, b], "they come back selected")
            try await sandbox.eventually(seconds: 5) { panels.selection.ids == expected }
            #expect(panels.selection.ids == expected, "the panels have both photos")

            #expect(panels.add([KeywordPath("Back")!]))
            await sandbox.settled()
            for photo in [a, b] {
                #expect(SidecarStore().load(for: photo)?.metadata?.keywords == ["Back"], "\(photo.lastPathComponent)")
            }
        }
    }
}
