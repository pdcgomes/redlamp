import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Synchronization
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Group By in the Library grid (LIB-41), over a folder the library has indexed: each key's groups, counts and
/// picks as the library makes them, each a header in the grid; groups opened and closed with the selection and
/// the active photo kept and the grid's cells moved rather than reloaded; ⌥← and ⌥→, and ← and → past closed
/// groups; moments' Tighter–Looser setting; Group By and the setting kept with each source; the moments without a
/// pick; and the filter bar's orientation column and completions.
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
        // The folder's own 14 photos: Below's E01 is a source of its own here.
        library.setIncludesSubfolders(false)
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

    /// Groups the grid by `key` at `looseness` and waits for the groups.
    private func group(_ model: EditorModel, by key: GroupKey, looseness: Int = 0) async throws {
        model.setLooseness(looseness)
        model.setGroupKey(key)
        try await eventually {
            key == .ungrouped ? model.gridGroups.list == nil
                : model.gridGroups.list?.groups.key == key
                && model.gridGroups.list?.groups.setting == MomentSetting(looseness: looseness)
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

    /// A filmstrip below the grid in its window, as the editor docks it.
    private func filmstrip(
        _ model: EditorModel,
        below grid: LibraryGridView,
        in window: NSWindow,
    ) -> FilmstripStripView {
        let strip = FilmstripStripView(model: model)
        let content = NSView(frame: CGRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = content
        grid.frame = CGRect(
            x: 0, y: FilmstripStripView.height, width: content.bounds.width,
            height: content.bounds.height - FilmstripStripView.height,
        )
        strip.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: FilmstripStripView.height)
        content.addSubview(grid)
        content.addSubview(strip)
        content.layoutSubtreeIfNeeded()
        return strip
    }

    /// The filmstrip's photos by name, in its order.
    private func stripNames(_ strip: FilmstripStripView, _ model: EditorModel) -> [String] {
        (0 ..< strip.collectionView.numberOfItems(inSection: 0)).compactMap(strip.row(ofItem:))
            .map { model.items[$0].url.lastPathComponent }
    }

    @Test func `the filmstrip shows the grid's photos in its order, a closed group's left out, and clicks there follow it`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, window) = try await open()
        defer { window.contentView = nil }
        let strip = filmstrip(model, below: grid, in: window)
        let listed = model.items.map(\.url.lastPathComponent)
        #expect(stripNames(strip, model) == listed, "ungrouped, the list's order")
        try await group(model, by: .camera)
        let byCamera = groupNames(model)
        // A new order reaches the strip a turn after the grid.
        try await eventually { stripNames(strip, model) == byCamera.flatMap(\.self) }
        #expect(stripNames(strip, model) == byCamera.flatMap(\.self))
        model.gridGroups.close(1)
        #expect(stripNames(strip, model) == byCamera[0] + byCamera[2], "a closed group's photos left out")
        model.closeAllGroups()
        #expect(stripNames(strip, model).isEmpty)
        model.openAllGroups()
        #expect(stripNames(strip, model) == byCamera.flatMap(\.self))

        // ⇧-click in the filmstrip selects in the grid's order, across the groups' boundary.
        try model.select(url(model, "D02.JPG"))
        try await Task.sleep(for: .milliseconds(30))
        let place = try #require(stripNames(strip, model).firstIndex(of: "A02.JPG"))
        strip.collectionView.layoutSubtreeIfNeeded()
        let item = try #require(strip.collectionView.item(at: IndexPath(item: place, section: 0)) as? FilmstripItem)
        item.cell.onClick?([.shift])
        #expect(selected(model) == ["D02.JPG", "A01.JPG", "A02.JPG"])

        try await group(model, by: .moment, looseness: MomentSetting.tightest)
        try await eventually { stripNames(strip, model) == groupNames(model).flatMap(\.self) }
        #expect(stripNames(strip, model) == groupNames(model).flatMap(\.self))
        try await group(model, by: .ungrouped)
        try await eventually { stripNames(strip, model) == listed }
        #expect(stripNames(strip, model) == listed)
    }

    @Test func `⇧ and Auto Advance move on in the grid's order, past closed groups, in Library, the loupe and Develop`(
    ) async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .camera)
        // Canon's B01 to B03, D01 and D02; the Fujifilm's A01 to A06, C01 and C02; the scan.
        try model.select(url(model, "B03.JPG"))
        #expect(model.perform(.rating2, shifted: true))
        #expect(model.selection?.lastPathComponent == "D01.JPG", "⇧ moves on in the group's order, not the list's")
        #expect(model.items.first { $0.name == "B03.JPG" }?.metadata.rating == 2)
        try model.select(url(model, "D02.JPG"))
        try model.click(url(model, "D01.JPG"), toggling: true)
        #expect(model.perform(.flagPick, shifted: true))
        #expect(
            model.selection?.lastPathComponent == "A01.JPG",
            "after the last of the photos culled, in the next group",
        )
        model.gridGroups.close(1)
        try model.select(url(model, "D02.JPG"))
        #expect(model.perform(.rating1, shifted: true) && model.selection?.lastPathComponent == "SCAN.PNG")
        model.gridGroups.open(1)

        #expect(model.perform(.autoAdvance) && model.autoAdvance)
        try model.select(url(model, "A06.JPG"))
        #expect(model.perform(.labelGreen) && model.selection?.lastPathComponent == "C01.JPG")
        model.showLibrary(.loupe)
        let right = try #require(ShortcutAction.resolve(KeyCombo(.right), in: .library)?.action)
        let left = try #require(ShortcutAction.resolve(KeyCombo(.left), in: .library)?.action)
        #expect(
            model.perform(left) && model.selection?.lastPathComponent == "A06.JPG",
            "the loupe's ← in the grid's order",
        )
        #expect(model.perform(right) && model.perform(right) && model.selection?.lastPathComponent == "C02.JPG")
        #expect(model.perform(.toggleMark) && model.selection?.lastPathComponent == "SCAN.PNG")
        try model.select(url(model, "D02.JPG"))
        model.showModule(.develop)
        #expect(model.perform(.rating4) && model.selection?.lastPathComponent == "A01.JPG", "Develop moves on so too")
        #expect(model.perform(.autoAdvance) && !model.autoAdvance)

        // Develop reads ahead the photos ← and → go to.
        let ahead = try model.workingSet(around: url(model, "D01.JPG"), comingFrom: url(model, "B03.JPG"))
        #expect(ahead.map(\.lastPathComponent) == ["D01.JPG", "D02.JPG", "B03.JPG", "A01.JPG"])
    }

    private func press(_ grid: LibraryGridView, _ code: Int, shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function], timestamp: 0,
            windowNumber: grid.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code),
        ))
        grid.content.keyDown(with: event)
    }

    @Test func `Option-Left and Option-Right go to the first photo of the group before and after, opening it`(
    ) async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .moment)
        try model.select(url(model, "A04.JPG"))
        #expect(model.canPerform(.nextGroup) && !model.canPerform(.previousGroup))
        #expect(model.perform(.nextGroup) && model.selection?.lastPathComponent == "B01.JPG")
        #expect(model.perform(.nextGroup) && model.selection?.lastPathComponent == "C01.JPG")
        model.gridGroups.close(3)
        #expect(model.perform(.nextGroup) && model.selection?.lastPathComponent == "D01.JPG")
        #expect(model.gridGroups.isOpen(3), "⌥→ opens the group it goes to")
        #expect(model.perform(.previousGroup) && model.selection?.lastPathComponent == "C01.JPG")
        model.perform(.nextGroup)
        model.perform(.nextGroup)
        #expect(model.selection?.lastPathComponent == "SCAN.PNG" && !model.canPerform(.nextGroup))
        #expect(!model.perform(.nextGroup))
        #expect(ShortcutAction.resolve(KeyCombo(.right, option: true), in: .library)?.action == .nextGroup)
        #expect(ShortcutAction.resolve(KeyCombo(.left, option: true), in: .develop)?.action == .previousGroup)

        try await group(model, by: .ungrouped)
        #expect(!model.canPerform(.nextGroup) && !model.perform(.previousGroup))
    }

    @Test func `a click on a photo in the grouped grid selects that photo, wherever the grid is scrolled`(
    ) async throws {
        defer { cleanUp() }
        let (model, grid, window) = try await open()
        defer { window.contentView = nil }
        window.setContentSize(CGSize(width: 900, height: 300))
        grid.layoutSubtreeIfNeeded()
        try await group(model, by: .camera)
        let firsts = (model.gridGroups.list?.groups.compactMap(\.photos.first) ?? [])
            .compactMap(model.library.url(ofPhoto:)).map(\.lastPathComponent)
        try #require(firsts.count >= 3)
        try model.select(url(model, firsts[firsts.count - 1]))
        try await Task.sleep(for: .milliseconds(100))
        grid.layoutSubtreeIfNeeded()
        let onScreen = elements(grid).filter { element in
            guard let id = element.accessibilityIdentifier(), !id.hasPrefix("grid.group.") else { return false }
            let frame = window.convertFromScreen(element.accessibilityFrame())
            return window.contentView?.hitTest(CGPoint(x: frame.midX, y: frame.midY)) is LibraryGridContentView
        }
        .compactMap { $0.accessibilityIdentifier().map { String($0.dropFirst("grid.".count)) } }
        try #require(onScreen.count > 2)
        for name in onScreen {
            try click(grid, name)
            #expect(selected(model) == [name], "a click on \(name) selected \(selected(model))")
        }
    }

    private func elements(_ grid: LibraryGridView) -> [NSAccessibilityElement] {
        func views(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        let content = views(grid).first { $0.accessibilityIdentifier() == "library.grid" }
        return (content?.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    /// A click on the grid's element for photo `name`, at its middle, as the regression suite's driver makes it.
    private func click(_ grid: LibraryGridView, _ name: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try #require(grid.window)
        let element = try #require(elements(grid).first { $0.accessibilityIdentifier() == "grid.\(name)" })
        let frame = window.convertFromScreen(element.accessibilityFrame())
        let location = NSPoint(x: frame.midX, y: frame.midY)
        let root: NSView = window.contentView?.superview ?? grid
        let view = try #require(root.hitTest(location))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }

    @Test func `the menus are told as a grouping lands, and as the first group closes or the last opens`(
    ) async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try model.select(url(model, "A04.JPG"))
        let told = Mutex(false)
        let watch = {
            told.withLock { $0 = false }
            withObservationTracking {
                _ = [ShortcutAction.toggleGroup, .openAllGroups, .closeAllGroups].map(model.canPerform)
            } onChange: {
                told.withLock { $0 = true }
            }
        }
        watch()
        model.setGroupKey(.moment)
        try await eventually { model.gridGroups.list?.groups.key == .moment }
        #expect(told.withLock { $0 }, "the grouping landed")
        #expect(model.canPerform(.toggleGroup) && model.canPerform(.closeAllGroups))
        #expect(!model.canPerform(.openAllGroups))

        watch()
        model.gridGroups.close(1)
        #expect(told.withLock { $0 }, "the first group closed")
        #expect(model.canPerform(.openAllGroups))
        watch()
        model.gridGroups.close(2)
        #expect(!told.withLock { $0 }, "another closed, others still open")
        model.openAllGroups()
        #expect(told.withLock { $0 }, "the last opened")
        #expect(!model.canPerform(.openAllGroups))
    }

    @Test func `a new grouping tells the menus only when their checks find something else in it`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .day)
        try model.select(url(model, "A04.JPG"))
        try await Task.sleep(for: .milliseconds(30))
        let told = Mutex(false)
        let watch = {
            told.withLock { $0 = false }
            withObservationTracking {
                _ = [ShortcutAction.previousGroup, .nextGroup, .previousPhoto, .nextPhoto, .toggleGroup]
                    .map(model.canPerform)
            } onChange: {
                told.withLock { $0 = true }
            }
        }
        #expect(!model.canPerform(.previousGroup) && model.canPerform(.nextGroup))

        // A04 is in the first group by day and by moment, between A03 and A05: the menus find the same.
        model.setGroupKey(.moment)
        watch()
        try await eventually { model.gridGroups.list?.groups.key == .moment }
        #expect(!told.withLock { $0 }, "the same checks in the moments")
        #expect(!model.canPerform(.previousGroup) && model.canPerform(.nextGroup))

        // The tightest moments split A03 from A04, whose moment is then the second.
        model.setLooseness(MomentSetting.tightest)
        watch()
        try await eventually {
            model.gridGroups.list?.groups.setting == MomentSetting(looseness: MomentSetting.tightest)
        }
        #expect(told.withLock { $0 }, "a group before A04's")
        #expect(model.canPerform(.previousGroup))
    }

    // MARK: - Moments' setting and each source's view

    @Test func `the Tighter–Looser setting finds moments again as it moves, and each source keeps it`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .moment)
        #expect(model.gridGroups.list?.groups.count == 5)
        try await group(model, by: .moment, looseness: MomentSetting.tightest)
        #expect(groupNames(model).prefix(2) == [["A01.JPG", "A02.JPG", "A03.JPG"], ["A04.JPG", "A05.JPG", "A06.JPG"]])
        #expect(!model.canPerform(.tighterMoments) && model.canPerform(.looserMoments))
        try await group(model, by: .moment, looseness: MomentSetting.loosest)
        #expect(groupNames(model).first?.count == 9, "the loosest setting joins A and B")
        #expect(model.perform(.tighterMoments) && model.libraryViews.looseness == 3)
        try await eventually { model.gridGroups.list?.groups.setting == MomentSetting(looseness: 3) }
        #expect(model.gridGroups.list?.groups.setting == MomentSetting(looseness: 3))

        // The folder with its subfolders is another source, with a setting of its own.
        model.setIncludesSubfolders(true)
        try await eventually(seconds: 20) { model.library.count == 15 && model.library.isShownFromLibrary }
        try await group(model, by: .moment, looseness: -2)
        model.setIncludesSubfolders(false)
        try await eventually(seconds: 20) { model.library.count == 14 && model.libraryViews.looseness == 3 }
        #expect(model.libraryViews.looseness == 3 && model.libraryViews.groupKey == .moment)
        model.setIncludesSubfolders(true)
        try await eventually(seconds: 20) { model.library.count == 15 && model.libraryViews.looseness == -2 }
        #expect(model.libraryViews.looseness == -2)
    }

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
        state.setLooseness(9)
        state.remember("/Somewhere", selection: [], active: nil)
        let again = LibraryViewState(defaults: defaults)
        #expect(again.groupKey == .lens && again.looseness == MomentSetting.loosest)
        again.setGroupKey(.day)
        #expect(again.restore("/Somewhere")?.group == .lens && again.groupKey == .lens)
    }

    @Test func `the moments without a pick are counted, and shown alone`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        try await group(model, by: .moment)
        #expect(model.gridGroups.coverage == LibraryGroups.Coverage(unpicked: 3, moments: 5))
        #expect(model.canPerform(.unpickedMoments) && model.perform(.unpickedMoments))
        #expect(model.gridGroups.showsUnpicked)
        #expect(model.gridGroups.list.map { list in list.groups.indices.filter(list.isOpen) } == [1, 2, 4])
        try model.select(url(model, "B01.JPG"))
        model.cull(.flag(.pick))
        try await eventually { model.gridGroups.coverage?.unpicked == 2 }
        #expect(model.gridGroups.coverage == LibraryGroups.Coverage(unpicked: 2, moments: 5))
        #expect(model.gridGroups.picks[1] == 1)
        model.perform(.unpickedMoments)
        #expect(!model.gridGroups.showsUnpicked && model.gridGroups.list.map { list in
            list.groups.indices.allSatisfy(list.isOpen)
        } == true)
        try await group(model, by: .camera)
        #expect(model.gridGroups.coverage == nil && !model.canPerform(.unpickedMoments))
    }

    // MARK: - Orientation in the filter bar

    @Test func `the filter bar has an orientation column and completes orientations with their titles`() async throws {
        defer { cleanUp() }
        let (model, _, window) = try await open()
        defer { window.contentView = nil }
        let filters = try #require(model.libraryFilters)
        #expect(FacetColumn.orientation.title == "Orientation")
        filters.setBarShown(true)
        filters.setFilter(LibraryFilter(sections: [.metadata], columns: [.orientation]))
        filters.countColumns()
        try await eventually { filters.columns[0]?.column == .orientation }
        let counts = try #require(filters.columns[0])
        let rows = FilterColumnRow.rows(counts, folder: nil)
        #expect(rows.map(\.title) == ["Landscape", "Portrait", "Square"])
        #expect(rows.map(\.count) == [11, 2, 1])
        try filters.choose([#require(rows[1].value)], inColumn: 0)
        try await eventually { model.items.count == 2 }
        #expect(filters.filter.text == "orientation:portrait")
        #expect(Set(model.items.map(\.name)) == ["A03.JPG", "B03.JPG"])

        let completion = FilterCompletion(QueryCompletion(field: .orientation, value: "portrait"))
        #expect(completion.title == "Portrait" && completion.kind == "Orientation")
        #expect(completion.text == "orientation:portrait ")
        filters.clear()
    }
}
