import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Library's right-hand panels (LIB-21, LIB-22): the selection's keywords, shared and partial; keywords added
/// and removed, and the keyword set's keys; the keyword list's counts, checkboxes, arrow, edits, merging and
/// deleting; the selection's IPTC Core fields, mixed and edited; presets; capture times; each change one batch
/// with Undo and Redo on Library's Undo, in turn with culling's.
@MainActor
struct LibraryPanelsTests {
    /// Small JPEGs taken a minute apart from 2007-06-01 15:30, in a folder the library has indexed and shows,
    /// in Library, with the panels following the selection.
    @MainActor
    final class Folder {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "panels-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        let defaults = UserDefaults(suiteName: "panels-\(UUID().uuidString)")
        private(set) var library: FolderLibrary!
        private(set) var service: LibraryService!
        private(set) var model: EditorModel!
        private(set) var photos: [URL] = []

        var root: URL {
            base.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var panels: LibraryPanels {
            model.libraryPanels
        }

        /// `keywords` gives the photos it names a sidecar holding them.
        func open(count: Int = 6, keywords: [Int: [String]] = [:]) async throws {
            for number in 0 ..< count {
                let url = root.appending(path: String(format: "IMG_%04d.JPG", number), directoryHint: .notDirectory)
                try Self.writeJPEG(url, shade: number, taken: String(format: "2007:06:01 15:%02d:00", 30 + number))
                photos.append(url)
                if let keywords = keywords[number] {
                    try SidecarStore().save(
                        Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: keywords)), for: url,
                    )
                }
            }
            library = FolderLibrary(defaults: defaults)
            library.add([root])
            service = LibraryService(
                paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
                sidecars: library.sidecars,
            ) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
            library.attach(service)
            for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: false) {
                try await Task.sleep(for: .milliseconds(10))
            }
            model = EditorModel(engine: StubEngine(), library: library)
            model.open([root])
            try await eventually {
                self.library.isShownFromLibrary && self.model.items.count >= count && self.model.info != nil
            }
            try #require(library.isShownFromLibrary, "the folder shown from the library")
            model.showModule(.library)
            panels.follow()
            try await eventually { self.panels.keywordList != nil && !self.panels.keywordSets.isEmpty }
        }

        func close() {
            service?.close()
            try? FileManager.default.removeItem(at: base)
        }

        /// Selects the photos numbered `numbers`, the last one clicked active, and waits for the panels to show
        /// them.
        func select(_ numbers: [Int]) async throws {
            let core = try #require(service.core)
            let urls = numbers.map { photos[$0] }
            let ids = await LibraryService.indexIDs(of: urls, in: core.index)
            let expected = urls.compactMap { ids[$0] }.sorted()
            model.select(photos[numbers[0]])
            for number in numbers.dropFirst() {
                model.click(photos[number], toggling: true)
            }
            try await eventually { self.panels.selection.ids == expected }
            try #require(panels.selection.ids == expected, "the panels follow the selection")
        }

        /// Until every change asked for is made, the lists hold it and the panels show it.
        func written() async throws {
            await panels.written()
            await service.settled()
            try await Task.sleep(for: .milliseconds(30))
            await panels.refreshed()
            await panels.keywordsRead()
        }

        func keywords(_ number: Int) -> [String] {
            (SidecarStore().load(for: photos[number])?.metadata?.keywords ?? []).sorted()
        }

        func metadata(_ number: Int) -> PhotoMetadata? {
            SidecarStore().load(for: photos[number])?.metadata
        }

        func batches() async throws -> Int {
            let core = try #require(service.core)
            let keywords = try await LibraryKeywords(index: core.index, paths: core.paths).entries().count
            let metadata = try await LibraryMetadata(index: core.index, paths: core.paths).entries().count
            return keywords + metadata
        }

        func eventually(seconds: Double = 15, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        static func writeJPEG(_ url: URL, shade: Int, taken: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            context.setFillColor(red: CGFloat(shade % 7) / 7, green: CGFloat(shade % 5) / 5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil,
            ))
            let properties = [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: taken],
            ] as CFDictionary
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }

    static func path(_ text: String) -> KeywordPath {
        KeywordPath(text)!
    }

    // MARK: - Keywording

    @Test func `the selection's keywords are full paths, those only some photos have told apart`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(keywords: [0: ["Places/Portugal/Lisbon", "Family"], 1: ["Places/Portugal/Lisbon"]])
        try await folder.select([0, 1, 2])
        let selection = folder.panels.selection
        #expect(selection.keywords == [Self.path("Places/Portugal/Lisbon"): 2, Self.path("Family"): 1])
        #expect(selection.hasEverywhere(Self.path("Places/Portugal/Lisbon")) == nil, "two of the three")
        #expect(selection.hasEverywhere(Self.path("Places")) == false, "a keyword containing one isn't on them")
        try await folder.select([0, 1])
        #expect(folder.panels.selection.hasEverywhere(Self.path("Places/Portugal/Lisbon")) == true)
        #expect(
            folder.panels.selection.orderedKeywords.map(\.path.text) == ["Places/Portugal/Lisbon", "Family"],
            "those on every photo first",
        )
        #expect(KeywordingPanelView.summary(of: folder.panels.selection) == "On 2 selected photos")
    }

    @Test func `keywords typed are completed and added as one batch, with Undo and Redo`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(keywords: [0: ["Places/Portugal/Lisbon"]])
        let panels = folder.panels
        #expect(panels.completions("lis").first?.path == Self.path("Places/Portugal/Lisbon"))
        try await folder.select([0, 1, 2])
        let before = try await folder.batches()
        #expect(panels.addKeywords("Lisbon, Trips > 2007"))
        #expect(panels.selection.hasEverywhere(Self.path("Trips/2007")) == true, "shown at once")
        try await folder.written()
        #expect(try await folder.batches() == before + 1, "one batch")
        for number in 0 ... 2 {
            #expect(folder.keywords(number) == ["Places/Portugal/Lisbon", "Trips/2007"], "photo \(number)")
        }
        #expect(folder.keywords(3).isEmpty)
        #expect(panels.keywordList?[Self.path("Trips/2007")]?.count == 3)

        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.keywords(0) == ["Places/Portugal/Lisbon"] && folder.keywords(1).isEmpty)
        #expect(panels.selection.hasEverywhere(Self.path("Trips/2007")) == false)
        #expect(folder.model.canPerform(.redo))
        #expect(folder.model.perform(.redo))
        try await folder.written()
        #expect(folder.keywords(1) == ["Places/Portugal/Lisbon", "Trips/2007"])

        #expect(panels.remove(Self.path("Places/Portugal/Lisbon")))
        try await folder.written()
        #expect(folder.keywords(0) == ["Trips/2007"] && folder.keywords(2) == ["Trips/2007"])
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.keywords(0) == ["Places/Portugal/Lisbon", "Trips/2007"])
    }

    @Test func `a keyword set's keys toggle its keywords on the selection, and a set is chosen`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open()
        let panels = folder.panels
        try await folder.select([1, 2])
        #expect(panels.activeSet?.name == KeywordSet.recentName)
        panels.chooseKeywordSet("Wedding Photography")
        try await folder.written()
        #expect(panels.activeSet?.name == "Wedding Photography")
        #expect(ShortcutAction.resolve(.char("1", option: true), in: .library)?.action == .keywordSet1)
        #expect(folder.model.canPerform(.keywordSet1))
        #expect(folder.model.perform(.keywordSet1))
        try await folder.written()
        #expect(folder.keywords(1) == ["Bride"] && folder.keywords(2) == ["Bride"])
        #expect(folder.model.perform(.keywordSet3))
        try await folder.written()
        #expect(folder.keywords(2) == ["Bride", "Ceremony"])
        #expect(folder.model.perform(.keywordSet1), "pressed again, it comes off")
        try await folder.written()
        #expect(folder.keywords(1) == ["Ceremony"] && folder.keywords(2) == ["Ceremony"])
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.keywords(1) == ["Bride", "Ceremony"])
        // Recent Keywords has what was added last, first.
        panels.chooseKeywordSet(KeywordSet.recentName)
        try await folder.written()
        #expect(panels.activeSet?.keyword(forShortcut: 1) == Self.path("Ceremony"))
        folder.model.showModule(.develop)
        #expect(!folder.model.canPerform(.keywordSet1), "Library's keys")
    }

    @Test func `Undo and Redo go back through culling's changes and the panels' in the order they were made`(
    ) async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open()
        let model = try #require(folder.model)
        try await folder.select([0, 1])
        #expect(model.perform(.rating2))
        #expect(folder.panels.add([Self.path("Order")]))
        try await folder.written()
        #expect(model.perform(.rating4))
        try await folder.written()
        func rating(_ number: Int) -> Int {
            model.library.item(for: folder.photos[number])?.metadata.rating ?? -1
        }
        try await folder.eventually { rating(0) == 4 }
        #expect(model.perform(.undo), "the second rating")
        try await folder.eventually { rating(0) == 2 }
        #expect(folder.keywords(0) == ["Order"])
        #expect(model.perform(.undo), "the keyword")
        try await folder.written()
        #expect(folder.keywords(0).isEmpty && rating(0) == 2)
        #expect(model.perform(.undo), "the first rating")
        try await folder.eventually { rating(0) == 0 }
        #expect(model.perform(.redo), "the first rating again")
        try await folder.eventually { rating(0) == 2 }
        #expect(folder.keywords(0).isEmpty)
        #expect(model.perform(.redo), "the keyword again")
        try await folder.written()
        #expect(folder.keywords(0) == ["Order"] && rating(0) == 2)
        // A change made now leaves nothing to make again.
        #expect(model.perform(.rating1))
        try await folder.eventually { rating(0) == 1 }
        #expect(!model.canPerform(.redo))
    }

    // MARK: - The keyword list

    @Test func `the keyword list counts by hierarchy, and its checkboxes and arrow work on the selection`(
    ) async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(keywords: [0: ["Places/Portugal/Lisbon"], 1: ["Places/Portugal/Porto"], 2: ["Family"]])
        let panels = folder.panels
        let list = try #require(panels.keywordList)
        #expect(list[Self.path("Places")]?.count == 2 && list[Self.path("Places/Portugal")]?.count == 2)
        #expect(list[Self.path("Places/Portugal/Lisbon")]?.count == 1)
        #expect(list.children(of: Self.path("Places/Portugal")).map(\.name) == ["Lisbon", "Porto"])
        try await folder.select([2, 3])
        #expect(panels.toggle(Self.path("Places/Portugal/Porto")), "a checkbox off puts it on")
        try await folder.written()
        #expect(folder.keywords(2) == ["Family", "Places/Portugal/Porto"] && folder
            .keywords(3) == ["Places/Portugal/Porto"])
        // The list is counted again after the batch, apart from its sidecars' writes.
        try await folder.eventually { panels.keywordList?[Self.path("Places/Portugal/Porto")]?.count == 3 }
        #expect(panels.keywordList?[Self.path("Places/Portugal/Porto")]?.count == 3)
        #expect(panels.toggle(Self.path("Family")), "a checkbox some photos have puts it on them all")
        try await folder.written()
        #expect(folder.keywords(3) == ["Family", "Places/Portugal/Porto"])
        #expect(panels.toggle(Self.path("Family")), "on all, it comes off")
        try await folder.written()
        #expect(folder.keywords(2) == ["Places/Portugal/Porto"])

        panels.showPhotos(of: Self.path("Places/Portugal"))
        let filters = try #require(folder.model.libraryFilters)
        #expect(filters.filter.text == QueryCompletion(field: .keyword, value: "Places/Portugal").term)
        #expect(filters.isBarShown)
        try await folder.eventually { folder.model.items.count == 4 }
        #expect(Set(folder.model.items.map(\.url)) == Set([0, 1, 2, 3].map { folder.photos[$0] }))
    }

    @Test func `a keyword is edited, merged into another and deleted from the list, with Undo`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(keywords: [0: ["Family", "Lisboa"], 1: ["Places/Lisbon"]])
        let panels = folder.panels
        var options = KeywordOptions(synonyms: ["Kin"])
        options.includeOnExport = false
        options.isPerson = true
        #expect(panels.edit(Self.path("Family"), name: "Family & Friends", options: options))
        try await folder.written()
        #expect(folder.keywords(0) == ["Family & Friends", "Lisboa"])
        let edited = try #require(panels.keywordList?[Self.path("Family & Friends")])
        #expect(edited.options.synonyms == ["Kin"] && !edited.options.includeOnExport && edited.options.isPerson)
        #expect(panels.keywordList?[Self.path("Family")] == nil)
        #expect(panels.completions("kin").first?.path == Self.path("Family & Friends"), "found by its synonym")
        #expect(folder.model.perform(.undo), "both its rename and its options")
        try await folder.written()
        #expect(folder.keywords(0) == ["Family", "Lisboa"])
        #expect(panels.keywordList?[Self.path("Family")]?.options.synonyms == [])

        #expect(panels.merge(Self.path("Lisboa"), into: Self.path("Places/Lisbon")))
        try await folder.written()
        #expect(folder.keywords(0) == ["Family", "Places/Lisbon"] && folder.keywords(1) == ["Places/Lisbon"])
        #expect(panels.keywordList?[Self.path("Lisboa")] == nil)
        #expect(panels.keywordList?[Self.path("Places/Lisbon")]?.count == 2)

        #expect(panels.delete(Self.path("Places")))
        try await folder.written()
        #expect(folder.keywords(0) == ["Family"] && folder.keywords(1).isEmpty)
        #expect(panels.keywordList?[Self.path("Places/Lisbon")] == nil)
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.keywords(1) == ["Places/Lisbon"])

        #expect(panels.create("Animals > Birds"))
        try await folder.written()
        #expect(panels.keywordList?[Self.path("Animals/Birds")]?.count == 0, "kept in the list with no photos")
    }

    @Test func `Lightroom's keyword-list file is imported with Undo, and exported`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(keywords: [0: ["Places/Portugal/Lisbon"]])
        let file = folder.base.appending(path: "Keywords.txt")
        try "Animals\n\tBirds\n\t\t{Aves}\n[People]\n\tAna\n".write(to: file, atomically: true, encoding: .utf8)
        let panels = folder.panels
        #expect(await panels.importKeywords(from: file) == 4)
        try await folder.written()
        #expect(panels.keywordList?[Self.path("Animals/Birds")]?.options.synonyms == ["Aves"])
        #expect(panels.keywordList?[Self.path("People")]?.options.includeOnExport == false)
        let exported = folder.base.appending(path: "Exported.txt")
        let export = try #require(await panels.exportKeywords(to: exported))
        let text = try String(contentsOf: exported, encoding: .utf8)
        #expect(export.keywords >= 6 && text.contains("\t\t{Aves}") && text.contains("[People]"))
        #expect(text.contains("Places\n\tPortugal\n\t\tLisbon\n"))
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(panels.keywordList?[Self.path("Animals/Birds")] == nil)
    }

    // MARK: - Metadata

    @Test func `the selection's fields are shown, mixed where they differ, and edited on every photo with Undo`(
    ) async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open()
        let panels = folder.panels
        try await folder.select([0])
        #expect(panels.set(.caption, to: "Tram 28"))
        try await folder.written()
        try await folder.select([1])
        #expect(panels.set(.caption, to: "Alfama"))
        try await folder.written()
        try await folder.select([0, 1, 2])
        #expect(panels.selection.fields[.caption] == .mixed)
        #expect(panels.selection.fields[.title] == SharedValue.none)
        let before = try await folder.batches()
        #expect(panels.set(.title, to: "Lisbon in June"))
        #expect(panels.set(.city, to: "Lisbon"))
        #expect(panels.selection.fields[.title] == .same("Lisbon in June"), "shown at once")
        try await folder.written()
        #expect(try await folder.batches() == before + 2, "a batch each")
        #expect(panels.selection.fields[.title] == .same("Lisbon in June"))
        #expect(panels.selection.fields[.city] == .same("Lisbon"))
        for number in 0 ... 2 {
            #expect(folder.metadata(number)?.title == "Lisbon in June" && folder.metadata(number)?.location?
                .city == "Lisbon")
        }
        #expect(folder.metadata(0)?.caption == "Tram 28", "a field not edited is kept")
        #expect(panels.selection.fields.captured.map { CaptureTimeChange.describe(time: $0.lowerBound) }
            == "2007-06-01 15:30:00")
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.metadata(1)?.location?.city == nil)
        #expect(panels.selection.fields[.city] == SharedValue.none)
        #expect(folder.metadata(1)?.title == "Lisbon in June")
    }

    @Test func `a preset gives only its ticked fields, each replacing, appending or prefixing`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open()
        let panels = folder.panels
        for (number, caption) in [(0, "First dance"), (1, "Vows")] {
            try await folder.select([number])
            panels.set(.caption, to: caption)
            panels.set(.copyright, to: "© Ana")
            try await folder.written()
        }
        var preset = MetadataPreset(name: "Chapel", fields: [
            .caption: MetadataPreset.Entry("at the chapel", mode: .append),
            .title: MetadataPreset.Entry("Wedding"),
            .copyright: MetadataPreset.Entry("2007", mode: .prefix),
        ])
        #expect(await panels.save(preset))
        try await folder.eventually { panels.presets.map(\.name) == ["Chapel"] }
        try await folder.select([0, 1, 2])
        #expect(panels.apply(preset))
        try await folder.written()
        #expect(folder.metadata(0)?.caption == "First dance at the chapel" && folder.metadata(1)?
            .caption == "Vows at the chapel")
        #expect(folder.metadata(2)?.caption == "at the chapel")
        #expect(folder.metadata(0)?.title == "Wedding" && folder.metadata(1)?.copyright == "2007 © Ana")
        #expect(folder.metadata(0)?.creator == nil, "a field it doesn't tick is left as it is")
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(folder.metadata(0)?.caption == "First dance" && folder.metadata(0)?.title == nil)

        preset.fields[.title] = nil
        #expect(await panels.save(MetadataPreset(name: "Chapel 2", fields: preset.fields), replacing: "Chapel"))
        try await folder.eventually { panels.presets.map(\.name) == ["Chapel 2"] }
        #expect(await panels.deletePreset(named: "Chapel 2"))
        try await folder.eventually { panels.presets.isEmpty }
    }

    @Test func `capture times are shifted, or set on the active photo with the others alike, with Undo`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open()
        let panels = folder.panels
        try await folder.select([0, 1])
        #expect(folder.model.selection == folder.photos[1], "the photo clicked last is active")
        func shown() -> String {
            panels.selection.fields.captured.map {
                "\(CaptureTimeChange.describe(time: $0.lowerBound)) \(CaptureTimeChange.describe(time: $0.upperBound))"
            } ?? "none"
        }
        #expect(shown() == "2007-06-01 15:30:00 2007-06-01 15:31:00")
        #expect(folder.model.canPerform(.editCaptureTime))
        #expect(panels.shiftCaptureTime(by: 3600 + 15))
        try await folder.written()
        #expect(folder.metadata(0)?.captureShift == 3615 && folder.metadata(1)?.captureShift == 3615)
        #expect(shown() == "2007-06-01 16:30:15 2007-06-01 16:31:15")
        #expect(folder.metadata(2)?.captureShift == nil)
        #expect(folder.model.perform(.undo))
        try await folder.written()
        #expect(shown() == "2007-06-01 15:30:00 2007-06-01 15:31:00")
        #expect(folder.metadata(0)?.captureShift == nil)

        let formatter = ISO8601DateFormatter()
        #expect(try panels.setCaptureTime(#require(formatter.date(from: "2008-01-02T03:04:05Z"))))
        try await folder.written()
        #expect(shown() == "2008-01-02 03:03:05 2008-01-02 03:04:05", "the active photo set, the other shifted as much")
    }

    // MARK: - The column

    @Test func `the right column's panels open and close, kept between launches`() async throws {
        let folder = Folder()
        defer { folder.close() }
        try await folder.open(count: 2)
        let panels = folder.panels
        #expect(panels.isExpanded(.keywording) && panels.isExpanded(.metadata))
        panels.toggle(.keywordList)
        panels.toggle(.metadata, solo: false)
        #expect(!panels.isExpanded(.keywordList) && !panels.isExpanded(.metadata))
        let again = EditorModel(engine: StubEngine(), library: folder.library)
        #expect(again.libraryPanels.expanded == [.photo, .keywording])
        panels.toggle(.photo, solo: true)
        #expect(panels.expanded == [.photo])
        #expect(ShortcutAction.toggleRightPanel.combos.contains(KeyCombo(.right, option: true, command: true)))
        let visible = folder.model.rightPanelVisible
        #expect(folder.model.perform(.toggleRightPanel))
        #expect(folder.model.rightPanelVisible != visible)
    }
}
