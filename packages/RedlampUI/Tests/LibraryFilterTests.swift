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

/// The Library filter bar (LIB-18) over a folder the library has indexed: text, attributes and
/// columns finding photos, columns narrowing each other, the text and the rules as one query, sorts,
/// saved filters, each source's filter and the lock, missing and offline photos, typing that never
/// waits, and the selection kept through filtering.
@MainActor
struct LibraryFilterTests {
    /// A photo of the folder: its camera and settings in its EXIF, its badges in its sidecar.
    struct Photo {
        var path: String
        var make: String?
        var model: String?
        var iso: Int?
        var date: String?
        var rating = 0
        var flag: PhotoFlag?
        var label: ColorLabel?
        var edited = false
    }

    static let photos = [
        Photo(
            path: "IMG_0001.JPG",
            make: "FUJIFILM",
            model: "X-T5",
            iso: 200,
            date: "2024:06:14 10:00:00",
            rating: 5,
            flag: .pick,
            label: .red,
        ),
        Photo(
            path: "IMG_0002.JPG",
            make: "FUJIFILM",
            model: "X-T5",
            iso: 800,
            date: "2024:06:15 11:00:00",
            rating: 3,
            label: .blue,
            edited: true,
        ),
        Photo(
            path: "IMG_0003.JPG",
            make: "Canon",
            model: "Canon EOS R5",
            iso: 100,
            date: "2023:01:02 09:00:00",
            flag: .reject,
        ),
        Photo(path: "IMG_0004.PNG", rating: 1),
        Photo(
            path: "DSC_0005.JPG",
            make: "Canon",
            model: "Canon EOS R5",
            iso: 3200,
            date: "2024:07:01 08:00:00",
            rating: 4,
            edited: true,
        ),
        Photo(
            path: "Below/IMG_0006.JPG",
            make: "FUJIFILM",
            model: "X-T5",
            iso: 400,
            date: "2022:03:04 12:00:00",
            rating: 2,
        ),
    ]

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "library-filter-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "library-filter-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private var paths: LibraryPaths {
        LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func write(_ photo: Photo, shade: Int) throws {
        let url = root.appending(path: photo.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64 + shade * 8, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: CGFloat(shade % 7) / 7, green: CGFloat(shade % 5) / 5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64 + shade * 8, height: 48))
        let data = NSMutableData()
        let type = photo.path.hasSuffix(".PNG") ? UTType.png : UTType.jpeg
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var tiff: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        if let make = photo.make, let model = photo.model {
            tiff = [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model]
        }
        if let iso = photo.iso {
            exif[kCGImagePropertyExifISOSpeedRatings] = [iso]
        }
        if let date = photo.date {
            exif[kCGImagePropertyExifDateTimeOriginal] = date
        }
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        if photo.rating > 0 || photo.flag != nil || photo.label != nil || photo.edited {
            var recipe = EditRecipe()
            if photo.edited {
                recipe[.exposure] = 1
            }
            try SidecarStore().save(
                Sidecar(
                    recipe: recipe,
                    metadata: PhotoMetadata(rating: photo.rating, flag: photo.flag, label: photo.label),
                ),
                for: url,
            )
        }
    }

