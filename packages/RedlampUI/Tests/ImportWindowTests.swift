import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import window (LIB-27), driven as the window drives it: its sources browsed and counted, the
/// photos chosen, rated, flagged and labelled from the grid's keys, the templates' example and errors,
/// Import copying to the destination and the backup with the choices made and showing the photos in
/// Library, Cancel and Import again, a forced quit resumed, what a card's insertion does, and the columns
/// taking the window's width.
@MainActor
@Suite(.serialized)
struct ImportWindowTests {
    @Test func `a folder's photos are listed, those the library has counted apart and left out`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await fixture.index(fixture.folder("Shelf", count: 2))
        let card = try fixture.folder("Card", count: 5)
        let model = fixture.model()
        model.start()
        try await model.addFolder(card)
        await model.browsed()
        let source = try #require(model.sources.first)
        #expect(source.photos.count == 5 && source.imported == 2 && source.isBrowsed)
        #expect(model.detail(of: source) == "5 photos, 2 already in the library")
        #expect(model.chosen.photos == 3)
        #expect(model.summary.hasPrefix("3 photos chosen") && model.summary.contains("2 photos already in the library"))
        #expect(model.photos.map(\.primary.name) == (0 ..< 5).reversed().map(ImportWindowFixture.name), "newest first")
        #expect(model.photos.filter(model.isLeftOut).map(\.primary.name).sorted() == ["IMG_0000.JPG", "IMG_0001.JPG"])
        let leftOut = try #require(model.photos.first { model.isLeftOut($0) })
        model.choose([leftOut.id], true)
        #expect(model.chosen.photos == 3, "a photo the library has can't be chosen")

