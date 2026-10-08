import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The left panel's Collections section (LIB-23): sets and collections made, renamed, moved into a set and
/// deleted; the selection's photos put in a collection and taken out of the one shown; the target collection;
/// each change on Library's Undo.
@MainActor
@Suite(.serialized)
struct CollectionsPanelTests {
    private func path(_ text: String) throws -> CollectionPath {
        try #require(CollectionPath(text))
    }

    /// Waits for the changes asked for to be made, then for the list to show `condition`.
    private func made(_ sandbox: SourcesSandbox, until condition: (LibrarySources) -> Bool) async throws {
        let model = try #require(sandbox.model)
        await model.libraryPanels.written()
        try await sandbox.counts(until: condition)
    }

    @Test func `sets and collections are made, renamed, moved into a set and deleted, each with Undo and Redo`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.isCounted }
        let clients = try path("Clients")
        let acme = try path("Clients/Acme")
        let selects = try path("Clients/Acme/Selects")
        let portfolio = try path("Portfolio")

        #expect(sources.create(.set, named: "Clients"))
        try await made(sandbox) { $0.collections[clients] != nil }
        #expect(sources.create(.set, named: "Acme", inside: clients))
        #expect(sources.create(.collection, named: "Selects", inside: acme))
        #expect(sources.create(.collection, named: "Portfolio"))
        try await made(sandbox) { $0.collections.count == 4 }
        #expect(sources.collections(inside: nil).map(\.path) == [clients, portfolio])
        #expect(sources.collections(inside: acme).map(\.path) == [selects])
        #expect(sources.collections[acme]?.kind == .set && sources.collections[selects]?.kind == .collection)
        #expect(sources.count(of: .collection(selects)) == 0 && sources.count(of: .collection(clients)) == nil)
        #expect(sources.problem(naming: "Portfolio", inside: nil) != nil, "a name in the list already is said")
        #expect(!sources.create(.collection, named: "Portfolio"))

        let best = try path("Best")
        #expect(sources.rename(portfolio, to: "Best"))
        try await made(sandbox) { $0.collections[best] != nil }
        #expect(sources.collections[portfolio] == nil)
        #expect(model.perform(.undo))
        try await made(sandbox) { $0.collections[portfolio] != nil }
        #expect(sources.collections[best] == nil, "Undo renames it back")
        #expect(model.perform(.redo))
        try await made(sandbox) { $0.collections[best] != nil }

        let moved = try path("Clients/Best")
        #expect(sources.move(best, into: clients))
        try await made(sandbox) { $0.collections[moved] != nil }
        #expect(sources.collections(inside: clients).map(\.path) == [acme, moved])
        #expect(model.perform(.undo))
        try await made(sandbox) { $0.collections[best] != nil && $0.collections[moved] == nil }

        #expect(sources.delete(clients))
        try await made(sandbox) { $0.collections[clients] == nil }
        #expect(sources.collections.keys.map(\.text) == ["Best"], "the set goes with what's inside it")
        #expect(model.perform(.undo))
        try await made(sandbox) { $0.collections.count == 4 }
        #expect(Set(sources.collections.keys) == [clients, acme, selects, best])
    }

    @Test func `the selection's photos go in a collection and come out of the one shown, each with Undo`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        let (a, b, c) = (sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG"), sandbox.photo("Shoot/C.JPG"))
        let selects = try path("Selects")
        try await sandbox.counts { $0.isCounted }
        #expect(sources.create(.collection, named: "Selects"))
        try await made(sandbox) { $0.collections[selects] != nil }

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 3 }
        model.select(a)
        model.click(b, toggling: true)
        #expect(model.canPerform(.addToCollection) && !model.canPerform(.removeFromCollection))
        #expect(sources.add(to: selects))
        try await sandbox.eventually { model.libraryPanels.undoCount > 0 }
        try await made(sandbox) { $0.count(of: .collection(selects)) == 2 }
        #expect(sources.count(of: .collection(selects)) == 2)

        #expect(sources.show(.collection(selects)))
        try await sandbox.eventually { !sources.isListing && model.items.count == 2 }
        #expect(Set(model.items.map(\.url)) == [a, b])
        model.select(a)
        #expect(model.canPerform(.removeFromCollection))
        #expect(model.perform(.removeFromCollection))
        try await sandbox.eventually { model.items.map(\.url) == [b] }
        #expect(model.items.map(\.url) == [b], "taken out, it leaves the collection shown")
        #expect(model.perform(.undo))
        try await sandbox.eventually { model.items.count == 2 }
        #expect(Set(model.items.map(\.url)) == [a, b], "Undo puts it back")

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.folder != nil && model.items.count == 3 }
        model.select(c)
        let picks = try path("Picks")
        #expect(sources.create(.collection, named: "Picks", adding: true))
        try await sandbox.eventually { model.libraryPanels.undoCount > 2 }
        try await made(sandbox) { $0.count(of: .collection(picks)) == 1 }
        #expect(sources.count(of: .collection(picks)) == 1, "made with the selected photo in it")
        let core = try #require(sandbox.service?.core)
        let ids = await LibraryService.indexIDs(of: [c], in: core.index)
        let id = try #require(ids[c])
        let kept = try await core.index.read { try $0.collections(ofPhoto: id) }
        #expect(kept == [picks], "its sidecar names it, and the index has it from there")
    }

    @Test func `the target collection takes Add to Target Collection's photos and is marked in the list`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let list = CollectionOutlineView(model: model)
        window.contentView = list
        defer { window.contentView = nil }
        @MainActor func rows() -> [SourceRow] {
            (0 ..< list.numberOfRows).compactMap { index in
                guard case let .source(row) = (list.item(atRow: index) as? SidebarNode)?.kind else { return nil }
                return row
            }
        }
        let clients = try path("Clients")
        let selects = try path("Clients/Selects")
        try await sandbox.counts { $0.isCounted }
        #expect(sources.create(.set, named: "Clients"))
        #expect(sources.create(.collection, named: "Selects", inside: clients, target: true))
        try await made(sandbox) { $0.target == selects }
        #expect(sources.target == selects, "made the target as it's made")
        try await sandbox.eventually { rows().map(\.source) == [.collection(clients), .collection(selects)] }
        #expect(rows().map(\.isTarget) == [false, true])
        let cell = list.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SidebarCellView
        #expect(cell?.accessibilityLabel() == "Selects, 0 photos, target collection")

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 2 }
        model.select(sandbox.photo("Shoot/A.JPG"))
        #expect(model.perform(.addToTargetCollection))
        try await sandbox.eventually { model.libraryPanels.undoCount > 1 }
        try await made(sandbox) { $0.count(of: .collection(selects)) == 1 }
        try await sandbox.eventually { rows().last?.count == 1 }
        #expect(rows().last?.count == 1, "its count in the list")

        // Renamed, the target is still the target.
        let picks = try path("Clients/Picks")
        #expect(sources.rename(selects, to: "Picks"))
        try await made(sandbox) { $0.target == picks }
        #expect(sources.target == picks)

        // With Marked the target, Add to Target Collection marks the photos.
        #expect(sources.setTarget(nil))
        try await made(sandbox) { $0.target == nil }
        model.select(sandbox.photo("Shoot/B.JPG"))
        #expect(model.perform(.addToTargetCollection))
        try await sandbox.eventually { !model.isWritingCulling }
        try await sandbox.counts { $0.count(of: .marked) == 1 }
        #expect(sources.count(of: .marked) == 1 && model.items.last?.metadata.mark == true)
    }

    @Test func `⌘N makes a collection in Library and a snapshot in Develop, and ⌫ takes photos out only in Library`() {
        #expect(ShortcutAction.resolve(.char("n", command: true), in: .library)?.action == .newCollection)
        #expect(ShortcutAction.resolve(.char("n", command: true), in: .develop)?.action == .newSnapshot)
        #expect(ShortcutAction.resolve(KeyCombo(.delete), in: .library)?.action == .removeFromCollection)
        #expect(ShortcutAction.resolve(KeyCombo(.delete), in: .develop)?.action == .deleteMask)
        #expect(ShortcutAction.resolve(.char("b"), in: .library)?.action == .toggleMark, "B stays the mark's")
        #expect(ShortcutAction.resolve(.char("b", command: true), in: .library)?.action == .showMarked)
    }
}
