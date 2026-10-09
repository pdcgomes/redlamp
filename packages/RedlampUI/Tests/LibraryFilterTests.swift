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
        /// IPTC Core's fields, a custom label and collections, in its sidecar.
        var metadata = PhotoMetadata()
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
            metadata: PhotoMetadata(
                creator: "Ana Silva", location: PhotoLocation(country: "Portugal", city: "Lisboa"),
                collections: ["Trips/Lisbon"],
            ),
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
            metadata: PhotoMetadata(creator: "Ana Silva", collections: ["Trips/Lisbon"]),
        ),
        Photo(
            path: "IMG_0003.JPG",
            make: "Canon",
            model: "Canon EOS R5",
            iso: 100,
            date: "2023:01:02 09:00:00",
            flag: .reject,
        ),
        Photo(path: "IMG_0004.PNG", rating: 1, metadata: PhotoMetadata(customLabel: "Hero")),
        Photo(
            path: "DSC_0005.JPG",
            make: "Canon",
            model: "Canon EOS R5",
            iso: 3200,
            date: "2024:07:01 08:00:00",
            rating: 4,
            edited: true,
            metadata: PhotoMetadata(location: PhotoLocation(country: "Portugal", city: "Porto")),
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

    private let opened = Opened()

    @MainActor
    final class Opened {
        var service: LibraryService?
    }

    func cleanUp() {
        LibrarySandbox.remove(base, closing: [opened.service])
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
        var metadata = photo.metadata
        metadata.rating = photo.rating
        metadata.flag = photo.flag
        metadata.label = photo.label
        if !metadata.isEmpty || photo.edited {
            var recipe = EditRecipe()
            if photo.edited {
                recipe[.exposure] = 1
            }
            try SidecarStore().save(Sidecar(recipe: recipe, metadata: metadata), for: url)
        }
    }

    /// Photos in moments by the camera's clock: M01 and M02 at 10:00, M01 picked; M03 and M04 after a pause of
    /// 140 s, which starts a moment up to two steps looser; M05 and M06 at noon; and M07 without a capture time.
    static let moments = [
        Photo(path: "M01.JPG", date: "2024:06:14 10:00:00", flag: .pick),
        Photo(path: "M02.JPG", date: "2024:06:14 10:00:10"),
        Photo(path: "M03.JPG", date: "2024:06:14 10:02:30"),
        Photo(path: "M04.JPG", date: "2024:06:14 10:02:40"),
        Photo(path: "M05.JPG", date: "2024:06:14 12:00:00"),
        Photo(path: "M06.JPG", date: "2024:06:14 12:00:10"),
        Photo(path: "M07.PNG"),
    ]

    /// The folder of `photos` indexed, open in an editor from the library, its subfolders shown when
    /// `subfolders`.
    func open(
        _ photos: [Photo] = Self.photos, subfolders: Bool = false,
    ) async throws -> (EditorModel, LibraryService) {
        for (shade, photo) in photos.enumerated() {
            try write(photo, shade: shade)
        }
        let library = FolderLibrary()
        library.add([root])
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
        library.setIncludesSubfolders(subfolders)
        model.open([root])
        try await eventually { library.isShownFromLibrary && !library.isListing && library.count > 0 }
        try #require(library.isShownFromLibrary)
        return (model, service)
    }

    func eventually(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func names(_ model: EditorModel) -> [String] {
        model.items.map(\.name)
    }

    /// Waits until the library has listed the photos `text` finds.
    func filtered(_ model: EditorModel, _ text: String) async throws {
        let filters = try #require(model.libraryFilters)
        filters.setText(text)
        try await listed(model)
    }

    /// Waits until the library has listed the photos of the filter and sort the bar has now.
    func listed(_ model: EditorModel) async throws {
        let filters = try #require(model.libraryFilters)
        let query = filters.filter.query
        let sort = filters.sort
        let wanted = LibraryListFilterSummary(
            query: query, sort: sort.query, reversed: sort.field == .folder && !sort.ascending,
        )
        try await eventually { filters.lastListed == wanted }
        #expect(filters.lastListed == wanted, "\(filters.filter.text) listed")
    }

    static func view(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
    }

    static func find<View: NSView>(_: View.Type, in view: NSView?) -> View? {
        guard let view else { return nil }
        if let found = view as? View {
            return found
        }
        return view.subviews.lazy.compactMap { find(View.self, in: $0) }.first
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
        // The columns are handed over one at a time, as each is counted.
        try await eventually {
            filters.columns[1]?.total == 2 && filters.columns[2]?.total == 2 && model.items.count == 2
        }
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

    @Test func `columns count creators, cities, countries, collections and custom labels from the sidecars`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setBarShown(true)
        filters.setFilter(LibraryFilter(
            sections: [.metadata], columns: [.creator, .city, .country, .collection, .customLabel],
        ))
        filters.countColumns()
        try await eventually { filters.columns.count == 5 }
        func counts(_ index: Int) -> [String?: Int] {
            Dictionary(uniqueKeysWithValues: (filters.columns[index]?.values ?? []).map { ($0.name, $0.count) })
        }
        #expect(counts(0) == ["Ana Silva": 2, nil: 3])
        #expect(counts(1) == ["Lisboa": 1, "Porto": 1, nil: 3])
        #expect(counts(2) == ["Portugal": 2, nil: 3])
        #expect(counts(3) == ["Trips": 2, "Trips/Lisbon": 2, nil: 3])
        #expect(counts(4) == ["Hero": 1, nil: 4])
        let sets = try FilterColumnRow.rows(#require(filters.columns[3]), folder: nil)
        #expect(sets.map(\.title) == ["Trips", "No Collection"] && sets[0].children.map(\.title) == ["Lisbon"])
        #expect(FacetColumn.allCases.suffix(5).map(\.title) == [
            "Creator",
            "City",
            "Country",
            "Collection",
            "Custom Label",
        ])

        filters.choose([.text("Ana Silva")], inColumn: 0)
        try await listed(model)
        #expect(Set(names(model)) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        try await eventually { filters.columns[1]?.total == 2 }
        #expect(counts(1) == ["Lisboa": 1, nil: 1], "the city column counts the creator's photos")
        filters.choose([.text("Trips/Lisbon")], inColumn: 3)
        try await listed(model)
        #expect(filters.filter.text == "creator:\"Ana Silva\" collection:Trips/Lisbon")
        #expect(Set(names(model)) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        filters.choose([.text("Porto")], inColumn: 1)
        try await listed(model)
        #expect(model.items.isEmpty && filters.filter.text.hasSuffix(" city:Porto"))
        filters.clear()
        filters.choose([.text("Hero")], inColumn: 4)
        try await listed(model)
        #expect(filters.filter.text == "label:Hero" && names(model) == ["IMG_0004.PNG"])
        try await eventually { filters.columns[4]?.total == 5 }
        let rows = try FilterColumnRow.rows(#require(filters.columns[4]), folder: nil)
        let rules = filters.filter.rules
        #expect(rows
            .filter { $0.isChosen(by: FilterColumnRow.choice(in: rules, column: .customLabel), in: .customLabel) }
            .map(\.title) == ["Hero"])
    }
}