        // Several at once: each counted, and left out of the import with its box.
        try await model.addFolder(fixture.folder("Other", count: 2, from: 10))
        await model.browsed()
        #expect(model.sources.count == 2 && model.chosen.photos == 5)
        #expect(model.shown == model.sources[1].id && model.photos.count == 2)
        model.setIncluded(model.sources[1].id, false)
        #expect(model.chosen.photos == 3)
    }

    @Test func `the keys Library uses rate, flag, label and choose the photos selected in the grid`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 3))
        await model.browsed()
        let grid = ImportGridViewController(model: model, thumbnails: ImportThumbnails(store: fixture.store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = grid.view
        model.onChange = { grid.modelChanged($0) }
        grid.modelChanged(.photos(ids: nil))
        grid.collectionView.layoutSubtreeIfNeeded()
        #expect(grid.collectionView.allowsMultipleSelection && grid.collectionView.isSelectable)
        grid.collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)]
        let (first, second, third) = try (
            #require(model.photo(at: 0)?.id), #require(model.photo(at: 1)?.id), #require(model.photo(at: 2)?.id),
        )
        func press(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0,
            )
            if let event {
                grid.collectionView.keyDown(with: event)
            }
        }
        func choices(_ id: String) -> ImportChoices? {
            model.photo(id: id)?.choices
        }
        press("3")
        #expect(choices(first)?.rating == 3 && choices(third)?.rating == 3 && choices(second)?.rating == 0)
        press("p")
        #expect(choices(first)?.flag == .pick && choices(third)?.flag == .pick)
        press("x")
        #expect(choices(first)?.flag == .reject)
        press("u")
        #expect(choices(first)?.flag == nil && choices(first)?.given.contains(.flag) == true)
        press("6")
        #expect(choices(first)?.label == .red && choices(third)?.label == .red)
        press("6")
        #expect(choices(first)?.label == nil, "the same label key again takes it off")
        press("9")
        #expect(choices(third)?.label == .blue)
        press(" ")
        #expect(choices(first)?.isChosen == false && choices(third)?.isChosen == false && choices(second)?
            .isChosen == true)
        #expect(model.chosen.photos == 1)
        press(" ")
        #expect(choices(first)?.isChosen == true)
        press("0")
        #expect(choices(first)?.rating == 0 && choices(first)?.given.contains(.rating) == true)
        window.makeFirstResponder(grid.collectionView)
        let selectAll = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        ))
        #expect(grid.collectionView.performKeyEquivalent(with: selectAll))
        #expect(grid.selectedIDs == [first, second, third])
        // The grid's cell says what was given.
        let item = try #require(grid.collectionView.item(at: IndexPath(item: 2, section: 0)))
        #expect(item.view.accessibilityLabel() == model.photo(at: 2)?.primary.name)
        #expect(try ImportGridCell.badges(#require(model.photo(at: 2)), leftOut: false, copied: false) == "Blue")
    }

    @Test func `the templates' live example follows what's typed, and an error in them is said in words`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 2))
        await model.browsed()
        fixture.settle(model)
        func example() async -> String? {
            await model.exampled()
            return model.example
        }
        #expect(await example() == "2026/2026-10-05/IMG_0001.JPG", "the first photo chosen, newest first")
        model.setNames("Lisbon-{seq:3}")
        #expect(await example() == "2026/2026-10-05/Lisbon-001.JPG")
        model.setNames("{date:yyyyMMdd-HHmmss}-{name|lower}")
        #expect(await example() == "2026/2026-10-05/20261005-090001-img_0001.JPG")
        model.setNames("{camra}")
        #expect(model.namesError?.contains("camra isn't a token") == true)
        #expect(model.importBlocker?.hasPrefix("The name template has an error") == true)
        #expect(await example() == nil)
        model.setNames("{name")
        #expect(model.namesError == nil, "a token still being typed isn't an error")
        model.setNames("{name}")
        model.setFolders("{date:yyyy}/{oops}")
        #expect(model.folderError?.contains("oops isn't a token") == true)
        model.setFolders("")
        #expect(model.folderError == nil)
        #expect(await example() == "IMG_0001.JPG")
        model.setText("shoot", "Wedding")
        model.setFolders("{date:yyyy}/{date:yyyy-MM-dd}{text:shoot|before:\" \"}")
        #expect(model.textNames == ["shoot"])
        #expect(await example() == "2026/2026-10-05 Wedding/IMG_0001.JPG")
        let first = try #require(model.photo(at: 0))
        model.choose([first.id], false)
        #expect(await example() == "2026/2026-10-05 Wedding/IMG_0000.JPG", "the first photo chosen")
    }

    @Test func `To's templates and keywords grow to two lines when their text needs them, as it's typed too`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let to = ImportDestinationViewController(model: fixture.model())
        // The column at the width the window gives it, ordered out: CI's screen is smaller than this Mac's.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = to.view
        let folders = try #require(ApplePhotosWindowTests.view("import.folders", in: to.view) as? NSTextField)
        let keywords = try #require(ApplePhotosWindowTests.view("import.keywords", in: to.view) as? NSTokenField)
        func height(_ field: NSTextField) -> CGFloat {
            to.view.layoutSubtreeIfNeeded()
            return field.frame.height
        }
        func type(_ text: String, in field: NSTextField) throws {
            if field.currentEditor() == nil {
                window.makeFirstResponder(field)
            }
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        let oneLine = height(folders)
        // Auto Layout rounds a frame to the screen's pixels; a line can be a fraction of a point taller.
        let twoLines = try oneLine + NSLayoutManager().defaultLineHeight(for: #require(folders.font))
        try type("{date:yyyy}/{date:yyyy-MM-dd} {text:shoot}/{camera}", in: folders)
        #expect(abs(height(folders) - twoLines) < 1, "a template longer than the column, as it's typed")
        try type(String(repeating: "{date:yyyy-MM-dd}/", count: 8), in: folders)
        #expect(abs(height(folders) - twoLines) < 1, "no more than two lines")
        window.makeFirstResponder(nil)
        #expect(abs(height(folders) - twoLines) < 1, "once typed")
        try type("{name}", in: folders)
        #expect(height(folders) == oneLine, "a short template on one line")

        window.makeFirstResponder(nil)
        let oneRow = height(keywords)
        try type("Portugal,Lisbon,Alfama,Street,Night,Tram 28,Miradouro,Graça,Belém", in: keywords)
        #expect(height(keywords) > oneRow, "keywords longer than the column, as they're typed")
        window.makeFirstResponder(nil)
        let twoRows = height(keywords)
        #expect(twoRows > oneRow, "once they're tokens")
        keywords.objectValue = [
            "Portugal",
            "Lisbon",
            "Alfama",
            "Street",
            "Night",
            "Tram 28",
            "Miradouro",
            "Graça",
            "Belém",
            "Sintra",
            "Cascais",
            "Porto",
            "Coimbra",
            "Évora",
        ]
        #expect(height(keywords) == twoRows, "no more than two lines")
        keywords.objectValue = ["Lisbon"]
        #expect(height(keywords) == oneRow, "a keyword on one line")
    }

    @Test func `importing copies the photos chosen to the destination and the backup, with their choices, then shows them in Library, selected`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 4))
        await model.browsed()
        fixture.settle(model)
        model.setKeywords(["Places/Portugal/Lisbon"])
        let names = Dictionary(model.photos.map { ($0.primary.name, $0.id) }) { first, _ in first }
        let (unchosen, rated, picked, red) = try (
            #require(names["IMG_0000.JPG"]), #require(names["IMG_0001.JPG"]), #require(names["IMG_0002.JPG"]),
            #require(names["IMG_0003.JPG"]),
        )
        model.choose([unchosen], false)
        model.rate([rated], 3)
        model.flag([picked], .pick)
        model.label([red], .red)
        let editor = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: fixture.defaults))
        model.showInLibrary = { editor.showImported($0) }
        #expect(model.importBlocker == nil)
        model.startImport()
        await model.imported()
        let outcome = try #require(model.outcome)
        #expect(outcome.state == .finished && outcome.verified == 3 && outcome.isSafeToErase)
        #expect(model.phase == .finished && model.failure == nil && model.chosen.photos == 0)
        #expect(model.detail(of: model.sources[0]).hasPrefix("Safe to erase"))
        let day = "2026/2026-10-05/"
        let photos = ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG"]
        #expect(ImportWindowFixture.files(in: fixture.backup) == Set(photos.map { day + $0 }))
        #expect(ImportWindowFixture.files(in: fixture.destination)
            .filter { $0.hasSuffix(".JPG") } == Set(photos.map { day + $0 }))
        let sidecars = SidecarStore(locator: .besidePhotos)
        func metadata(_ name: String) -> PhotoMetadata? {
            sidecars.load(for: fixture.destination.appending(path: day + name))?.metadata
        }
        #expect(metadata("IMG_0001.JPG")?.rating == 3)
        #expect(metadata("IMG_0002.JPG")?.flag == .pick)
        #expect(metadata("IMG_0003.JPG")?.label == .red)
        #expect(metadata("IMG_0001.JPG")?.keywords == ["Places/Portugal/Lisbon"])
        #expect(model.destinationLines == ["Pictures: 3 of 3 photos verified", "Backup: 3 of 3 photos verified"])

        let folder = fixture.destination.appending(path: day, directoryHint: .isDirectory)
        let shown = photos.map { folder.appending(path: $0) }
        try await waitUntil("the photos selected in Library") { editor.selectedPhotos.count == 3 }
        #expect(editor.module == .library && editor.libraryView == .grid)
        #expect(editor.folder.map(LibraryService.path) == LibraryService.path(folder))
        #expect(Set(editor.selectedPhotos.map(LibraryService.path)) == Set(shown.map(LibraryService.path)))
        #expect(editor.library.root(containing: folder) != nil, "the folder is in Folders")
        // Photos imported are shown so, and Import again finds nothing left.
        let copied = try #require(model.photos.first { $0.id == rated })
        #expect(model.isLeftOut(copied))
        #expect(model.importBlocker == "No photos are chosen.")
    }
}

