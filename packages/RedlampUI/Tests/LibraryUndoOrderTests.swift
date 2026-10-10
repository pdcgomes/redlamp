import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library's Undo and Redo across its changes (LIB-15, LIB-21, LIB-26): culling's, the panels', the renames and
/// moves and the Put Backs are taken back by ⌘Z and made again by ⇧⌘Z in the one order they were made, whichever
/// kind each is, and a new change of any kind ends every Redo.
///
/// The Trash is the real one: the photos are made on the external disk's scratch folder, and what a test leaves in
/// the Trash is removed with it.
@MainActor
@Suite(.serialized)
struct LibraryUndoOrderTests {
    /// Shoot's photos A to E and an empty Picked, indexed and shown from the library in Library, the panels
    /// following the selection; E in the Trash, put there by one of the library's batches.
    @MainActor
    final class Sandbox {
        let base = LibrarySandbox.scratch
            .appending(path: "undo-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: "undo-order-\(UUID().uuidString)")
        private(set) var service: LibraryService!
        private(set) var model: EditorModel!

        var root: URL {
            base.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var shoot: URL {
            root.appending(path: "Shoot", directoryHint: .isDirectory)
        }

        var picked: URL {
            root.appending(path: "Picked", directoryHint: .isDirectory)
        }

        func photo(_ name: String, in folder: URL? = nil) -> URL {
            (folder ?? shoot).appending(path: name, directoryHint: .notDirectory)
        }

        func open() async throws {
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            for (number, name) in ["A", "B", "C", "D", "E"].enumerated() {
                try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
                try SourcesSandbox.jpeg(number: number).write(to: photo("\(name).JPG"))
            }
            let library = FolderLibrary(defaults: defaults)
            library.setIncludesSubfolders(false)
            library.add([root])
            service = LibraryService(
                paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
                sidecars: library.sidecars,
            ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
            library.attach(service)
            for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: true) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await service.canShow(root, includingSubfolders: true), "the library caught up with the root")
            try await service.moveToTrash([photo("E.JPG")])
            model = EditorModel(engine: StubEngine(), library: library)
            model.showModule(.library)
            try await show(shoot, count: 4)
            model.libraryPanels.follow()
            try await eventually { self.model.libraryPanels.keywordList != nil }
        }

        func show(_ folder: URL, count: Int) async throws {
            model.showFolder(folder)
            try await eventually { self.model.folder == folder && self.model.items.count == count }
            try #require(model.folder == folder && model.items.count == count, "\(folder.lastPathComponent) shown")
        }

        /// Selects `name` alone in Shoot, and waits for the panels to follow.
        func select(_ name: String) async throws {
            model.select(photo(name))
            let core = try #require(service.core)
            let id = try #require(await LibraryService.indexIDs(of: [photo(name)], in: core.index)[photo(name)])
            try await eventually { self.model.libraryPanels.selection.ids == [id] }
        }

        /// Until every change, Undo and Redo asked for is made and saved.
        func settled() async {
            while let tail = model.cullingTail {
                await tail.value
                if model.cullingTail == tail {
                    break
                }
            }
            await model.libraryPanels.written()
            await model.filesMade()
            await model.putBackSteps.made()
            await model.saves.flush()
            await service.settled()
        }

        /// Runs `body` on the sandbox opened, then removes what it left in the Trash and its folder, whether `body`
        /// threw or not.
        static func with(_ body: (Sandbox) async throws -> Void) async throws {
            let sandbox = Sandbox()
            do {
                try await sandbox.open()
                try await body(sandbox)
            } catch {
                await sandbox.close()
                throw error
            }
            await sandbox.close()
        }

        func close() async {
            if let service {
                for place in await service.trashedPlaces() {
                    try? FileManager.default.removeItem(atPath: place)
                }
            }
            LibrarySandbox.remove(base, closing: [service])
        }

        func eventually(seconds: Double = 15, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Which of the five changes the photos' files show.
    struct Made: Equatable, CustomStringConvertible {
        var keyword = false
        var putBack = false
        var renamed = false
        var rated = false
        var moved = false

        var description: String {
            [("keyword", keyword), ("put back", putBack), ("renamed", renamed), ("rated", rated), ("moved", moved)]
                .filter(\.1).map(\.0).joined(separator: ", ")
        }
    }

    private static func made(_ sandbox: Sandbox) -> Made {
        let files = FileManager.default
        return Made(
            keyword: (SidecarStore().load(for: sandbox.photo("A.JPG"))?.metadata?.keywords ?? []).contains("Order"),
            putBack: files.fileExists(atPath: sandbox.photo("E.JPG").path),
            renamed: files.fileExists(atPath: sandbox.photo("Kept-B.JPG").path),
            rated: SidecarStore().load(for: sandbox.photo("C.JPG"))?.metadata?.rating == 3,
            moved: files.fileExists(atPath: sandbox.photo("D.JPG", in: sandbox.picked).path),
        )
    }

    @Test func `⌘Z takes back a keyword, a Put Back, a rename, a rating and a move newest first, and ⇧⌘Z makes them in turn`(
    ) async throws {
        try await Sandbox.with { sandbox in try await Self.everyKindInTurn(sandbox) }
    }

    private static func everyKindInTurn(_ sandbox: Sandbox) async throws {
        let model = try #require(sandbox.model)
        let library = model.library
        var expected = Made()

        // A keyword on A, from the panels.
        try await sandbox.select("A.JPG")
        #expect(model.libraryPanels.add([KeywordPath("Order")!]))
        await sandbox.settled()
        expected.keyword = true
        #expect(made(sandbox) == expected)

        // E put back from Recently Trashed.
        model.showRecentlyTrashed()
        try await sandbox.eventually { library.showsRecentlyTrashed && library.count == 1 }
        try await model.putBack(#require(library.items.first?.url))?.value
        await sandbox.settled()
        try await sandbox.show(sandbox.shoot, count: 5)
        expected.putBack = true
        #expect(made(sandbox) == expected)

        // B renamed.
        try await sandbox.select("B.JPG")
        let sheet = try #require(model.renameSheet(presets: NamingPresetStore(url: nil)))
        await sheet.start()
        sheet.setText("Kept-{name}")
        await sheet.namesFollow()
        #expect(await model.rename(sheet) == nil)
        await sandbox.settled()
        expected.renamed = true
        #expect(made(sandbox) == expected)

        // C rated.
        model.select(sandbox.photo("C.JPG"))
        #expect(model.perform(.rating3))
        await sandbox.settled()
        expected.rated = true
        #expect(made(sandbox) == expected)

        // D moved to Picked.
        #expect(await model.movePhotos([sandbox.photo("D.JPG")], to: sandbox.picked) == nil)
        await sandbox.settled()
        expected.moved = true
        #expect(made(sandbox) == expected)

        let steps: [(String, WritableKeyPath<Made, Bool>)] = [
            ("the move", \.moved), ("the rating", \.rated), ("the rename", \.renamed), ("the Put Back", \.putBack),
            ("the keyword", \.keyword),
        ]
        for (name, change) in steps {
            #expect(model.canPerform(.undo) && model.perform(.undo), "⌘Z for \(name)")
            await sandbox.settled()
            expected[keyPath: change] = false
            try await sandbox.eventually { made(sandbox) == expected }
            #expect(made(sandbox) == expected, "⌘Z took back \(name), newest first")
        }
        #expect(!model.canPerform(.undo), "nothing left to take back")

        for (name, change) in steps.reversed() {
            #expect(model.canPerform(.redo) && model.perform(.redo), "⇧⌘Z for \(name)")
            await sandbox.settled()
            expected[keyPath: change] = true
            try await sandbox.eventually { made(sandbox) == expected }
            #expect(made(sandbox) == expected, "⇧⌘Z made \(name) again, in the order they were made")
        }
        #expect(!model.canPerform(.redo), "nothing left to make again")

        // A change of another kind ends every Redo, and is the first ⌘Z takes back.
        #expect(model.perform(.undo) && model.perform(.undo))
        await sandbox.settled()
        expected.moved = false
        expected.rated = false
        try await sandbox.eventually { made(sandbox) == expected }
        try await sandbox.select("A.JPG")
        #expect(model.libraryPanels.remove(KeywordPath("Order")!))
        await sandbox.settled()
        #expect(!model.canPerform(.redo), "a keyword ends the move's and the rating's Redo")
        #expect(model.perform(.undo))
        await sandbox.settled()
        try await sandbox.eventually { made(sandbox) == expected }
        #expect(made(sandbox) == expected, "⌘Z took back the keyword's removal first")
    }

    @Test func `a copy takes its turn: ⌘Z takes back a rating made after it, then moves the copy to the Trash, and ⇧⌘Z makes both again in turn`(
    ) async throws {
        try await Sandbox.with { sandbox in
            let model = try #require(sandbox.model)
            let copy = sandbox.photo("A.JPG", in: sandbox.picked)
            let b = sandbox.photo("B.JPG")
            let rated = { SidecarStore().load(for: b)?.metadata?.rating == 3 }
            try await sandbox.select("A.JPG")
            #expect(await model.copySelection(to: sandbox.picked) == nil)
            await sandbox.settled()
            #expect(FileManager.default.fileExists(atPath: copy.path))
            #expect(FileManager.default.fileExists(atPath: sandbox.photo("A.JPG").path), "the original stays")
            model.select(b)
            #expect(model.perform(.rating3))
            await sandbox.settled()
            #expect(rated())

            #expect(model.perform(.undo))
            await sandbox.settled()
            #expect(!rated() && FileManager.default.fileExists(atPath: copy.path), "⌘Z took back the rating first")
            #expect(model.perform(.undo))
            await sandbox.settled()
            #expect(!FileManager.default.fileExists(atPath: copy.path), "then the copy, to the Trash")
            #expect(model.perform(.redo))
            await sandbox.settled()
            #expect(FileManager.default.fileExists(atPath: copy.path) && !rated(), "⇧⌘Z copied it again first")
            #expect(model.perform(.redo))
            await sandbox.settled()
            #expect(rated(), "then gave the stars back")
        }
    }

    @Test func `the library's Undo keeps its newest steps of every kind together, the oldest going first`(
    ) async throws {
        try await Sandbox.with { sandbox in
            let model = try #require(sandbox.model)
            let limit = 20
            let ratings: [ShortcutAction] = [.rating1, .rating2, .rating3, .rating4, .rating5]
            // Twelve ratings on A, then twelve keywords on B: twenty-four steps, four more than Undo keeps.
            try await sandbox.select("A.JPG")
            for step in 0 ..< 12 {
                #expect(model.perform(ratings[step % ratings.count]))
            }
            await sandbox.settled()
            try await sandbox.select("B.JPG")
            for step in 0 ..< 12 {
                let keyword = try #require(KeywordPath("Limit \(step)"))
                #expect(model.libraryPanels.add([keyword]))
            }
            await sandbox.settled()
            #expect(model.cullingUndoCount + model.libraryPanels.undoSteps.count == limit)
            #expect(model.cullingUndoCount == limit - 12, "the four oldest ratings dropped, every keyword kept")

            for step in 0 ..< limit {
                #expect(model.canPerform(.undo) && model.perform(.undo), "⌘Z \(step + 1)")
                await sandbox.settled()
            }
            #expect(!model.canPerform(.undo), "nothing older left to take back")
            let keywords = SidecarStore().load(for: sandbox.photo("B.JPG"))?.metadata?.keywords ?? []
            #expect(!keywords.contains { $0.hasPrefix("Limit") }, "every keyword taken back")
            #expect(
                SidecarStore().load(for: sandbox.photo("A.JPG"))?.metadata?.rating == 4,
                "A back to the fourth rating, the oldest kept made before it",
            )
        }
    }

    @Test func `the Put Backs count towards the library's one limit, and alone keep its newest steps`() async throws {
        try await Sandbox.with { sandbox in
            let model = try #require(sandbox.model)
            let limit = 20
            func putBack() async {
                await model.makePutBack(originals: []) {
                    var outcome = FileOutcome(
                        batch: FileBatch(kind: .putBack, title: "Put back 1 photo", steps: []), state: .finished,
                    )
                    outcome.photos = 1
                    return outcome
                }.value
            }
            try await sandbox.select("A.JPG")
            for rating in [ShortcutAction.rating1, .rating2, .rating3, .rating4, .rating5] {
                #expect(model.perform(rating))
            }
            await sandbox.settled()
            for _ in 0 ..< 18 {
                await putBack()
            }
            #expect(model.putBackSteps.undo.count == 18 && model.cullingUndoCount == 2, "the three oldest ratings")
            for _ in 0 ..< 4 {
                await putBack()
            }
            #expect(model.cullingUndoCount == 0, "the last two ratings, older than every Put Back")
            #expect(model.putBackSteps.undo.count == limit)
            let newest = model.putBackSteps.undo.last.map(ObjectIdentifier.init)
            await putBack()
            #expect(model.putBackSteps.undo.count == limit, "the oldest Put Back dropped for the newest")
            #expect(model.putBackSteps.undo.dropLast().last.map(ObjectIdentifier.init) == newest)
        }
    }

    @Test func `⌘Z pressed as a move is asked for takes it back once its batch is done`() async throws {
        try await Sandbox.with { sandbox in
            let model = try #require(sandbox.model)
            let d = sandbox.photo("D.JPG")
            let moving = Task { await model.movePhotos([d], to: sandbox.picked) }
            try await sandbox.eventually { model.fileUndoCount == 1 }
            #expect(model.canPerform(.undo) && model.perform(.undo), "on Undo as soon as it's asked for")
            #expect(await moving.value == nil)
            await sandbox.settled()
            #expect(FileManager.default.fileExists(atPath: d.path), "D back in Shoot")
            #expect(!FileManager.default.fileExists(atPath: sandbox.photo("D.JPG", in: sandbox.picked).path))
            #expect(model.fileUndoCount == 0 && model.fileRedoCount == 1)
            try await sandbox.eventually { sandbox.model.items.count == 4 }
            #expect(model.items.map(\.name).contains("D.JPG"))
        }
    }
}