@MainActor
extension LibraryFilterTests {
    @Test func `pressing Tab completes collections, custom labels and traits, a trait with the photos it finds`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.complete("collection:tri", cursor: 14)
        try await eventually { !filters.completions.isEmpty }
        #expect(filters.completions.map(\.text) == ["collection:Trips ", "collection:Trips/Lisbon "])
        #expect(filters.completions.map(\.title) == ["Trips", "Trips › Lisbon"])
        #expect(filters.completions.first?.kind == "Collection" && filters.completionRange == 0 ..< 14)
        filters.complete("rating>=1 -label:her", cursor: 20)
        try await eventually { filters.completions.first?.kind == "Custom Label" }
        #expect(filters.completions.map(\.text) == ["-label:Hero "] && filters.completions.first?
            .title == "Hero")
        filters.complete("lis", cursor: 3)
        try await eventually { filters.completions.contains { $0.kind == "Collection" } }
        #expect(filters.completions.contains { $0.text == "collection:Trips/Lisbon " })
        filters.complete("type:jpeg pano", cursor: 14)
        try await eventually { filters.completions.first?.kind == "Trait" }
        let panorama = try #require(filters.completions.first)
        #expect(panorama.text == "is:panorama " && panorama.title == "Panorama")
        #expect(panorama.count == 1 && panorama.detail == "Trait · 1", "DSC_0005.JPG, twice as wide as it's tall")
    }

    @Test func `the moments without a pick are a term of the text, the Attribute section and completion alike`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open(Self.moments)
        let filters = try #require(model.libraryFilters)
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }

        try await filtered(model, "is:unpicked-moment")
        #expect(names(model) == ["M03.JPG", "M04.JPG", "M05.JPG", "M06.JPG", "M07.PNG"])
        #expect(filters.attributes.unpickedMoments && filters.listed?.total == 7)
        filters.show(.attribute, adding: true)
        model.perform(.toggleFilterBar)
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let row = try #require(Self.find(FilterAttributeRow.self, in: bar))
        try await eventually { !bar.isHidden && !row.isHidden }
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(Self.view("library.filter.unpicked-moments", in: row))
        #expect(button.accessibilityValue() as? String == "on")
        let outside = row.subviews.filter { !($0 is NSTextField) && !row.bounds.contains($0.frame) }
        #expect(outside.isEmpty, "every button in the Attribute section's \(row.bounds): \(outside.map(\.frame))")
        model.perform(.toggleFilterBar)
        model.setLooseness(3)
        try await eventually { model.items.count == 3 }
        #expect(names(model) == ["M05.JPG", "M06.JPG", "M07.PNG"], "three steps looser, M03 joins M01's moment")
        #expect(filters.moments == MomentSetting(looseness: 3), "the bar follows the source's setting, hidden or not")

        let noon = try #require(model.items.first { $0.name == "M06.JPG" }?.url)
        model.select(noon)
        model.cull(.flag(.pick))
        try await eventually { model.items.count == 1 }
        #expect(names(model) == ["M07.PNG"], "a pick at noon covers its moment")

        filters.complete("unpi", cursor: 4)
        try await eventually { filters.completions.first?.kind == "Trait" }
        let completion = try #require(filters.completions.first)
        #expect(completion.text == "is:unpicked-moment " && completion.title == "Moments without a Pick")
        #expect(completion.detail == "Trait · 1", "the folder's photos it finds, with the folder's setting")
        filters.endCompletion()

        filters.toggle(.unpickedMoment)
        try await listed(model)
        #expect(filters.filter.text.isEmpty && model.items.count == 7 && !filters.attributes.unpickedMoments)
        filters.setText("rating>=1 OR flag:pick")
        filters.toggle(.unpickedMoment)
        try await listed(model)
        #expect(filters.filter.text == "(rating>=1 OR flag:pick) is:unpicked-moment" && model.items.isEmpty)
        #expect(filters.attributes.unpickedMoments)
        filters.setText("is:panorama,unpicked-moment")
        #expect(!filters.attributes.unpickedMoments, "a trait among others is the text's")
        filters.clear()
        model.setLooseness(0)
    }

    @Test func `the damaged files are a term of the text, the Attribute section and completion alike`() async throws {
        defer { cleanUp() }
        let earlier = Date().addingTimeInterval(-600)
        try write(Photo(path: "Cut.JPG"), shade: 9)
        let cut = root.appending(path: "Cut.JPG")
        try Data(contentsOf: cut).dropLast(40).write(to: cut)
        let empty = root.appending(path: "Empty.JPG")
        try Data().write(to: empty)
        for url in [cut, empty] {
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: url.path)
        }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }

        try await filtered(model, "is:damaged")
        #expect(Set(names(model)) == ["Cut.JPG", "Empty.JPG"])
        #expect(filters.attributes.damaged && filters.listed?.total == 7)
        filters.complete("dama", cursor: 4)
        try await eventually { filters.completions.first?.kind == "Trait" }
        let completion = try #require(filters.completions.first)
        #expect(completion.text == "is:damaged " && completion.title == "Damaged Files")
        #expect(completion.detail == "Trait · 2", "the folder's damaged files")
        filters.endCompletion()

        filters.show(.attribute, adding: true)
        model.perform(.toggleFilterBar)
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let row = try #require(Self.find(FilterAttributeRow.self, in: bar))
        try await eventually { !bar.isHidden && !row.isHidden }
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(Self.view("library.filter.damaged", in: row))
        #expect(button.accessibilityValue() as? String == "on")
        let outside = row.subviews.filter { !($0 is NSTextField) && !row.bounds.contains($0.frame) }
        #expect(outside.isEmpty, "every button in the Attribute section's \(row.bounds): \(outside.map(\.frame))")
        model.perform(.toggleFilterBar)

        filters.toggle(.damaged)
        try await listed(model)
        #expect(filters.filter.text.isEmpty && model.items.count == 7 && !filters.attributes.damaged)
        filters.setText("rating>=1 OR flag:pick")
        filters.toggle(.damaged)
        try await listed(model)
        #expect(filters.filter.text == "(rating>=1 OR flag:pick) is:damaged" && model.items.isEmpty)
        #expect(filters.attributes.damaged && !filters.attributes.unpickedMoments)
        filters.clear()
    }

    @Test func `a filter that finds nothing offers to take out the term in its way, as a button in the bar`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(text: "", sections: [.text]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        let module = try #require(Self.find(LibraryModuleView.self, in: window.contentView))
        try #require(module.showsFilmstrip)

        try await filtered(model, "camera:X-T5 rating:4")
        #expect(model.items.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            module.showsFilmstrip,
            "the filmstrip stays as a filter finds nothing, so the grid doesn't change height",
        )
        try await eventually { filters.removal != nil }
        #expect(filters.removal?.term == "rating:4" && filters.removal?.count == 2, "the X-T5's two photos")
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let button = try #require(Self.view("library.filter.removal", in: bar))
        try await eventually { !button.isHidden }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!button.isHidden && bar.bounds.contains(button.frame) && button.frame.width > 100)
        #expect(button.accessibilityLabel() == "Remove rating:4: 2 photos")

        filters.setText("camera:X-T5 rating:4 x")
        #expect(filters.removal == nil, "a change to the filter takes the offer back at once")
        try await eventually { button.isHidden }
        try await filtered(model, "camera:X-T5 rating:4")
        // The bar follows the offer a turn after the filter has it.
        try await eventually { filters.removal != nil && !button.isHidden }
        try await click("library.filter.removal", in: window)
        try await listed(model)
        #expect(filters.filter.text == "camera:X-T5" && Set(names(model)) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        try await eventually { button.isHidden }
        #expect(filters.removal == nil)
    }

    @Test func `a filter that finds nothing offers a name a typo away, as a button that puts it in the word's place`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(text: "", sections: [.text]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))

        try await filtered(model, "lisbao")
        #expect(model.items.isEmpty)
        try await eventually { filters.suggestion != nil && filters.removal != nil }
        let suggestion = try #require(filters.suggestion)
        #expect(suggestion.name == "Lisboa" && suggestion.term == "Lisboa" && suggestion.count == 1, "IMG_0001's city")
        #expect(filters.offers.map(\.title) == ["Did you mean Lisboa? 1 photo", "Remove lisbao: 5 photos"])
        let button = try #require(Self.view("library.filter.suggestion", in: bar))
        let removal = try #require(Self.view("library.filter.removal", in: bar))
        try await eventually { !button.isHidden && !removal.isHidden }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!button.isHidden && button.frame.width > 100, "the suggestion's button")
        #expect(button.frame.maxX <= removal.frame.minX, "beside the removal's")
        #expect(button.accessibilityLabel() == "Did you mean Lisboa? 1 photo")

        try await click("library.filter.suggestion", in: window)
        try await listed(model)
        #expect(filters.filter.text == "Lisboa" && names(model) == ["IMG_0001.JPG"], "the word replaced")
        try await eventually { button.isHidden }
        #expect(button.isHidden && filters.suggestion == nil && filters.removal == nil)

        // A field's value, the filter's other terms kept.
        try await filtered(model, "rating>=3 camera:canom")
        try await eventually { filters.suggestion != nil }
        #expect(filters.suggestion?.term == "camera:Canon" && filters.suggestion?.count == 1, "DSC_0005, rated 4")
        filters.take(.suggestion)
        try await listed(model)
        #expect(filters.filter.text == "rating>=3 camera:Canon" && names(model) == ["DSC_0005.JPG"])
    }

    @Test func `completions of places say which field each is`() async throws {
        let kinds: [(LibraryQuery.Field, String)] = [
            (.city, "City"), (.country, "Country"), (.state, "State or Province"), (.sublocation, "Sublocation"),
        ]
        for (field, kind) in kinds {
            #expect(FilterCompletion(QueryCompletion(field: field, value: "Lisboa")).kind == kind, "\(field)")
        }
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.complete("lisb", cursor: 4)
        try await eventually { filters.completions.contains { $0.kind == "City" } }
        #expect(filters.completions.contains { $0.kind == "City" && $0.text == "city:Lisboa " && $0.title == "Lisboa" })
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
}
