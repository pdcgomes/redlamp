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

/// Stacks in the Library grid and the filmstrip (LIB-28), over a folder the library has indexed: each stack closed as
/// one cell with its count, opened and closed with the grid's cells moved rather than reloaded; a closed stack's
/// selection covering all its photos for clicks, ⌘-clicks, ⇧-clicks, culling and ← and →; stacks closed inside Group
/// By's groups in step with the filmstrip's; and stacking, unstacking and a stack's top as changes with Undo.
@MainActor
struct LibraryStacksTests {
    /// A photo of the folder: when it was taken, seconds after 10:00 on 14 June 2024, and its format.
    struct Photo {
        var path: String
        var time: Double
        var type = UTType.jpeg
    }

    /// A burst of three frames a third of a second apart, B01 to B03; a JPEG beside its HEIC, P01, a minute later;
    /// and S01 to S04 alone, ten minutes apart.
    static let photos = [
        Photo(path: "B01.JPG", time: 0), Photo(path: "B02.JPG", time: 0.33), Photo(path: "B03.JPG", time: 0.66),
        Photo(path: "P01.JPG", time: 60), Photo(path: "P01.HEIC", time: 60, type: .heic),
        Photo(path: "S01.JPG", time: 600), Photo(path: "S02.JPG", time: 1200), Photo(path: "S03.JPG", time: 1800),
        Photo(path: "S04.JPG", time: 2400),
    ]

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "library-stacks-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "library-stacks-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func write(_ photo: Photo) throws {
        let url = root.appending(path: photo.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            photo.type.identifier as CFString,
            1,
            nil,
        ))
        let whole = photo.time.rounded(.down)
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: String(
                    format: "2024:06:14 10:%02d:%02d", Int(whole) / 60, Int(whole) % 60,
                ),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", Int((photo.time - whole) * 100)),
                kCGImagePropertyExifExposureTime: 1.0 / 500,
            ],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// The folder indexed, open in an editor from the library, with its grid and filmstrip shown in a window, which
    /// the test keeps until it ends, once its stacks are found.
    private func open() async throws -> (EditorModel, LibraryGridView, FilmstripStripView, NSWindow) {
        for photo in Self.photos {
            try write(photo)
        }
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars, defaults: UserDefaults(suiteName: suite)!,
        ) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        for _ in 0 ..< 2000 {
            if await service.canShow(root, includingSubfolders: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let model = EditorModel(engine: StubEngine(), library: library)
        model.open([root])
        let count = Self.photos.count
        try await eventually(seconds: 20) { library.isShownFromLibrary && !library.isListing && library.count == count }
        try #require(library.isShownFromLibrary && library.count == count)
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 1200), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        let grid = LibraryGridView(model: model)
        let strip = FilmstripStripView(model: model)
        let content = NSView(frame: window.contentLayoutRect)
        grid.frame = CGRect(x: 0, y: FilmstripStripView.height, width: 900, height: 1200 - FilmstripStripView.height)
        strip.frame = CGRect(x: 0, y: 0, width: 900, height: FilmstripStripView.height)
        content.addSubview(grid)
        content.addSubview(strip)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        try await eventually(seconds: 20) { model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true }
        try #require(model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true, "the burst and the pair found")
        try await Task.sleep(for: .milliseconds(50))
        return (model, grid, strip, window)
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func url(_ model: EditorModel, _ name: String) throws -> URL {
        try #require(model.items.first { $0.url.lastPathComponent == name }?.url)
    }

    private func id(_ model: EditorModel, _ name: String) throws -> Int64 {
        try #require(model.library.photoID(of: url(model, name)))
    }

    private func selected(_ model: EditorModel) -> Set<String> {
        Set(model.selectedPhotos.map(\.lastPathComponent))
    }

    /// The photos with cells, by name, in the grid's order.
    private func cells(_ grid: LibraryGridView, _ model: EditorModel) -> [String] {
        (0 ..< grid.shownCount).compactMap { grid.row(ofItem: $0) }.map { model.items[$0].url.lastPathComponent }
    }

    private func strip(_ strip: FilmstripStripView) -> Int {
        strip.collectionView.numberOfItems(inSection: 0)
    }

    // MARK: - Showing stacks

    @Test func `each stack is one cell with its count in the grid and the filmstrip, opened and closed in place`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, filmstrip, window) = try await open()
        defer { window.contentView = nil }
        let burst = ["B01.JPG", "B02.JPG", "B03.JPG"]
        #expect(cells(grid, model) == ["B01.JPG", "P01.JPG", "S01.JPG", "S02.JPG", "S03.JPG", "S04.JPG"])
        #expect(strip(filmstrip) == 6, "the filmstrip shows the stacks closed too")
        let top = try id(model, "B01.JPG")
        let first = try #require(grid.cells.values.first { $0.item?.name == "B01.JPG" })
        #expect(first.stackBadges.count == .stackCount(3, open: false))
        let pair = try #require(grid.cells.values.first { $0.item?.name == "P01.JPG" })
        #expect(pair.stackBadges.pair == .pairText("+HEIC", open: false))
        let reloads = grid.reloads

        model.gridStacks.toggle(top)
        #expect(cells(grid, model) == burst + ["P01.JPG", "S01.JPG", "S02.JPG", "S03.JPG", "S04.JPG"])
        #expect(strip(filmstrip) == 8 && first.stackBadges.count == .stackCount(3, open: true))
        try model.gridStacks.toggle(id(model, "B03.JPG"))
        #expect(cells(grid, model).count == 6 && strip(filmstrip) == 6, "S from a frame closes its burst")
        try model.gridStacks.toggle(badgeOf: id(model, "P01.JPG"), pair: true)
        #expect(cells(grid, model).contains("P01.HEIC"), "a click on the pair's badge opens it")
        model.gridStacks.openAll()
        #expect(cells(grid, model).count == Self.photos.count && strip(filmstrip) == Self.photos.count)
        model.gridStacks.closeAll()
        #expect(cells(grid, model).count == 6 && strip(filmstrip) == 6)
        #expect(grid.reloads == reloads, "opening and closing moved the cells rather than reloading them")
    }

    @Test func `a closed stack's cell selects all its photos, for clicks, culling and the keys`() async throws {
        defer { cleanUp() }
        let (model, grid, _, window) = try await open()
        defer { window.contentView = nil }
        let burst: Set = ["B01.JPG", "B02.JPG", "B03.JPG"]
        try model.clickInGrid(url(model, "B01.JPG"))
        #expect(selected(model) == burst && model.selection?.lastPathComponent == "B01.JPG")
        try model.clickInGrid(url(model, "S01.JPG"), toggling: true)
        #expect(selected(model) == burst.union(["S01.JPG"]))
        try model.clickInGrid(url(model, "B01.JPG"), toggling: true)
        #expect(selected(model) == ["S01.JPG"], "⌘-click takes a closed stack away whole")
        try model.clickInGrid(url(model, "S02.JPG"), extending: true)
        #expect(selected(model) == ["S01.JPG", "S02.JPG"])
        try model.clickInGrid(url(model, "B01.JPG"))
        try model.clickInGrid(url(model, "S01.JPG"), extending: true)
        #expect(
            selected(model) == burst.union(["P01.JPG", "P01.HEIC", "S01.JPG"]),
            "⇧-click reaches the stacks between",
        )

        try model.clickInGrid(url(model, "P01.JPG"))
        model.cull(.flag(.pick))
        let flagged = Set(model.items.filter { $0.metadata.flag == .pick }.map(\.url.lastPathComponent))
        #expect(flagged == ["P01.JPG", "P01.HEIC"], "a pair's change reaches both files")

        // The active photo inside a closed stack gives way to its cell.
        try model.select(url(model, "B02.JPG"))
        model.coverClosedStacks()
        #expect(model.selection?.lastPathComponent == "B01.JPG" && selected(model) == burst)

        // ← and → go from cell to cell.
        #expect(model.perform(.nextPhoto) && model.selection?.lastPathComponent == "P01.JPG")
        #expect(model.perform(.nextPhoto) && model.selection?.lastPathComponent == "S01.JPG")
        #expect(model.perform(.previousPhoto) && model.perform(.previousPhoto))
        #expect(model.selection?.lastPathComponent == "B01.JPG" && selected(model) == burst)
        #expect(grid.shownCount == 6)
    }

    @Test func `grouped, each stack is closed in its group, and opens there as the filmstrip's does`() async throws {
        defer { cleanUp() }
        let (model, grid, filmstrip, window) = try await open()
        defer { window.contentView = nil }
        model.setGroupKey(.moment)
        try await eventually { model.gridGroups.list?.groups.key == .moment }
        let grouped = try #require(model.gridGroups.list)
        #expect(grouped.stacked.stacksShown == (0, 2), "the burst and the pair closed in their groups")
        #expect(grid.shownCount == grouped.groups.count + 6)
        let top = try id(model, "B01.JPG")
        model.gridStacks.toggle(top)
        #expect(model.gridGroups.list.map { $0.stacked.stacksShown == (1, 1) } == true && strip(filmstrip) == 8)
        #expect(grid.shownCount == grouped.groups.count + 8)
        #expect(try model.gridGroups.shownPhoto(1, from: top) == id(model, "B02.JPG"))
        model.gridStacks.closeAll()
        #expect(grid.shownCount == grouped.groups.count + 6 && strip(filmstrip) == 6)
        #expect(try model.gridGroups.shownPhoto(1, from: top) == id(model, "P01.JPG"), "→ passes a closed stack")
        model.setGroupKey(.ungrouped)
    }

    @Test func `⇧ and Auto Advance move from cell to cell as the grid shows them, grouped or not`() async throws {
        defer { cleanUp() }
        let (model, _, filmstrip, window) = try await open()
        defer { window.contentView = nil }
        let burst: Set = ["B01.JPG", "B02.JPG", "B03.JPG"]
        try model.clickInGrid(url(model, "B01.JPG"))
        #expect(model.perform(.rating3, shifted: true))
        #expect(model.selection?.lastPathComponent == "P01.JPG" && selected(model) == ["P01.JPG", "P01.HEIC"])
        #expect(model.items.filter { $0.metadata.rating == 3 }.count == 3, "the burst's three photos")

        model.setGroupKey(.folder)
        try await eventually { model.gridGroups.list?.groups.key == .folder }
        #expect(strip(filmstrip) == 6, "the filmstrip shows the group's cells, each stack one")
        try model.clickInGrid(url(model, "B01.JPG"))
        #expect(model.perform(.flagPick, shifted: true))
        #expect(model.selection?.lastPathComponent == "P01.JPG" && selected(model) == ["P01.JPG", "P01.HEIC"])
        #expect(Set(model.items.filter { $0.metadata.flag == .pick }.map(\.url.lastPathComponent)) == burst)
        try model.gridStacks.toggle(id(model, "B01.JPG"))
        #expect(strip(filmstrip) == 8)
        model.perform(.autoAdvance)
        try model.clickInGrid(url(model, "B01.JPG"))
        #expect(
            model.perform(.labelRed) && model.selection?.lastPathComponent == "B02.JPG",
            "an open stack's next frame",
        )
        model.perform(.autoAdvance)
        model.gridStacks.closeAll()
        model.setGroupKey(.ungrouped)
    }

    // MARK: - Changes

    @Test func `a filter's change in a list without stacks is no restack, and the filmstrip doesn't reload`(
    ) async throws {
        defer { cleanUp() }
        let (model, _, filmstrip, window) = try await open()
        defer { window.contentView = nil }
        let filters = try #require(model.libraryFilters)
        var restacks = 0
        let observation = model.gridStacks.observe { change in
            if change == .restacked {
                restacks += 1
            }
        }
        defer { observation.invalidate() }
        /// The filter's photos listed, and the stacking their change started done.
        func filter(_ text: String, count: Int) async throws {
            let made = model.gridStacks.stackingsMade
            filters.setText(text)
            try await eventually { model.items.count == count && model.gridStacks.stackingsMade > made }
            try await Task.sleep(for: .milliseconds(50))
            try #require(model.items.count == count && model.gridStacks.stackingsMade > made, "\(text)")
        }

        try await filter("date:2024-06-14T10:05..", count: 4)
        try await eventually { restacks > 0 }
        #expect(model.gridStacks.list == nil && strip(filmstrip) == 4 && restacks > 0, "the stacks filtered out")
        let (reloads, before) = (filmstrip.reloads, restacks)
        try await filter("date:2024-06-14T10:15..", count: 3)
        try await filter("date:2024-06-14T10:05..", count: 4)
        try await filter("date:2024-06-14T10:25..", count: 2)
        #expect(restacks == before, "no stacks before or after")
        #expect(filmstrip.reloads == reloads && strip(filmstrip) == 2, "the strip took the rows that came and went")
        #expect(model.gridStacks.outline.hasStacks == false)

        try await filter("", count: Self.photos.count)
        try await eventually { model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true }
        #expect(restacks == before + 1 && strip(filmstrip) == 6, "the burst and the pair back, closed")
        try await filter("-name:B02", count: Self.photos.count - 1)
        try await eventually { restacks == before + 2 }
        let top = try #require(model.gridStacks.list?.cell(for: id(model, "B01.JPG")))
        #expect(model.gridStacks.list?.badges(of: top).stack?.count == 2, "the burst's two frames left")
        #expect(restacks == before + 2 && strip(filmstrip) == 6)
    }

    @Test func `stacking, unstacking and a stack's top are changes Undo takes back, the grid following`() async throws {
        defer { cleanUp() }
        let (model, grid, _, window) = try await open()
        defer { window.contentView = nil }
        let (first, second) = try (id(model, "S01.JPG"), id(model, "S02.JPG"))
        func top() -> Int64? {
            model.gridStacks.list?.stacks.stack(containing: first)?.top
        }
        try model.clickInGrid(url(model, "S01.JPG"))
        try model.clickInGrid(url(model, "S02.JPG"), toggling: true)
        #expect(model.canPerform(.stackPhotos) && !model.canPerform(.unstackPhotos))
        #expect(model.perform(.stackPhotos))
        try await eventually(seconds: 20) { top() == second }
        #expect(top() == second, "the active photo is on top")
        #expect(model.gridStacks.list.map { $0.stacksShown == (0, 3) } == true && grid.shownCount == 5)

        model.gridStacks.toggle(second)
        try model.clickInGrid(url(model, "S01.JPG"))
        #expect(model.canPerform(.moveToStackTop))
        #expect(model.perform(.moveToStackTop))
        try await eventually(seconds: 20) { top() == first }
        #expect(top() == first)

        #expect(model.perform(.unstackPhotos))
        try await eventually(seconds: 20) { top() == nil }
        #expect(top() == nil && model.gridStacks.list.map { $0.stacksShown == (0, 2) } == true)

        #expect(model.perform(.undo))
        try await eventually(seconds: 20) { top() == first }
        #expect(top() == first, "⌘Z stacks them again")
        #expect(model.canPerform(.redo))
        #expect(model.perform(.redo))
        try await eventually(seconds: 20) { top() == nil }
        #expect(top() == nil, "⇧⌘Z takes them apart again")
        #expect(model.perform(.undo))
        try await eventually(seconds: 20) { top() == first }
        #expect(model.perform(.undo))
        try await eventually(seconds: 20) { top() == second }
        #expect(model.perform(.undo))
        try await eventually(seconds: 20) { top() == nil }
        #expect(top() == nil && grid.shownCount == 6)
        await model.libraryPanels.written()
    }
}
