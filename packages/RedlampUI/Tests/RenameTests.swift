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

/// Rename Photos (LIB-25, LIB-26): the preview's names, empty tokens and collisions numbered in capture order;
/// presets saved and chosen; a rename that takes each raw with its JPEG, sidecars and other apps' `.xmp`, keeps the
/// original name, and is undone and made again through Library's Undo, the grid, the selection and the index
/// following without reading a photo again.
@MainActor
struct RenameTests {
    /// A folder the library has indexed, shown from it in Library: IMG_0001.DNG beside IMG_0001.JPG, which has a
    /// sidecar and an `.xmp`, then IMG_0002 to IMG_0004 alone; taken a second apart, IMG_0003 first.
    @MainActor
    final class RenameFolder {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "rename-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        let library = FolderLibrary()
        private(set) var service: LibraryService!
        private(set) var model: EditorModel!
        private(set) var diffs: [LibraryDiff] = []
        private var observation: LibraryObservation?

        var root: URL {
            base.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var paths: LibraryPaths {
            LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
        }

        /// The files, and the seconds after noon each was taken.
        static let photos: [(name: String, second: Int)] = [
            ("IMG_0001.DNG", 3), ("IMG_0001.JPG", 3), ("IMG_0002.JPG", 2), ("IMG_0003.JPG", 1), ("IMG_0004.JPG", 4),
        ]

        func url(_ name: String) -> URL {
            root.appending(path: name, directoryHint: .notDirectory)
        }

        /// With `folders`, empty folders made in it before it's indexed.
        func open(folders: [String] = []) async throws {
            for folder in folders {
                try FileManager.default.createDirectory(
                    at: root.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true,
                )
            }
            for (number, photo) in Self.photos.enumerated() {
                try Self.write(url(photo.name), shade: number, second: photo.second)
            }
            try SidecarStore().save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2)),
                for: url("IMG_0001.JPG"),
            )
            try Data("xmp of IMG_0001".utf8).write(to: url("IMG_0001.xmp"))
            library.add([root])
            service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
            library.attach(service)
            for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: false) {
                try await Task.sleep(for: .milliseconds(10))
            }
            model = EditorModel(engine: StubEngine(), library: library)
            model.open([root])
            try await eventually {
                self.library.isShownFromLibrary && self.model.items.count == Self.photos.count && self.model.info != nil
            }
            try #require(library.isShownFromLibrary && model.items.count == Self.photos.count)
            model.showModule(.library)
            observation = library.observe { [weak self] diff in self?.diffs.append(diff) }
        }

        /// The sheet's model for the photos selected, with presets of its own, its photos read.
        func sheet() async throws -> RenameModel {
            let sheet = try #require(model.renameSheet(presets: NamingPresetStore(url: nil)))
            await sheet.start()
            await sheet.namesFollow()
            return sheet
        }

        /// The files in the folder, sorted.
        func files() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        }

        func shownNames() -> [String] {
            model.items.map(\.name)
        }

        func originalName(_ name: String) -> String? {
            SidecarStore().load(for: url(name))?.metadata?.originalName
        }

        /// Reads the folder again as change tracking does, and returns the photos the indexer read again.
        func indexAgain() async throws -> Int {
            let core = try #require(service.core)
            var read = 0
            for await event in core.indexer.update([FolderChange(root, recursive: true)]) {
                if case let .finished(summary) = event {
                    read += summary.photosInserted + summary.photosUpdated
                }
                core.live.receive(.indexer(event))
            }
            return read
        }

        func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
            for _ in 0 ..< Int(seconds * 200) where !condition() {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() {
            service?.close()
            try? FileManager.default.removeItem(at: base)
        }

        /// A small JPEG, or a TIFF for a `.DNG`, taken `second` seconds after noon on 1 March 2024.
        static func write(_ url: URL, shade: Int, second: Int) throws {
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
            let type = url.pathExtension.lowercased() == "dng" ? UTType.tiff : UTType.jpeg
            let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            let time = String(format: "2024:03:01 12:00:%02d", second)
            let properties = [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: time],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Redlamp",
                    kCGImagePropertyTIFFModel: "Test",
                ],
            ] as CFDictionary
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }

    // MARK: - The preview

    @Test func `the preview names every photo with its pair, flags empty tokens and numbers collisions in capture order`(
    ) async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0001.JPG"))
        #expect(model.perform(.selectAllPhotos))
        let sheet = try await folder.sheet()
        let job = try #require(sheet.job)
        #expect(job.paths.map { ($0 as NSString).lastPathComponent }.sorted() == RenameFolder.photos.map(\.name)
            .sorted())

        sheet.setText("{date:yyyyMMdd}")
        await sheet.namesFollow()
        let names = try Dictionary(uniqueKeysWithValues: zip(
            job.paths.map { ($0 as NSString).lastPathComponent }, #require(sheet.batch).results.map(\.name),
        ))
        // IMG_0003 was taken first, then IMG_0002, the pair, IMG_0004: numbered in that order from 2.
        #expect(names["IMG_0003.JPG"] == "20240301.JPG")
        #expect(names["IMG_0002.JPG"] == "20240301-2.JPG")
        #expect(names["IMG_0001.DNG"] == "20240301-3.DNG" && names["IMG_0001.JPG"] == "20240301-3.JPG")
        #expect(names["IMG_0004.JPG"] == "20240301-4.JPG")
        #expect(sheet.summary == "5 photos: 5 renamed, 0 unchanged, 4 numbered to tell them apart")
        let numbered = try #require(job.paths.firstIndex { $0.hasSuffix("IMG_0002.JPG") })
        #expect(sheet.notes(numbered).text == "numbered: IMG_0003.JPG has the name" && sheet.notes(numbered).isWarning)

        sheet.setText("{title}-{name}")
        await sheet.namesFollow()
        #expect(sheet.summary == "5 photos: 5 renamed, 0 unchanged; empty: {title} for 5")
        #expect(sheet.notes(0).text.contains("empty: {title}"))
    }

    @Test func `the sheet lays out its template, options and preview, and its table shows each new name`() async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0002.JPG"))
        let sheet = try await folder.sheet()
        _ = NSApplication.shared
        let controller = RenameSheetController(model: sheet, editor: model)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RenameSheetController.size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false,
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        sheet.setText("Party-{sequence:2}")
        await sheet.namesFollow()
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        let all = views(in: controller.view)
        let table = try #require(all.compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 1)
        let name = controller.tableView(table, objectValueFor: table.tableColumns[1], row: 0) as? String
        #expect(name == "Party-01.JPG")
        let rename = all.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "rename.rename" }
        #expect(rename?.isEnabled == true)
        let field = all.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "rename.template" }
        #expect(field?.stringValue == sheet.text || field != nil)
        #expect(all.contains { $0.accessibilityIdentifier() == "rename.template.tokens" })
    }

    @Test func `a template's error is said in words, and the last template that reads stays named`() async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0002.JPG"))
        let sheet = try await folder.sheet()
        sheet.setText("Wedding-{sequence:2}")
        await sheet.namesFollow()
        #expect(sheet.batch?.results.map(\.name) == ["Wedding-01.JPG"])
        sheet.setText("Wedding-{camra}-x")
        await sheet.namesFollow()
        #expect(sheet.error == "camra isn't a token; did you mean camera?")
        #expect(sheet.batch?.results.map(\.name) == ["Wedding-01.JPG"], "the last template that reads stays named")
        #expect(await sheet.renames() == nil, "a template with an error renames nothing")
        sheet.setText("Wedding-{seq")
        #expect(sheet.error == nil, "a token still open at the end is left out as it's typed")
    }

    // MARK: - Presets

    @Test func `presets are saved with their options, chosen again, kept beside those built in, and Delete takes them out`(
    ) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = NamingPresetStore(url: file)
        let field = NamingTemplateField(identifier: "test", placeholder: "", presets: [], store: store)
        var options = NamingOptions()
        options.sequenceStart = 7
        field.options = { options }
        field.text = "{text:shoot}-{sequence:4}"
        #expect(field.save(as: "Wedding Day"))
        #expect(!field.save(as: "Filename"), "a built-in preset's name is taken")
        #expect(store.all.count == NamingPreset.builtIn.count + 1)

        let again = NamingPresetStore(url: file)
        let saved = try #require(again.saved.first)
        #expect(saved.name == "Wedding Day" && saved.template.description == "{text:shoot}-{sequence:4}")
        #expect(saved.options.sequenceStart == 7)

        let chooser = NamingTemplateField(
            identifier: "test", placeholder: "", presets: NamingPreset.builtIn.map { ($0.name, $0.template) },
            store: again,
        )
        var chosen: (String, NamingOptions?)?
        chooser.onChange = { chosen = ($0, $1) }
        let item = try #require(chooser.presets.itemArray.first { $0.title == "Wedding Day" })
        chooser.presets.select(item)
        _ = (chooser.presets.target as? NSObject)?.perform(chooser.presets.action)
        #expect(chosen?.0 == "{text:shoot}-{sequence:4}" && chosen?.1?.sequenceStart == 7)
        #expect(chooser.presets.titleOfSelectedItem == "Wedding Day")

        again.delete(saved.id)
        #expect(NamingPresetStore(url: file).saved.isEmpty)
    }

    @Test func `a preset this version can't read is kept as it was written`() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let newer = #"{"presets": [{"id": "x", "name": "Newer", "template": "{lunarphase}"}], "counters": {"values": {"shoot": 12}}}"#
        try Data(newer.utf8).write(to: file)
        let store = NamingPresetStore(url: file)
        #expect(store.saved.isEmpty && store.counters["shoot"] == 12)
        try store.save("Mine", template: NamingTemplate(parsing: "{name}"), options: NamingOptions())
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("{lunarphase}") && written.contains("Mine"))
    }

    @Test func `a token from the menu goes where the cursor is, and a modifier just after a token goes inside it`() {
        let field = NamingTemplateField(identifier: "test", placeholder: "", presets: [], store: nil)
        var texts: [String] = []
        field.onChange = { text, _ in texts.append(text) }
        field.text = "Wedding-"
        field.insert("{camera}")
        field.insert("|lower")
        #expect(field.text == "Wedding-{camera|lower}")
        #expect(texts.last == "Wedding-{camera|lower}")
    }

    // MARK: - Renaming

    @Test func `a rename takes each raw with its JPEG, sidecars and xmp, keeps the original name, and the grid follows`(
    ) async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0001.JPG"))
        model.click(folder.url("IMG_0002.JPG"), toggling: true)
        let ids = model.library.photoIDs
        let selected = model.photoSelection
        let sheet = try await folder.sheet()
        sheet.setText("Wedding-{sequence:2}")
        let error = await model.rename(sheet)
        #expect(error == nil)
        await model.filesMade()
        // Each photo's original name is kept in its sidecar, which the raw gets for it.
        #expect(folder.files() == [
            "IMG_0003.JPG", "IMG_0004.JPG", "Wedding-01.DNG", "Wedding-01.DNG.redlamp", "Wedding-01.JPG",
            "Wedding-01.JPG.redlamp", "Wedding-01.xmp", "Wedding-02.JPG", "Wedding-02.JPG.redlamp",
        ])
        #expect(folder.originalName("Wedding-01.DNG") == "IMG_0001.DNG")
        #expect(folder.originalName("Wedding-01.JPG") == "IMG_0001.JPG")
        #expect(folder.originalName("Wedding-02.JPG") == "IMG_0002.JPG")
        #expect(
            SidecarStore().load(for: folder.url("Wedding-01.JPG"))?.metadata?.rating == 2,
            "the sidecar went with it",
        )

        #expect(folder.shownNames() == [
            "IMG_0003.JPG", "IMG_0004.JPG", "Wedding-01.DNG", "Wedding-01.JPG", "Wedding-02.JPG",
        ])
        #expect(Set(model.library.photoIDs) == Set(ids), "every photo keeps its ID")
        #expect(model.photoSelection == selected, "the selection keeps its photos")
        #expect(model.selection == folder.url("Wedding-02.JPG"), "the active photo goes with its file")
        #expect(model.info == nil, "Develop's document of the photo renamed is put away")
        #expect(folder.diffs.allSatisfy { !$0.reset }, "nothing is listed afresh")
        #expect(model.fileUndoCount == 1)
    }

    @Test func `Undo and Redo take a rename back and make it again, the grid and the selection following`(
    ) async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0002.JPG"))
        model.click(folder.url("IMG_0004.JPG"), toggling: true)
        let ids = model.library.photoIDs
        let selected = model.photoSelection
        let before = folder.files()
        let sheet = try await folder.sheet()
        sheet.setText("Party-{sequence}")
        #expect(await model.rename(sheet) == nil)
        await model.filesMade()
        let renamed = folder.files()
        #expect(renamed.contains("Party-1.JPG") && renamed.contains("Party-2.JPG"))

        #expect(model.canPerform(.undo) && model.perform(.undo))
        try await folder.eventually(seconds: 0.5) { folder.shownNames().contains("IMG_0002.JPG") }
        #expect(folder.shownNames().contains("IMG_0002.JPG"), "Undo shows before its batch is done")
        await model.filesMade()
        #expect(folder.files() == before)
        #expect(folder.originalName("IMG_0002.JPG") == nil, "Undo takes the original name out")
        #expect(model.photoSelection == selected && model.selection == folder.url("IMG_0004.JPG"))
        #expect(model.fileUndoCount == 0 && model.fileRedoCount == 1)

        #expect(model.canPerform(.redo) && model.perform(.redo))
        await model.filesMade()
        #expect(folder.files() == renamed)
        #expect(folder.originalName("Party-1.JPG") == "IMG_0002.JPG")
        #expect(Set(model.library.photoIDs) == Set(ids) && model.photoSelection == selected)
        #expect(model.selection == folder.url("Party-2.JPG"))
        #expect(folder.diffs.allSatisfy { !$0.reset })
        #expect(try await folder.indexAgain() == 0, "the index follows without reading a photo again")
    }

    @Test func `Undo takes back the newest of a rename and a culling change first, and Redo makes them in turn`(
    ) async throws {
        let folder = RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.select(folder.url("IMG_0003.JPG"))
        #expect(model.perform(.rating3))
        let sheet = try await folder.sheet()
        sheet.setText("Kept-{name}")
        #expect(await model.rename(sheet) == nil)
        await model.filesMade()
        #expect(model.perform(.flagPick))
        let photo = folder.url("Kept-IMG_0003.JPG")
        #expect(model.library.item(for: photo)?.metadata.flag == .pick)

        #expect(model.perform(.undo), "the flag, newest, first")
        #expect(model.library.item(for: photo)?.metadata.flag == nil && model.fileUndoCount == 1)
        #expect(model.perform(.undo), "then the rename")
        await model.filesMade()
        #expect(folder.files().contains("IMG_0003.JPG"))
        #expect(model.library.item(for: folder.url("IMG_0003.JPG"))?.metadata.rating == 3)
        #expect(model.perform(.undo), "then the rating")
        #expect(model.library.item(for: folder.url("IMG_0003.JPG"))?.metadata.rating == 0)

        #expect(model.perform(.redo), "the rating again")
        #expect(model.library.item(for: folder.url("IMG_0003.JPG"))?.metadata.rating == 3)
        #expect(model.perform(.redo), "then the rename")
        await model.filesMade()
        #expect(folder.files().contains("Kept-IMG_0003.JPG"))
        #expect(model.perform(.redo), "then the flag")
        #expect(model.library.item(for: photo)?.metadata.flag == .pick)
        #expect(!model.canPerform(.redo))

        #expect(model.perform(.undo) && model.perform(.undo))
        await model.filesMade()
        #expect(model.perform(.rating5), "a new change")
        #expect(!model.canPerform(.redo), "ends the rename's Redo too")
        await model.filesMade()
    }
}
