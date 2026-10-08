import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Previous Import shown while another import finishes (LIB-23, LIB-27): it shows that import's photos, as
/// Lightroom Classic's Previous Import does, selected when the import window finished it, rather than the shown
/// source giving way to the destination's folder.
@MainActor
struct PreviousImportTests {
    /// Imports `card` into the sandbox's Imported folder through the library, as the import window does, and
    /// returns where its photos went.
    static func importing(_ card: URL, _ sandbox: SourcesSandbox) async throws -> [URL] {
        let core = try #require(sandbox.service?.core)
        let library = ImportLibrary(
            paths: core.paths, index: core.index, store: core.store, indexer: core.indexer, live: core.live,
        )
        let session = try ImportSession(sources: [ImportSource.at(card)], library: library, makesPreviews: false)
        let destination = sandbox.folder("Imported")
        let plan = try await session.plan(ImportSettings(
            destination: destination,
            folders: NamingTemplate(parsing: ""),
        ))
        let outcome = try await session.importer().run(plan)
        try #require(outcome.state == .finished && outcome.verified == plan.items.count)
        return plan.items.compactMap { item in item.photos.first.flatMap { plan.targets(of: $0).first } }
    }

    /// A first import of two photos, shown as Previous Import, and a card of one more.
    static func library() async throws -> (sandbox: SourcesSandbox, model: EditorModel, second: URL) {
        let sandbox = SourcesSandbox()
        try sandbox.photos(["Imported/Before.JPG"])
        let first = sandbox.base.appending(path: "First", directoryHint: .isDirectory)
        try sandbox.photos(["IMG_0001.JPG", "IMG_0002.JPG"], under: first, from: 10)
        let second = sandbox.base.appending(path: "Second", directoryHint: .isDirectory)
        try sandbox.photos(["IMG_0003.JPG"], under: second, from: 20)
        let model = try await sandbox.open()
        _ = try await importing(first, sandbox)
        try await sandbox.counts { $0.count(of: .previousImport) == 2 }
        #expect(model.perform(.showPreviousImport))
        try await sandbox.eventually { !model.librarySources.isListing && model.items.count == 2 }
        try #require(model.items.map(\.name).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        return (sandbox, model, second)
    }

    @Test func `a shown Previous Import shows a newer import's photos, selected, as the import window finishes it`(
    ) async throws {
        let (sandbox, model, second) = try await Self.library()
        defer { sandbox.remove() }
        let placed = try await Self.importing(second, sandbox)
        model.showImported(placed)
        try await sandbox.eventually(seconds: 20) {
            !model.librarySources.isListing && model.items.map(\.name) == ["IMG_0003.JPG"]
        }
        #expect(model.librarySources.shown == .previousImport, "Previous Import stays shown")
        #expect(model.items.map(\.name) == ["IMG_0003.JPG"])
        #expect(model.folder == nil, "not the destination's folder")
        #expect(model.selection?.lastPathComponent == "IMG_0003.JPG")
        #expect(model.librarySources.count(of: .previousImport) == 1)
    }

    @Test func `a shown Previous Import follows a newer import the library counts`() async throws {
        let (sandbox, model, second) = try await Self.library()
        defer { sandbox.remove() }
        _ = try await Self.importing(second, sandbox)
        try await sandbox.counts { $0.count(of: .previousImport) == 1 }
        try await sandbox.eventually(seconds: 20) {
            !model.librarySources.isListing && model.items.map(\.name) == ["IMG_0003.JPG"]
        }
        #expect(model.librarySources.shown == .previousImport)
        #expect(model.items.map(\.name) == ["IMG_0003.JPG"])
    }
}