    /// The folder indexed, open in an editor from the library, its subfolders shown when `subfolders`.
    private func open(subfolders: Bool = false) async throws -> (EditorModel, LibraryService) {
        for (shade, photo) in Self.photos.enumerated() {
            try write(photo, shade: shade)
        }
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
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
        library.setIncludesSubfolders(subfolders)
        model.open([root])
        try await eventually(seconds: 20) { library.isShownFromLibrary && !library.isListing && library.count > 0 }
        try #require(library.isShownFromLibrary)
        return (model, service)
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func names(_ model: EditorModel) -> [String] {
        model.items.map(\.name)
    }

    /// Waits until the library has listed the photos `text` finds.
    private func filtered(_ model: EditorModel, _ text: String) async throws {
        let filters = try #require(model.libraryFilters)
        filters.setText(text)
        try await listed(model)
    }

    /// Waits until the library has listed the photos of the filter and sort the bar has now.
    private func listed(_ model: EditorModel) async throws {
        let filters = try #require(model.libraryFilters)
        let query = filters.filter.query
        let sort = filters.sort
        let wanted = LibraryListFilterSummary(
            query: query, sort: sort.query, reversed: sort.field == .folder && !sort.ascending,
        )
        try await eventually { filters.lastListed == wanted }
        #expect(filters.lastListed == wanted, "\(filters.filter.text) listed")
    }

    // MARK: - Finding photos

    @Test func `text, attribute and column choices find the photos they name`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        try await filtered(model, "camera:X-T5")
        #expect(Set(names(model)) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        #expect(model.library.isFiltered && filters.listed?.total == 5)
        try await filtered(model, "type:png")
        #expect(names(model) == ["IMG_0004.PNG"])
        try await filtered(model, "0003")
        #expect(names(model) == ["IMG_0003.JPG"])

        filters.clear()
        filters.toggle(.pick)
        try await listed(model)
        #expect(filters.filter.text == "flag:pick" && names(model) == ["IMG_0001.JPG"])
        filters.toggle(.unflagged)
        try await listed(model)
        #expect(filters.filter.text == "flag:pick,none" && model.items.count == 4)
        filters.rate(4)
        try await listed(model)
        #expect(filters.filter.text == "flag:pick,none rating>=4")
        #expect(Set(names(model)) == ["IMG_0001.JPG", "DSC_0005.JPG"])
        filters.setRatingComparison(.lessOrEqual)
        try await listed(model)
        #expect(filters.filter.text == "flag:pick,none rating<=4")
        #expect(Set(names(model)) == ["IMG_0002.JPG", "IMG_0004.PNG", "DSC_0005.JPG"])
        filters.clear()
        filters.toggleEdited(true)
        try await listed(model)
        #expect(Set(names(model)) == ["IMG_0002.JPG", "DSC_0005.JPG"])
        filters.toggleEdited(false)
        try await listed(model)
        #expect(filters.filter.text == "edited:no" && model.items.count == 3)
        filters.toggle(PhotoRecord.Kind.png)
        try await listed(model)
        #expect(filters.filter.text == "edited:no ext:png" && names(model) == ["IMG_0004.PNG"])

        filters.clear()
        filters.setColumns([.camera, .label])
        filters.choose([.text("Canon EOS R5")], inColumn: 0)
        try await listed(model)
        #expect(filters.filter.text == "camera:\"Canon EOS R5\"")
        #expect(Set(names(model)) == ["IMG_0003.JPG", "DSC_0005.JPG"])
        filters.choose([], inColumn: 0)
        try await listed(model)
        #expect(filters.filter.text.isEmpty && model.items.count == 5 && !model.library.isFiltered)
    }

    @Test func `columns count their own photos, and each narrows the columns after it`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setBarShown(true)
        filters.setFilter(LibraryFilter(sections: [.metadata], columns: [.camera, .date, .rating]))
        filters.countColumns()
        try await eventually { filters.columns.count == 3 }
        func counts(_ index: Int) -> [String?: Int] {
            Dictionary(uniqueKeysWithValues: (filters.columns[index]?.values ?? []).map { ($0.name, $0.count) })
        }
        #expect(counts(0) == ["Canon EOS R5": 2, "Fujifilm X-T5": 2, nil: 1] && filters.columns[0]?.total == 5)
        #expect(counts(2) == ["0": 1, "1": 1, "3": 1, "4": 1, "5": 1])

