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

/// What else the library's rows do on ⌘↵ (LIB-19): a folder shown in Library or revealed in Finder, a photo opened
/// in Develop, a keyword left out of the filter or added to the selected photos, the selected photos added to a
/// collection; and the actions on the selection run on every photo selected.
@MainActor
struct CommandPaletteRowActionsTests {
    private static let photos: [(path: String, metadata: PhotoMetadata)] = [
        ("Lisbon Trip/IMG_0001.JPG", PhotoMetadata(keywords: ["Animals/Birds"], collections: ["Trips/Lisbon"])),
        ("Lisbon Trip/IMG_0002.JPG", PhotoMetadata()),
        ("Studio/IMG_0003.JPG", PhotoMetadata()),
        ("Studio/IMG_0004.JPG", PhotoMetadata()),
    ]

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "palette-row-actions-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "palette-row-actions-tests-\(UUID().uuidString)"
    private let opened = Opened()

    @MainActor
    final class Opened {
        var service: LibraryService?
        var revealed: [URL] = []
    }

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private func cleanUp() {
        LibrarySandbox.remove(base, closing: [opened.service])
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func url(_ path: String) -> URL {
        root.appending(path: path).standardizedFileURL
    }

    /// The photos indexed and shown in an editor's Library from the library, with their subfolders.
    private func open() async throws -> EditorModel {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        for (index, photo) in Self.photos.enumerated() {
            let url = url(photo.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            let context = try #require(CGContext(
                data: nil, width: 64 + index * 8, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            context.setFillColor(red: CGFloat(index) / 4, green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64 + index * 8, height: 48))
            let data = NSMutableData()
            let destination = try #require(
                CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
            )
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
            if !photo.metadata.isEmpty {
                try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: photo.metadata), for: url)
            }
        }
        let library = FolderLibrary()
        library.add([root])
        let paths = LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        opened.service = service
        for _ in 0 ..< 2000 {
            if await service.canShow(root, includingSubfolders: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let model = EditorModel(engine: StubEngine(), library: library)
        library.setIncludesSubfolders(true)
        model.open([root])
        model.showModule(.library)
        try await eventually(seconds: 20) {
            library.isShownFromLibrary && !library.isListing && library.count == Self.photos.count
        }
        try #require(library.isShownFromLibrary)
        let opened = opened
        model.libraryViews.revealInFinder = { opened.revealed += $0 }
        return model
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Opens the palette, types `text`, waits for the library's rows, and highlights the first that `matches`.
    private func highlight(
        _ text: String, in model: EditorModel, where matches: (PaletteItem) -> Bool,
    ) async throws -> CommandPaletteModel {
        model.openCommandPalette()
        let palette = try #require(model.commandPalette)
        palette.setText(text)
        try await eventually { palette.library.text == text && !palette.library.isSearching }
        let found = palette.rows.first(where: matches)
        let row = try #require(found, "\(text): \(palette.rows.map(\.title))")
        palette.select(row)
        return palette
    }

    /// Whether `item` is the folder or photo whose path ends with `path`: the index keeps the paths it was given.
    private static func isFolder(_ path: String) -> (PaletteItem) -> Bool {
        { item in
            if case let .libraryName(.folder, found) = item.kind {
                return found.hasSuffix("/" + path)
            }
            return false
        }
    }

    private static func isPhoto(_ path: String) -> (PaletteItem) -> Bool {
        { item in
            if case let .photo(found) = item.kind {
                return found.hasSuffix("/" + path)
            }
            return false
        }
    }

    private func choose(_ action: PaletteRowAction, in palette: CommandPaletteModel) throws {
        palette.handle(.rowActions)
        #expect(palette.page == .actions)
        let row = try #require(palette.rows.first { $0.kind == .rowAction(action) }, "\(palette.rows.map(\.title))")
        palette.select(row)
        palette.handle(.submit)
    }

    @Test func `⌘↵ on a folder reveals it in Finder, or from Develop shows it in Library`() async throws {
        defer { cleanUp() }
        let model = try await open()
        var palette = try await highlight("studio", in: model, where: Self.isFolder("Studio"))
        palette.handle(.rowActions)
        #expect(palette.rows.map(\.kind) == [.rowAction(.primary), .rowAction(.revealInFinder)], "in Library already")
        palette.handle(.escape)
        try choose(.revealInFinder, in: palette)
        #expect(opened.revealed.map(\.lastPathComponent) == ["Studio"])
        #expect(model.commandPalette == nil)

        model.showModule(.develop)
        palette = try await highlight("studio", in: model, where: Self.isFolder("Studio"))
        try choose(.showInLibrary, in: palette)
        #expect(model.module == .library)
        try await eventually { model.folder?.lastPathComponent == "Studio" }
        #expect(model.folder?.lastPathComponent == "Studio")
    }

    @Test func `⌘↵ on a photo opens it in Develop`() async throws {
        defer { cleanUp() }
        let model = try await open()
        let palette = try await highlight("IMG_0003", in: model, where: Self.isPhoto("Studio/IMG_0003.JPG"))
        try choose(.openInDevelop, in: palette)
        #expect(model.module == .develop)
        try await eventually { model.selection?.lastPathComponent == "IMG_0003.JPG" }
        #expect(model.selection?.lastPathComponent == "IMG_0003.JPG")
    }

    @Test func `⌘↵ on a keyword leaves it out of the filter, or adds it to the photos selected`() async throws {
        defer { cleanUp() }
        let model = try await open()
        let filters = try #require(model.libraryFilters)
        let isBirds: (PaletteItem) -> Bool = { $0.kind == .libraryName(.keyword, "Animals/Birds") }
        var palette = try await highlight("birds", in: model, where: isBirds)
        try choose(.filterOut, in: palette)
        #expect(filters.filter.text == "-kw:Animals/Birds")
        #expect(filters.isBarShown)
        filters.clear()

        let studio = url("Studio/IMG_0003.JPG")
        model.libraryPanels.follow()
        model.select(studio)
        try await eventually { model.libraryPanels.selection.ids.count == 1 }
        palette = try await highlight("birds", in: model, where: isBirds)
        try choose(.addKeywordToSelection, in: palette)
        try await eventually(seconds: 20) {
            SidecarStore().load(for: studio)?.metadata?.keywords?.contains("Animals/Birds") == true
        }
        #expect(SidecarStore().load(for: studio)?.metadata?.keywords == ["Animals/Birds"])
    }

    @Test func `⌘↵ on a collection adds the photos selected to it`() async throws {
        defer { cleanUp() }
        let model = try await open()
        let photo = url("Studio/IMG_0004.JPG")
        model.select(photo)
        try await eventually { model.selection?.standardizedFileURL == photo }
        let palette = try await highlight("lisbon", in: model) { $0.kind == .libraryName(.collection, "Trips/Lisbon") }
        palette.handle(.rowActions)
        #expect(palette.rows.last?.title == "Add the Selected Photo to It")
        palette.handle(.escape)
        try choose(.addSelectionToCollection, in: palette)
        try await eventually(seconds: 20) {
            SidecarStore().load(for: photo)?.metadata?.collections.contains("Trips/Lisbon") == true
        }
        #expect(SidecarStore().load(for: photo)?.metadata?.collections == ["Trips/Lisbon"])
    }

    @Test func `the selection's actions run on every photo selected`() async throws {
        defer { cleanUp() }
        let model = try await open()
        model.selectAllPhotos()
        try await eventually { model.selectedCount == Self.photos.count }
        try PaletteRecents.$override.withValue(PaletteRecents(defaults: nil)) {
            model.openCommandPalette()
            let palette = try #require(model.commandPalette)
            let selection = try #require(palette.sections.first)
            #expect(selection.title == "Selection · \(Self.photos.count) photos")
            #expect(selection.items.contains { $0.kind == .action(.stackPhotos) })
            let rating = try #require(selection.items.first { $0.kind == .action(.rating4) })
            palette.select(rating)
            palette.activate(rating)
        }
        try await eventually(seconds: 20) {
            Self.photos.allSatisfy { SidecarStore().load(for: url($0.path))?.metadata?.rating == 4 }
        }
        for photo in Self.photos {
            #expect(SidecarStore().load(for: url(photo.path))?.metadata?.rating == 4, "\(photo.path)")
        }
    }
}
