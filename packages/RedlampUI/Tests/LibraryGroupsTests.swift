import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Group By in the Library grid (LIB-41), over a folder the library has indexed: each key's groups, counts and
/// picks as the library makes them, each a header in the grid; groups opened and closed with the selection and
/// the active photo kept and the grid's cells moved rather than reloaded; ← and → past closed groups; and Group By
/// kept with each source.
@MainActor
struct LibraryGroupsTests {
    /// A photo of the folder: when it was taken, seconds after 10:00 on 14 June 2024 by the camera's clock (nil
    /// for none), its camera and its size, and whether it's a pick.
    struct Photo {
        var path: String
        var time: Double?
        var canon = false
        var width = 64
        var height = 48
        var pick = false
    }

    /// Moments at the default setting: A01 to A06 (a pause of 30 s after A03, which only the tightest splits),
    /// 100 s before B01 to B03 (which the loosest doesn't split), 400 s before C01 and C02, the next day's D01
    /// and D02, and a scan without a capture time. A03 and B03 are portrait, A06 square.
    static let photos = [
        Photo(path: "A01.JPG", time: 0, pick: true), Photo(path: "A02.JPG", time: 10),
        Photo(path: "A03.JPG", time: 20, width: 48, height: 64), Photo(path: "A04.JPG", time: 50),
        Photo(path: "A05.JPG", time: 60), Photo(path: "A06.JPG", time: 70, width: 48, height: 48),
        Photo(path: "B01.JPG", time: 170, canon: true), Photo(path: "B02.JPG", time: 180, canon: true),
        Photo(path: "B03.JPG", time: 190, canon: true, width: 48, height: 64),
        Photo(path: "C01.JPG", time: 590), Photo(path: "C02.JPG", time: 600),
        Photo(path: "D01.JPG", time: 82800, canon: true, pick: true), Photo(path: "D02.JPG", time: 82810, canon: true),
        Photo(path: "SCAN.PNG"),
        Photo(path: "Below/E01.JPG", time: 165_600),
    ]

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "library-groups-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "library-groups-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func write(_ photo: Photo) throws {
        let url = root.appending(path: photo.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        let data = NSMutableData()
        let type = photo.path.hasSuffix(".PNG") ? UTType.png : UTType.jpeg
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let time = photo.time {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let ten = try #require(calendar.date(from: DateComponents(year: 2024, month: 6, day: 14, hour: 10)))
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: ten.addingTimeInterval(time),
            )
            let text = String(
                format: "%04d:%02d:%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            )
            properties[kCGImagePropertyTIFFDictionary] = photo.canon
                ? [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"]
                : [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: text,
                kCGImagePropertyExifLensModel: photo.canon ? "RF24-70mm F2.8 L IS USM" : "XF35mmF1.4 R",
            ]
        }
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        if photo.pick {
            try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(flag: .pick)), for: url)
        }
    }