        filters.choose([.text("Fujifilm X-T5")], inColumn: 0)
        try await eventually { filters.columns[1]?.total == 2 && model.items.count == 2 }
        #expect(filters.columns[0]?.total == 5, "a column counts the photos of the choices before it alone")
        #expect(counts(1) == ["2024-06-14": 1, "2024-06-15": 1])
        #expect(counts(2) == ["3": 1, "5": 1])
        let years = try FilterColumnRow.rows(#require(filters.columns[1]), folder: nil)
        #expect(years.map(\.title) == ["2024"] && years[0].count == 2 && years[0].children.first?.children.count == 2)

        filters.choose([.date(.day(2024, 6, 15))], inColumn: 1)
        try await eventually { model.items.count == 1 && filters.columns[2]?.total == 1 }
        #expect(names(model) == ["IMG_0002.JPG"] && counts(2) == ["3": 1])
        #expect(filters.filter.text == "camera:\"Fujifilm X-T5\" date:2024-06-15")
        let rules = filters.filter.rules
        let rows = try FilterColumnRow.rows(#require(filters.columns[0]), folder: nil)
        let chosen = rows.filter { $0.isChosen(by: FilterColumnRow.choice(in: rules, column: .camera), in: .camera) }
        #expect(chosen.map(\.title) == ["Fujifilm X-T5"])
    }

    @Test func `the text and the bar's attributes and columns are one query, each written by the other`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setText("sunset flag:pick rating>=3 label:red,blue camera:X-T5 offline:yes")
        let attributes = filters.attributes
        #expect(attributes.flags == [.pick] && attributes.rating == .init(comparison: .greaterOrEqual, stars: 3))
        #expect(attributes.labels == [.color(.red), .color(.blue)] && attributes.offline && !attributes.missing)
        #expect(FilterColumnRow.choice(in: filters.filter.rules, column: .camera)?.values == [.text("X-T5")])
        filters.toggle(.reject)
        #expect(filters.filter.text == "sunset flag:pick,reject rating>=3 label:red,blue camera:X-T5 offline:yes")
        filters.toggle(.offline)
        filters.toggle(.color(.blue))
        #expect(filters.filter.text == "sunset flag:pick,reject rating>=3 label:red camera:X-T5")
        filters.choose([.text("Canon EOS R5"), .text("Fujifilm X-T5")], inColumn: 1)
        #expect(filters.filter.columns[1] == .camera)
        #expect(filters.filter.text.hasSuffix("camera:\"Canon EOS R5\",\"Fujifilm X-T5\""))

        filters.setText("label:red OR label:blue")
        #expect(filters.attributes.labels.isEmpty, "rules that needn't all match aren't the section's")
        filters.toggle(.pick)
        #expect(filters.filter.text == "(label:red OR label:blue) flag:pick", "a choice narrows them")
        filters.setText("rating>=9 x")
        #expect(filters.error?.message == "rating is a whole number from 0 to 5")
        #expect(filters.attributes.flags == [.pick], "the attributes keep the query the text last read as")
    }

    // MARK: - Sorts

    @Test func `sorts order the photos by every field, both ways`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        func sorted(_ field: LibrarySortField, ascending: Bool = true) async throws -> [String] {
            filters.setSort(LibrarySort(field, ascending: ascending))
            try await listed(model)
            return names(model)
        }
        let byDate = ["IMG_0004.PNG", "IMG_0003.JPG", "IMG_0001.JPG", "IMG_0002.JPG", "DSC_0005.JPG"]
        #expect(try await sorted(.captured) == byDate)
        #expect(try await sorted(.captured, ascending: false) == byDate.reversed())
        #expect(try await sorted(.name) == [
            "DSC_0005.JPG",
            "IMG_0001.JPG",
            "IMG_0002.JPG",
            "IMG_0003.JPG",
            "IMG_0004.PNG",
        ])
        #expect(try await sorted(.rating, ascending: false)
            == ["IMG_0001.JPG", "DSC_0005.JPG", "IMG_0002.JPG", "IMG_0004.PNG", "IMG_0003.JPG"])
        let sizes = try await sorted(.size).map { name in model.items.first { $0.name == name }?.size ?? 0 }
        #expect(sizes == sizes.sorted() && Set(sizes).count > 1)
        let largest = try await sorted(.size, ascending: false)
        #expect(largest.map { name in model.items.first { $0.name == name }?.size ?? 0 } == sizes.reversed())
        #expect(try await Set(sorted(.edited, ascending: false).prefix(2)) == ["IMG_0002.JPG", "DSC_0005.JPG"])
        #expect(try await sorted(.modified).count == 5)
        #expect(try await sorted(.folder, ascending: false)
            == ["IMG_0004.PNG", "IMG_0003.JPG", "IMG_0002.JPG", "IMG_0001.JPG", "DSC_0005.JPG"])
        filters.setSort(LibrarySort())
        try await listed(model)
        #expect(!model.library.isFiltered)
        #expect(names(model) == ["DSC_0005.JPG", "IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG", "IMG_0004.PNG"])
        model.perform(.sortByRating)
        #expect(filters.sort == LibrarySort(.rating))
        model.perform(.reverseSort)
        #expect(filters.sort == LibrarySort(.rating, ascending: false))
    }
}