@MainActor
extension ImportWindowTests {
    @Test func `cancelling stops the copying with nothing half copied, and Import again copies the rest`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        // A slow card: 4 MB a second, one read at a time, so its 24 photos take seconds to copy.
        let slow = SimulatedFileSystem(profile: VolumeProfile(
            name: "slow card", latency: .milliseconds(5), bandwidth: 4_000_000, maxInFlight: 1, isLocal: true,
            isInternal: false,
        ))
        let model = fixture.model(fileSystem: slow)
        try await model.addFolder(fixture.folder("Card", count: 24, padding: 400_000))
        await model.browsed()
        fixture.settle(model)
        model.startImport()
        try await waitUntil("the first photo copied") { model.progress != nil }
        model.cancel()
        await model.imported()
        let stopped = try #require(model.outcome)
        #expect(stopped.state == .stopped && stopped.verified >= 1 && stopped.verified < 24)
        #expect(model.failure?.contains("cancelled") == true)
        for root in [fixture.destination, fixture.backup] {
            #expect(ImportWindowFixture.files(in: root).filter { $0.hasSuffix(".JPG") }.count == stopped.verified)
            #expect(ImportWindowFixture.leftovers(in: root).isEmpty, "nothing half copied at \(root.lastPathComponent)")
        }
        #expect(model.chosen.photos == 24 - stopped.verified)