    /// The folder indexed, open in an editor from the library, with its grid shown in a window, which the test
    /// keeps until it ends.
    private func open() async throws -> (EditorModel, LibraryGridView, NSWindow) {
        for photo in Self.photos {
            try write(photo)
        }
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars, defaults: defaults,
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
        try await eventually(seconds: 20) { library.isShownFromLibrary && !library.isListing && library.count == 14 }
        try #require(library.isShownFromLibrary && library.count == 14)
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 1400), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        let grid = LibraryGridView(model: model)
        window.contentView = grid
        grid.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        return (model, grid, window)
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Groups the grid by `key` and waits for the groups.
    private func group(_ model: EditorModel, by key: GroupKey) async throws {
        model.setGroupKey(key)
        try await eventually {
            key == .ungrouped ? model.gridGroups.list == nil : model.gridGroups.list?.groups.key == key
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func url(_ model: EditorModel, _ name: String) throws -> URL {
        try #require(model.items.first { $0.url.lastPathComponent == name }?.url)
    }

    private func id(_ model: EditorModel, _ name: String) throws -> Int64 {
        try #require(model.library.photoID(of: url(model, name)))
    }

    private func names(_ model: EditorModel, _ ids: some Sequence<Int64>) -> [String] {
        ids.compactMap(model.library.url(ofPhoto:)).map(\.lastPathComponent)
    }

    /// Each group's photos by name, as the grid has them.
    private func groupNames(_ model: EditorModel) -> [[String]] {
        model.gridGroups.list.map { list in list.groups.map { names(model, $0.photos) } } ?? []
    }

    private func selected(_ model: EditorModel) -> Set<String> {
        Set(model.selectedPhotos.map(\.lastPathComponent))
    }

    // MARK: - Group By

    @Test func `each Group By gives the library's groups, their counts and picks, each a header in the grid`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, window) = try await open()
        defer { window.contentView = nil }
        let core = try #require(model.library.service?.core)
        let urls = model.items.map(\.url)
        let indexIDs = await LibraryService.indexIDs(of: urls, in: core.index)
        let list = PhotoList(
            source: model.library.photoList.source,
            ids: ContiguousArray(urls.compactMap { indexIDs[$0] }),
        )
        try #require(list.count == 14)
        let grouping = try await core.engine.grouping()
        for key in GroupKey.allCases where key != .ungrouped {
            try await group(model, by: key)
            let library = grouping.groups(of: list, by: key)
            let shown = try #require(model.gridGroups.list)
            #expect(shown.groups.map(\.name) == library.map(\.name), "\(key)")
            #expect(shown.groups.map(\.count) == library.map(\.count), "\(key)")
            #expect(model.gridGroups.picks == library.map(\.picks), "\(key)")
            #expect(shown.groups.map(\.value) == library.map(\.value), "\(key)")
            #expect(grid.shownCount == 14 + library.count, "\(key): a header for each group, then its photos")
            let headers = grid.headers.values.sorted { $0.group < $1.group }
            #expect(!headers.isEmpty && headers.allSatisfy { $0.title == library[$0.group].name }, "\(key)")
            #expect(headers.allSatisfy { header in
                let frame = grid.gridLayout.frame(forItem: shown.index(ofHeader: header.group))
                return frame.width > grid.gridLayout.cellSize.width * 2 && frame.height == LibraryGridLayout
                    .headerHeight
            }, "\(key): each header is across the grid")
        }
        try await group(model, by: .camera)
        #expect(model.gridGroups.list?.groups.last?.name == "No camera")
        #expect(groupNames(model).map(\.count) == [5, 8, 1] && model.gridGroups.picks == [1, 1, 0])
        let layout = grid.gridLayout
        let firstCell = layout.frame(forItem: 1)
        let header = layout.frame(forItem: 0)
        #expect(
            firstCell.minY >= header.maxY && firstCell.minX == layout.left,
            "a group's cells start below its header",
        )
        let secondHeader = layout.frame(forItem: 6)
        #expect(secondHeader.minY > layout.frame(forItem: 5).maxY, "the next group's header has a row of its own")

        try await group(model, by: .ungrouped)
        #expect(grid.shownCount == 14 && grid.headers.isEmpty && grid.sections == nil)
    }

    // MARK: - Opening and closing

    @Test func `opening and closing groups keeps the selection and the active photo, moving the grid's cells`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .moment)
        #expect(groupNames(model) == [
            ["A01.JPG", "A02.JPG", "A03.JPG", "A04.JPG", "A05.JPG", "A06.JPG"], ["B01.JPG", "B02.JPG", "B03.JPG"],
            ["C01.JPG", "C02.JPG"], ["D01.JPG", "D02.JPG"], ["SCAN.PNG"],
        ])
        try model.select(url(model, "C01.JPG"))
        try model.click(url(model, "A02.JPG"), toggling: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(selected(model) == ["A02.JPG", "C01.JPG"] && model.selection?.lastPathComponent == "A02.JPG")
        let reloads = grid.reloads
        // C01 is item 12: the first header, A's six, B's header and three, and C's header.
        let c01 = try id(model, "C01.JPG")
        #expect(model.gridGroups.list?.index(of: c01) == 12)
        let cell = try #require(grid.cells[12])
        #expect(cell.item?.url.lastPathComponent == "C01.JPG")

        model.toggleGroup(1)
        #expect(model.gridGroups.isOpen(1) == false && grid.shownCount == 14 + 5 - 3)
        #expect(selected(model) == ["A02.JPG", "C01.JPG"] && model.selection?.lastPathComponent == "A02.JPG")
        #expect(grid.reloads == reloads, "closing a group moves the cells that stay")
        #expect(model.gridGroups.list?.index(of: c01) == 9 && grid.cells[9] === cell, "C01's cell moved up")
        #expect(grid.cells[9]?.item?.url.lastPathComponent == "C01.JPG")

        model.toggleGroup(1)
        #expect(model.gridGroups.isOpen(1) && grid.shownCount == 19 && grid.reloads == reloads)
        #expect(selected(model) == ["A02.JPG", "C01.JPG"] && model.selection?.lastPathComponent == "A02.JPG")

        // Closing the active photo's group: its photos leave the selection, the selected photo after it is active.
        model.toggleGroup(0)
        #expect(selected(model) == ["C01.JPG"] && model.selection?.lastPathComponent == "C01.JPG")
        #expect(try !(model.gridGroups.list?.isVisible(id(model, "A02.JPG")) ?? true))
        // With nothing else selected, the photo on show after the group, alone.
        model.toggleGroup(0)
        model.toggleGroup(2)
        #expect(selected(model) == ["D01.JPG"] && model.selection?.lastPathComponent == "D01.JPG")

        // ⌥-click on a header: every group closed, nothing selected, the active photo kept for when it's back.
        model.toggleGroup(4, all: true)
        #expect(model.gridGroups.list.map { list in list.groups.indices.allSatisfy { !list.isOpen($0) } } == true)
        #expect(model.photoSelection.isEmpty && model.selection?.lastPathComponent == "D01.JPG")
        #expect(grid.shownCount == 5 && grid.headers.count == 5 && grid.cells.isEmpty && grid.reloads == reloads)
        #expect(!model.canPerform(.flagPick) && !model.perform(.flagPick), "nothing out of sight is culled")
        #expect(model.canPerform(.openAllGroups) && !model.canPerform(.closeAllGroups))
        model.perform(.openAllGroups)
        #expect(grid.shownCount == 19 && grid.reloads == reloads)
        #expect(model.selection?.lastPathComponent == "D01.JPG")

        // A photo of a closed group made active elsewhere (the filmstrip) opens its group.
        model.toggleGroup(1)
        try model.select(url(model, "B02.JPG"))
        try await eventually { model.gridGroups.isOpen(1) }
        #expect(model.gridGroups.isOpen(1))
    }

    @Test func `the arrow keys and the filmstrip's steps go through the photos on show in the grid's order`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .camera)
        let canon = ["B01.JPG", "B02.JPG", "B03.JPG", "D01.JPG", "D02.JPG"]
        #expect(groupNames(model).first == canon)
        try model.select(url(model, "B03.JPG"))
        model.perform(.nextPhoto)
        #expect(model.selection?.lastPathComponent == "D01.JPG", "→ in the group's order")
        try model.select(url(model, "D02.JPG"))
        model.perform(.nextPhoto)
        #expect(model.selection?.lastPathComponent == "A01.JPG", "→ into the next group")
        model.perform(.previousPhoto)
        #expect(model.selection?.lastPathComponent == "D02.JPG")
        model.gridGroups.close(1)
        model.perform(.nextPhoto)
        #expect(model.selection?.lastPathComponent == "SCAN.PNG", "→ passes over a closed group's photos")
        #expect(!model.canPerform(.nextPhoto))
        model.gridGroups.open(1)

        // ⇧-click in the grid's order: D02 to A02 across the groups' boundary.
        try model.select(url(model, "D02.JPG"))
        try model.clickInGrid(url(model, "A02.JPG"), extending: true)
        #expect(selected(model) == ["D02.JPG", "A01.JPG", "A02.JPG"])

        // ↓ from the first group's last row goes into the next group's first.
        let columns = grid.gridLayout.columns
        try #require(columns >= 3)
        try model.select(url(model, "D02.JPG"))
        try await Task.sleep(for: .milliseconds(30))
        try press(grid, kVK_DownArrow)
        let below = groupNames(model)[1][min(4 % columns, 7)]
        #expect(model.selection?.lastPathComponent == below)
        try press(grid, kVK_UpArrow)
        #expect(model.selection?.lastPathComponent == "D02.JPG")
        try press(grid, kVK_End)
        #expect(model.selection?.lastPathComponent == "SCAN.PNG")
        try press(grid, kVK_Home)
        #expect(model.selection?.lastPathComponent == "B01.JPG")
    }

    private func press(_ grid: LibraryGridView, _ code: Int, shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function], timestamp: 0,
            windowNumber: grid.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code),
        ))
        grid.content.keyDown(with: event)
    }

    // MARK: - Each source's view

    @Test func `Group By is kept with each source's view, and across launches`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .camera)
        model.setIncludesSubfolders(true)
        try await eventually(seconds: 20) { model.library.count == 15 && model.library.isShownFromLibrary }
        try await group(model, by: .folder)
        #expect(model.gridGroups.list?.groups.count == 2, "the folder and its subfolder")
        model.setIncludesSubfolders(false)
        try await eventually(seconds: 20) { model.library.count == 14 && model.libraryViews.groupKey == .camera }
        try await eventually { model.gridGroups.list?.groups.key == .camera }
        #expect(model.gridGroups.list?.groups.key == .camera)
        model.setIncludesSubfolders(true)
        try await eventually(seconds: 20) { model.libraryViews.groupKey == .folder }
        #expect(model.libraryViews.groupKey == .folder)

        let state = LibraryViewState(defaults: defaults)
        state.setGroupKey(.lens)
        state.remember("/Somewhere", selection: [], active: nil)
        let again = LibraryViewState(defaults: defaults)
        #expect(again.groupKey == .lens)
        again.setGroupKey(.day)
        #expect(again.restore("/Somewhere")?.group == .lens && again.groupKey == .lens)
    }
}