@MainActor
extension LibraryFilterTests {
    // MARK: - Saved filters, sources and the lock

    @Test func `saved filters come back, in a readable file beside the index, with Redlamp's own`() async throws {
        defer { cleanUp() }
        let (model, service) = try await open()
        let filters = try #require(model.libraryFilters)
        #expect(filters.presets.map(\.name).starts(with: ["Filters Off", "Default Columns", "Flagged", "Rated"]))
        filters.setFilter(LibraryFilter(text: "rating>=3", sections: [.attribute, .text], columns: [.keyword]))
        filters.save(as: "Good Ones")
        #expect(filters.preset?.name == "Good Ones")
        filters.clear()
        #expect(filters.preset == nil)
        try filters.choose(#require(filters.presets.first { $0.name == "Good Ones" }))
        try await eventually { model.items.count == 3 }
        #expect(filters.filter.text == "rating>=3" && filters.filter.columns == [.keyword])
        let file = service.paths.root.appending(path: "Filter Presets.json")
        let saved = try JSONDecoder().decode([FilterPreset].self, from: Data(contentsOf: file))
        #expect(saved.map(\.name) == ["Good Ones"] && saved[0].filter.text == "rating>=3")
        let reopened = LibraryFilters(defaults: nil, presetsURL: file)
        #expect(reopened.presets.contains { $0.name == "Good Ones" && !$0.isBuiltIn })
        try filters.choose(#require(filters.presets.first { $0.name == "Flagged" }))
        try await eventually { model.items.count == 1 }
        #expect(filters.filter.text == "flag:pick")
        try filters.delete(#require(filters.presets.first { $0.name == "Good Ones" }))
        #expect(!filters.presets.contains { $0.name == "Good Ones" })
    }

    @Test func `each source keeps its filter and sort, and the lock keeps one filter across sources`() async throws {
        defer { cleanUp() }
        let (model, service) = try await open()
        let filters = try #require(model.libraryFilters)
        try await filtered(model, "rating>=2")
        filters.setSort(LibrarySort(.rating, ascending: false))
        try await eventually { names(model).first == "IMG_0001.JPG" && model.items.count == 3 }
        model.setIncludesSubfolders(true)
        try await eventually { model.library.isShownFromLibrary && !model.library.isListing && model.items.count == 6 }
        #expect(
            filters.filter.text.isEmpty && filters.sort == LibrarySort(),
            "the folder with its subfolders has its own",
        )
        model.setIncludesSubfolders(false)
        try await eventually { model.library.isShownFromLibrary && model.items.count == 3 }
        #expect(filters.filter.text == "rating>=2" && filters.sort == LibrarySort(.rating, ascending: false))
        #expect(names(model) == ["IMG_0001.JPG", "DSC_0005.JPG", "IMG_0002.JPG"])

        model.perform(.lockFilters)
        #expect(filters.isLocked)
        model.setIncludesSubfolders(true)
        try await eventually { model.library.isShownFromLibrary && model.items.count == 4 }
        #expect(filters.filter.text == "rating>=2", "the lock keeps the filter: the subfolder's 2 stars too")
        model.perform(.lockFilters)
        model.setIncludesSubfolders(false)
        try await eventually { model.library.isShownFromLibrary && !model.library.includesSubfolders }

        let again = LibraryFilters(defaults: defaults, presetsURL: nil)
        again.follow(root, includingSubfolders: false)
        #expect(again.filter.text == "rating>=2" && again.sort == LibrarySort(.rating, ascending: false))
        #expect(service.filters === filters)
    }

    // MARK: - Missing and offline

    @Test func `missing and offline photos are filters, following a volume as it goes and comes back`() async throws {
        defer { cleanUp() }
        let (model, service) = try await open()
        let filters = try #require(model.libraryFilters)
        let core = try #require(service.core)
        try await filtered(model, "offline:yes")
        #expect(model.items.isEmpty)
        let volume = try #require(try await core.index.read { reader in
            try reader.volumes().first.map(\.id)
        })
        let uuid = try #require(try await core.index.read { try $0.volumes().first?.uuid })
        try await core.index.write { try $0.setOffline(true, onVolume: volume, uuid: uuid) }
        try await core.live.photosChanged(core.engine.photosWithChangedState())
        try await eventually { model.items.count == 5 }
        #expect(model.items.count == 5, "every photo of the volume is offline")
        filters.clear()
        filters.toggle(.offline)
        #expect(filters.filter.text == "offline:yes")
        filters.toggle(.missing)
        try await eventually { model.items.isEmpty }
        #expect(filters.filter.text == "offline:yes missing:yes", "nothing is missing")
        try await core.index.write { try $0.setOffline(false, onVolume: volume, uuid: uuid) }
        try await core.live.photosChanged(core.engine.photosWithChangedState())
        try await filtered(model, "-offline:yes")
        try await eventually { model.items.count == 5 }
        #expect(model.items.count == 5)
    }