        model.startImport()
        await model.imported()
        let rest = try #require(model.outcome)
        #expect(rest.state == .finished && rest.verified == 24 - stopped.verified)
        let all = Set((0 ..< 24).map { "2026/2026-10-05/" + ImportWindowFixture.name($0) })
        #expect(ImportWindowFixture.files(in: fixture.backup) == all, "each photo once")
        #expect(model.chosen.photos == 0)
    }

    @Test func `an import a forced quit cut short waits to be resumed, and Resume finishes it`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 6))
        await model.browsed()
        fixture.settle(model)
        model.importer.interruption.withLock { $0 = .afterPhotos(2) }
        model.startImport()
        await model.imported()
        model.close()

        // The next launch's window.
        let next = fixture.model()
        next.start()
        try await waitUntil("the interrupted import") { !next.interrupted.isEmpty }
        #expect(next.importBlocker == "An import that was interrupted has to be resumed or rolled back first.")
        #expect(next.summary.contains("was interrupted with"))
        next.resume()
        await next.imported()
        #expect(next.interrupted.isEmpty && next.failure == nil)
        #expect(next.outcome?.state == .finished && next.outcome?.verified == 6 && next.outcome?.recoveredFrom != nil)
        #expect(ImportWindowFixture.files(in: fixture.backup).count == 6)
        #expect(ImportWindowFixture.leftovers(in: fixture.destination).isEmpty)
    }

    @Test func `a card inserted opens the import window on it while Settings says so`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let preferences = fixture.preferences
        #expect(preferences.showsWindowWhenCardInserted, "on at first, as in Lightroom Classic")
        #expect(!preferences.ejectsAfterImport, "off at first")
        let root = try fixture.card("EOS_DIGITAL", count: 2)
        let other = try fixture.folder("Not a card", count: 1)
        let cards = ImportCards { url in
            url.lastPathComponent == "EOS_DIGITAL" ? try? ImportSource.at(url, medium: .card(at: url)) : nil
        }
        var presented: [ImportSource] = []
        cards
            .onInserted = { card in
                ImportActions.cardInserted(card, preferences: preferences) { presented.append($0) }
            }
        let model = fixture.model(cards: cards)
        model.start()

        cards.mounted(root)
        try await waitUntil("the card listed") { cards.cards.count == 1 }
        #expect(presented.map(\.kind) == [.card] && presented.first?.url.lastPathComponent == "EOS_DIGITAL")
        #expect(model.sources.map(\.source.kind) == [.card], "From lists it as it's inserted")
        cards.mounted(other)
        try await Task.sleep(for: .milliseconds(200))
        #expect(cards.cards.count == 1 && presented.count == 1, "a volume that isn't a card")

        cards.unmounted(root)
        #expect(cards.cards.isEmpty && model.sources.first?.problem == "The card was taken out.")
        preferences.showsWindowWhenCardInserted = false
        cards.mounted(root)
        try await waitUntil("the card listed again") { cards.cards.count == 1 }
        #expect(presented.count == 1, "nothing opens with the setting off")
        #expect(model.sources.count == 1 && model.sources.first?.problem == nil, "the card put back is browsed afresh")
        #expect(
            ImportPreferences(defaults: fixture.defaults).showsWindowWhenCardInserted == false,
            "the setting is kept",
        )
    }

    @Test func `ejecting after Import ejects a card once every photo copied from it is verified`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let cards = try [
            fixture.cardSource(fixture.card("EOS_DIGITAL", count: 3)),
            fixture.cardSource(fixture.card("NIKON", count: 3, from: 10)),
        ]
        let ejected = Mutex<[String]>([])
        for (card, ejects) in zip(cards, [false, true]) {
            let model = fixture.model()
            model.ejector = { card in ejected.withLock { $0.append(card.id) } }
            fixture.preferences.ejectsAfterImport = ejects
            model.add(card)
            await model.browsed()
            fixture.settle(model)
            model.startImport()
            await model.imported()
            #expect(model.outcome?.isSafeToErase == true)
            #expect(ejected.withLock { $0 } == (ejects ? [card.id] : []))
            #expect(model.sources.first?.isEjected == ejects)
            model.close()
        }
    }

    @Test func `the destination, backup, templates, raw only and keywords are kept from one import to the next`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        model.setDestination(fixture.destination)
        model.setBackup(fixture.backup)
        model.setFolders("{date:yyyy}")
        model.setNames("{date:yyyyMMdd}-{seq:3}")
        model.setRawOnly(true)
        model.setKeywords(["Family", "Places/Portugal/Lisbon"])
        model.setText("shoot", "Wedding")
        let kept = ImportPreferences(defaults: fixture.defaults).settings
        #expect(kept == model.settings)
        #expect(kept.destination.path == fixture.destination.path && kept.backup?.path == fixture.backup.path)
        #expect(kept.folders.description == "{date:yyyy}" && kept.names.description == "{date:yyyyMMdd}-{sequence:3}")
        #expect(kept.rawOnly && kept.metadata.keywords == ["Family", "Places/Portugal/Lisbon"])
        #expect(kept.texts == ["shoot": "Wedding"])
        let window = fixture.model()
        #expect(window.folderText == "{date:yyyy}" && window.namesText == "{date:yyyyMMdd}-{sequence:3}")
    }

    @Test func `the first import has no destination until one is chosen, and an earlier version's stays chosen`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 2))
        await model.browsed()
        #expect(!model.hasDestination && model.importBlocker == nil, "Import asks for it")
        model.startImport()
        #expect(model.phase == .choosing, "nothing is imported to Pictures by itself")

        model.setDestination(fixture.destination)
        #expect(model.hasDestination && ImportPreferences(defaults: fixture.defaults).hasDestination)
        model.close()

        let suite = "import-earlier-\(UUID().uuidString)"
        let earlier = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        try earlier.set(
            JSONEncoder().encode(ImportSettings(destination: fixture.destination)),
            forKey: "import.settings",
        )
        #expect(ImportPreferences(defaults: earlier).hasDestination)
    }

    @Test func `the destination and the backup keep a bookmark each, and a folder no longer chosen loses its`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.backup, withIntermediateDirectories: true)
        let makes = FolderAccess.bookmark(for: fixture.destination) != nil
        let model = fixture.model()
        fixture.settle(model)
        let both = Set([fixture.destination.path, fixture.backup.path].map { URL(fileURLWithPath: $0).path })
        #expect(ImportPreferences(defaults: fixture.defaults).bookmarks.paths == (makes ? both : []))
        model.setBackup(nil)
        #expect(ImportPreferences(defaults: fixture.defaults).bookmarks
            .paths == (makes ? [fixture.destination.path] : []))
        model.close()

        let suite = "import-earlier-\(UUID().uuidString)"
        let earlier = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = ImportSettings(destination: fixture.destination, backup: fixture.backup)
        try earlier.set(JSONEncoder().encode(settings), forKey: "import.settings")
        let preferences = ImportPreferences(defaults: earlier)
        #expect(preferences.bookmarks.paths.isEmpty, "earlier versions kept none")
        await preferences.bookmarkRemembered()
        #expect(ImportPreferences(defaults: earlier).bookmarks.paths == (makes ? both : []))
    }

    @Test func `a metadata preset chosen in To is written at the destination, its codes expanded, and kept for the next`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let metadata = LibraryMetadata(index: fixture.index, paths: fixture.paths)
        try await metadata.save(MetadataPreset(name: "Wedding", fields: [
            .caption: MetadataPreset.Entry(#"at \ch\"#, mode: .append), .creator: MetadataPreset.Entry("Studio Lumen"),
            .city: MetadataPreset.Entry("Sintra"),
        ]))
        try await metadata.save(MetadataPreset(name: "Studio", fields: [.copyright: MetadataPreset.Entry("© Lumen")]))
        try await metadata.saveCodeReplacements("ch\tthe chapel\n")
        let model = fixture.model()
        await model.readPresets()
        #expect(model.metadataPresets.map(\.name) == ["Studio", "Wedding"] && model.preset == nil)
        try await model.addFolder(fixture.folder("Card", count: 2))
        await model.browsed()
        fixture.settle(model)
        model.setPreset(named: "Wedding")
        #expect(model.preset?.name == "Wedding")
        #expect(try ImportDestinationViewController.describe(#require(model.preset))
            == "Fills in Caption (Append), Creator and City.")
        model.startImport()
        await model.imported()
        #expect(model.outcome?.verified == 2 && model.failure == nil)
        let sidecars = SidecarStore(locator: .besidePhotos)
        for number in 0 ..< 2 {
            let written = sidecars.load(
                for: fixture.destination.appending(path: "2026/2026-10-05/" + ImportWindowFixture.name(number)),
            )?.metadata
            #expect(written?.caption == "at the chapel" && written?.creator == "Studio Lumen")
            #expect(written?.location == PhotoLocation(city: "Sintra") && written?.copyright == nil)
        }
        #expect(ImportPreferences(defaults: fixture.defaults).settings.metadata.name == "Wedding", "kept")
        #expect(model.settings.metadata.fields.isEmpty, "read from the library at each import, not kept")

        try await metadata.removePreset(named: "Wedding")
        let next = fixture.model()
        await next.readPresets()
        #expect(next.metadataPresets.map(\.name) == ["Studio"] && next.preset == nil, "gone from the library")
        next.setPreset(named: nil)
        #expect(ImportPreferences(defaults: fixture.defaults).settings.metadata.name.isEmpty)
    }

    @Test func `keywords typed are completed from the library's`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let shelf = try fixture.folder("Shelf", count: 1)
        try SidecarStore(locator: .besidePhotos).save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: ["Places/Portugal/Lisbon"])),
            for: shelf.appending(path: ImportWindowFixture.name(0)),
        )
        try await fixture.index(shelf)
        let model = fixture.model()
        model.start()
        try await waitUntil("the library's keywords") { model.keywordCompletion != nil }
        #expect(model.keywords(completing: "lis").contains("Places/Portugal/Lisbon"))
    }

    @Test func `the columns and the bar under them take the window's width as it's resized`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let controller = ImportWindowController(model: fixture.model())
        defer { controller.close() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let summary = try #require(ApplePhotosWindowTests.view("import.summary", in: content))
        let importButton = try #require(ApplePhotosWindowTests.button("import.import", in: content))
        /// Where the constraints put each view: a label's frame reaches past its text.
        func frame(_ view: NSView) -> NSRect {
            content.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
        }
        var sides: (from: CGFloat, to: CGFloat)?
        // Ordered out, the window takes any size: CI's screen is smaller than this Mac's.
        for width in [1000, 1180, 1700] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            content.layoutSubtreeIfNeeded()
            let (from, to) = (frame(controller.sourcesView.view), frame(controller.destinationView.view))
            #expect(from.minX == 0 && to.maxX == width, "the columns span the window at \(width) points")
            #expect(
                sides.map { $0 == (from.width, to.width) } ?? true,
                "From and To keep their widths at \(width) points, the photos taking the rest",
            )
            sides = sides ?? (from.width, to.width)
            #expect(
                frame(summary).minX == 16 && frame(importButton).maxX == width - 16,
                "the line at the bar's leading edge and Import at its trailing edge at \(width) points",
            )
        }
    }
}