    // MARK: - Keys, typing and the selection

    @Test func `the backslash shows the bar in Library, where Develop keeps it for Before and After`() {
        #expect(ShortcutAction.resolve(.char("\\"), in: .library)?.action == .toggleFilterBar)
        #expect(ShortcutAction.resolve(.char("\\"), in: .develop)?.action == .beforeAfter)
        #expect(ShortcutAction.resolve(.char("l", command: true), in: .library)?.action == .toggleFilters)
        #expect(ShortcutAction.allCases.filter { $0.sortField != nil }.count == LibrarySortField.allCases.count)
    }

    @Test func `the bar lays its sections out above the grid, its controls apart, its text taking the keyboard`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(text: "rating>=3", sections: [.text, .attribute, .metadata]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually(seconds: 5) { filters.columns.count == 4 }
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let grid = try #require(Self.find(LibraryGridView.self, in: window.contentView))
        #expect(bar.frame.height == LibraryFilterBarView.headerHeight + LibraryFilterBarView.textHeight
            + LibraryFilterBarView.attributeHeight + LibraryFilterBarView.metadataHeight)
        #expect(grid.convert(grid.bounds, to: nil).maxY <= bar.convert(bar.bounds, to: nil).minY + 0.5)
        let controls = bar.subviews.filter { !$0.isHidden && $0.frame.width > 0 && !($0 is FilterAttributeRow) }
            .filter { !($0 is FilterColumnsView) && $0.accessibilityIdentifier() != "library.filter.clear" }
        for (index, control) in controls.enumerated() {
            #expect(bar.bounds.contains(control.frame), "\(type(of: control)) inside the bar")
            for other in controls[(index + 1)...] {
                #expect(!control.frame.insetBy(dx: 1, dy: 1).intersects(other.frame), "\(control) and \(other)")
            }
        }
        #expect((window.firstResponder as? NSTextView)?.delegate === bar.field)
        if let path = ProcessInfo.processInfo.environment["REDLAMP_FILTER_BAR_IMAGE"],
           let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        model.perform(.toggleFilterBar)
        try await eventually(seconds: 2) { bar.isHidden }
        #expect(bar.isHidden && !filters.isBarShown)
    }

    @Test func `a click on a column's row chooses its photos, ⌘-click adds another, and All takes them out`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(sections: [.text, .metadata], columns: [.kind, .camera]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually(seconds: 5) { filters.columns[0]?.values.contains { $0.name == "png" } == true }

        try click("library.filter.column.0.value.png", in: window)
        try await listed(model)
        #expect(filters.filter.text == "ext:png" && names(model) == ["IMG_0004.PNG"])
        try click("library.filter.column.0.value.jpeg", in: window, modifiers: .command)
        try await listed(model)
        #expect(filters.filter.text.contains("jpeg") && filters.filter.text.contains("png"))
        #expect(model.items.count == 5)
        try click("library.filter.column.0.all", in: window)
        try await listed(model)
        #expect(filters.filter.text.isEmpty && !model.library.isFiltered)
    }

    /// Presses and releases the mouse on the view under `identifier`'s middle, as the e2e driver does.
    private func click(_ identifier: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(Self.view(identifier, in: window.contentView), "\(identifier) on screen")
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let hit = try #require(window.contentView?.superview?.hitTest(location))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
            ))
            if type == .leftMouseDown {
                hit.mouseDown(with: event)
            } else {
                hit.mouseUp(with: event)
            }
        }
    }

    private static func view(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
    }

    private static func find<View: NSView>(_: View.Type, in view: NSView?) -> View? {
        guard let view else { return nil }
        if let found = view as? View {
            return found
        }
        return view.subviews.lazy.compactMap { find(View.self, in: $0) }.first
    }

    @Test func `a term being typed is completed where it is, its field's values or a field`() {
        let term = FilterTerm("rating>=3 -camera:\"X-T", cursor: 22)
        #expect(term?.range == 10 ..< 22 && term?.negated == true && term?.field == .camera && term?.value == "X-T")
        #expect(FilterTerm("sunset kw:bir", cursor: 13)?.field == .keyword)
        #expect(FilterTerm("rating>=3", cursor: 9) == nil, "a comparison isn't completed")
        #expect(FilterTerm("sunset ", cursor: 7) == nil)
        #expect(FilterTerm.fields(startingWith: "ra").map(\.text) == ["rating:"])
        let completion = FilterCompletion(QueryCompletion(field: .camera, value: "Fujifilm X-T5")).negated(true)
        let (text, cursor) = FilterTerm.inserting(completion, in: "rating>=3 -camera:\"X-T", at: 10 ..< 22)
        #expect(text == "rating>=3 -camera:\"Fujifilm X-T5\" " && cursor == text.count)
    }

    @Test func `typing never waits on the engine on the main thread, and the latest filter wins`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        var typed = ""
        var slowest = Duration.zero
        let clock = ContinuousClock()
        for character in "camera:\"Canon EOS R5\" rating>=4 -flag:reject" {
            typed.append(character)
            let started = clock.now
            filters.setText(typed)
            slowest = max(slowest, clock.now - started)
        }
        #expect(slowest < .milliseconds(4), "a key's work on the main thread: \(slowest)")
        #expect(model.items.count == 5, "the list follows once the main thread turns")
        try await eventually {
            filters.lastListed?.query?.description == "camera:\"Canon EOS R5\" rating>=4 -flag:reject"
        }
        #expect(names(model) == ["DSC_0005.JPG"])
    }

    @Test func `the selection keeps the photos that remain as the filter changes`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let first = try #require(model.items.first { $0.name == "IMG_0001.JPG" }?.url)
        let second = try #require(model.items.first { $0.name == "IMG_0002.JPG" }?.url)
        let third = try #require(model.items.first { $0.name == "IMG_0003.JPG" }?.url)
        model.select(first)
        model.click(second, toggling: true)
        model.click(third, toggling: true)
        #expect(Set(model.selectedPhotos) == [first, second, third])
        try await filtered(model, "camera:X-T5")
        #expect(Set(model.selectedPhotos) == [first, second], "the X-T5's photos stay selected")
        #expect(model.photoSelection.active.flatMap(model.library.url(ofPhoto:)) != nil)
        try await filtered(model, "camera:X-T5 rating:5")
        #expect(model.selectedPhotos == [first] && model.selection == first)
        try await filtered(model, "camera:\"EOS R5\"")
        #expect(model.items.count == 2)
        #expect(
            model.selection.map { url in model.items.contains { $0.url == url } } == true,
            "a photo found is active",
        )
        try await filtered(model, "")
        #expect(model.items.count == 5)
    }
}
