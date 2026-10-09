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

/// The command palette in the library (LIB-19): folders, collections, keywords, cameras, lenses and
/// places by name, ranked as completion ranks them, and photos by name through the text index,
/// beside the palette's own rows; choosing one shows that source or makes it the filter's term.
@MainActor
struct CommandPaletteLibraryTests {
    struct Photo {
        var path: String
        var make: String?
        var model: String?
        var lens: String?
        var metadata = PhotoMetadata()
    }

    static let photos = [
        Photo(
            path: "Lisbon Trip/IMG_0001.JPG", make: "FUJIFILM", model: "X-T5", lens: "XF35mmF1.4 R",
            metadata: PhotoMetadata(
                keywords: ["Places/Portugal/Lisbon"], location: PhotoLocation(country: "Portugal", city: "Lisboa"),
                collections: ["Trips/Lisbon"],
            ),
        ),
        Photo(
            path: "Lisbon Trip/IMG_0002.JPG", make: "FUJIFILM", model: "X-T5", lens: "XF35mmF1.4 R",
            metadata: PhotoMetadata(keywords: ["Animals/Birds"]),
        ),
        Photo(
            path: "Studio/IMG_0003.JPG", make: "Canon", model: "Canon EOS R5", lens: "RF50mm F1.8 STM",
            metadata: PhotoMetadata(location: PhotoLocation(country: "Portugal", city: "Porto")),
        ),
        Photo(path: "Studio/IMG_0004.JPG"),
        Photo(path: "Studio/IMG_0005.JPG"),
        Photo(path: "Studio/IMG_0006.JPG"),
        Photo(path: "Studio/IMG_0007.JPG"),
        Photo(path: "Studio/DSC_0008.JPG"),
    ]

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "palette-library-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    private let suite = "palette-library-tests-\(UUID().uuidString)"

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private let opened = Opened()

    @MainActor
    final class Opened {
        var service: LibraryService?
    }

    private func cleanUp() {
        opened.service?.closeWithIndex()
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
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        var tiff: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        if let make = photo.make, let model = photo.model {
            tiff = [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model]
        }
        if let lens = photo.lens {
            exif[kCGImagePropertyExifLensModel] = lens
        }
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        if !photo.metadata.isEmpty {
            try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: photo.metadata), for: url)
        }
    }

    /// The folder indexed and open in an editor from the library, with its subfolders; with `damaged`, an empty
    /// JPEG in Studio too, written a while ago.
    private func open(damaged: Bool = false) async throws -> EditorModel {
        for (shade, photo) in Self.photos.enumerated() {
            try write(photo, shade: shade)
        }
        if damaged {
            let empty = root.appending(path: "Studio/Empty.JPG")
            try Data().write(to: empty)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: empty.path,
            )
        }
        let count = Self.photos.count + (damaged ? 1 : 0)
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
        try await eventually(seconds: 20) {
            library.isShownFromLibrary && !library.isListing && library.count == count
        }
        try #require(library.isShownFromLibrary)
        return model
    }

    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Types `text` into the open palette and waits for the library's rows for it.
    private func search(_ text: String, in model: EditorModel) async throws -> CommandPaletteModel {
        let palette = try #require(model.commandPalette)
        palette.setText(text)
        try await eventually { palette.library.text == text && !palette.library.isSearching }
        #expect(palette.library.text == text, "the library's rows for \(text)")
        return palette
    }

    private func libraryRows(_ palette: CommandPaletteModel) -> [PaletteItem] {
        palette.sections.first { $0.title == "Library" }?.items ?? []
    }

    // MARK: - Names

    @Test func `the palette finds the library's folders, collections, keywords, cameras, lenses and places`(
    ) async throws {
        defer { cleanUp() }
        let model = try await open()
        model.openCommandPalette()
        let lisbon = try await libraryRows(search("lisb", in: model))
        #expect(lisbon.map(\.context) == ["City", "Collection", "Keyword", "Folder · Photos"])
        #expect(lisbon.map(\.title) == ["Lisboa", "Trips › Lisbon", "Places › Portugal › Lisbon", "Lisbon Trip"])
        let kinds: [(String, String, String)] = [
            ("x-t5", "Fujifilm X-T5", "Camera"),
            ("xf35", "XF35mmF1.4 R", "Lens"),
            ("portug", "Portugal", "Country"),
            ("porto", "Porto", "City"),
            ("birds", "Animals › Birds", "Keyword"),
            ("studio", "Studio", "Folder · Photos"),
            ("trips", "Trips", "Collection"),
        ]
        for (text, title, context) in kinds {
            let rows = try await libraryRows(search(text, in: model))
            #expect(rows.first.map { [$0.title, $0.context] } == [title, context], "\(text): \(rows.map(\.title))")
        }
        let typo = try await libraryRows(search("lisbom", in: model))
        #expect(typo.first?.title == "Lisboa" && typo.contains { $0.title == "Lisbon Trip" }, "a typo away")
        let palette = try #require(model.commandPalette)
        #expect(palette.rows.first.map { palette.isEnabled($0) } == true)
    }

    @Test func `the commands keep their ranking, and the library's rows come after them`() async throws {
        defer { cleanUp() }
        let model = try await open()
        model.openCommandPalette()
        let palette = try #require(model.commandPalette)
        let commands = PaletteCatalog.sections(page: nil, scope: .all, query: "port", editor: model)
            .flatMap(\.items)
        #expect(commands.contains { $0.kind == .action(.export) })
        _ = try await search("port", in: model)
        #expect(Array(palette.rows.prefix(commands.count)) == commands)
        #expect(palette.sections.last?.title == "Library")
        #expect(palette.rows.dropFirst(commands.count).first?.title == "Porto", "the shortest name it starts")
        palette.setText("")
        #expect(!palette.rows.contains { $0.kind.rank == 5 }, "browsing lists no names")
    }

    // MARK: - Choosing

    @Test func `choosing a name makes it the filter's term, and a folder or a photo shows it`() async throws {
        defer { cleanUp() }
        let model = try await open()
        let filters = try #require(model.libraryFilters)
        model.openCommandPalette()
        var palette = try await search("birds", in: model)
        let birds = try #require(libraryRows(palette).first)
        palette.select(birds)
        palette.activate(birds)
        #expect(filters.filter.text == "kw:Animals/Birds" && filters.isBarShown && model.commandPalette == nil)
        try await eventually { model.items.map(\.name) == ["IMG_0002.JPG"] }
        #expect(model.items.map(\.name) == ["IMG_0002.JPG"])

        model.openCommandPalette()
        palette = try await search("x-t5", in: model)
        let camera = try #require(libraryRows(palette).first)
        palette.activate(camera)
        #expect(filters.filter.text == "kw:Animals/Birds camera:\"Fujifilm X-T5\"")
        model.openCommandPalette()
        palette = try await search("canon", in: model)
        try palette.activate(#require(libraryRows(palette).first))
        #expect(filters.filter.text == "kw:Animals/Birds camera:\"Canon EOS R5\"", "a camera in place of the last")
        filters.clear()

        model.openCommandPalette()
        palette = try await search("studio", in: model)
        let studio = try #require(libraryRows(palette).first { $0.context.hasPrefix("Folder") })
        palette.activate(studio)
        try await eventually { model.folder?.lastPathComponent == "Studio" }
        #expect(model.folder?.standardizedFileURL == root.appending(path: "Studio").standardizedFileURL)
    }

    @Test func `photos are found by name through the text index, and a row filters by the name`() async throws {
        defer { cleanUp() }
        let model = try await open()
        let filters = try #require(model.libraryFilters)
        model.openCommandPalette()
        var palette = try await search("img_000", in: model)
        let rows = libraryRows(palette)
        let photos = rows.filter {
            if case .photo = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(photos.map(\.title) == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG", "IMG_0004.JPG", "IMG_0005.JPG"])
        #expect(photos.first?.context == "Photo · Lisbon Trip")
        #expect(rows.last?.kind == .photosNamed("img_000") && rows.last?.context == "7 photos")
        #expect(try await libraryRows(search("im", in: model)).allSatisfy {
            if case .photo = $0.kind {
                false
            } else {
                true
            }
        }, "names under three characters aren't searched for")

        palette = try await search("dsc_0008", in: model)
        let photo = try #require(libraryRows(palette).first { $0.title == "DSC_0008.JPG" })
        #expect(photo.context == "Photo · Studio")
        palette.activate(photo)
        try await eventually { model.selection?.lastPathComponent == "DSC_0008.JPG" }
        #expect(model.selection?.lastPathComponent == "DSC_0008.JPG")

        model.openCommandPalette()
        palette = try await search("img_000", in: model)
        try palette.activate(#require(libraryRows(palette).last))
        #expect(filters.filter.text == "name:img_000")
    }

    // MARK: - Terms of the query language

    @Test func `the palette completes the query's terms as the bar's text does, a trait with the photos it finds`(
    ) async throws {
        defer { cleanUp() }
        let model = try await open(damaged: true)
        model.openCommandPalette()
        let damaged = try await #require(libraryRows(search("is:dam", in: model)).first)
        #expect(damaged.kind == .queryTerm("is:damaged") && damaged.title == "Damaged Files")
        #expect(damaged.context == "is:damaged · 1 photo", "the bar's source's damaged file")
        let unread = try await libraryRows(search("unread", in: model))
        #expect(
            unread.first?.kind == .queryTerm("is:damaged"),
            "the trait found by its synonym; no row for the unreadable field, whose values the palette doesn't complete",
        )
        let fields = try await libraryRows(search("c", in: model)).filter {
            if case .queryField = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(fields.map(\.title) == ["camera:", "collection:", "city:"], "fields the palette completes, three")
        let moments = try await libraryRows(search("unpicked", in: model))
        #expect(moments
            .contains { $0.kind == .queryTerm("is:unpicked-moment") && $0.title == "Moments without a Pick" })
        let negated = try await #require(libraryRows(search("-is:dam", in: model)).first)
        #expect(negated.kind == .queryTerm("-is:damaged") && negated.title == "Not Damaged Files")
        #expect(negated.context == "-is:damaged")
        let traits = try await libraryRows(search("is:", in: model))
        #expect(traits.map(\.kind) == LibraryQuery.Trait.allCases.map { .queryTerm("is:\($0.rawValue)") })
        let red = try await libraryRows(search("red", in: model))
        #expect(red.first?.kind == .queryTerm("label:red") && red.first?.title == "Red")

        let palette = try await search("orien", in: model)
        let field = try #require(libraryRows(palette).first)
        #expect(field.kind == .queryField("orientation:") && field.context == "Field")
        palette.activate(field)
        #expect(model.commandPalette === palette && palette.text == "orientation:", "↵ types the field")
        try await eventually { palette.library.text == "orientation:" && !palette.library.isSearching }
        #expect(libraryRows(palette).map(\.kind) == PhotoOrientation.allCases.map {
            .queryTerm("orientation:\($0.rawValue)")
        })
        palette.handle(.escape)
    }

    @Test func `choosing a term makes it one of the filter's, a trait beside the others, a value in its field's place`(
    ) async throws {
        defer { cleanUp() }
        let model = try await open(damaged: true)
        let filters = try #require(model.libraryFilters)
        func choose(_ text: String) async throws {
            model.openCommandPalette()
            let palette = try await search(text, in: model)
            let row = try #require(libraryRows(palette).first {
                if case .queryTerm = $0.kind {
                    true
                } else {
                    false
                }
            })
            #expect(palette.isEnabled(row), "\(text)")
            palette.select(row)
            palette.activate(row)
            #expect(model.commandPalette == nil, "\(text)")
        }
        try await choose("is:dam")
        #expect(filters.filter.text == "is:damaged" && filters.isBarShown)
        try await eventually { model.items.map(\.name) == ["Empty.JPG"] }
        #expect(model.items.map(\.name) == ["Empty.JPG"])
        try await choose("is:unpi")
        #expect(filters.filter.text == "is:damaged is:unpicked-moment", "a trait goes beside the others")
        try await choose("is:dam")
        #expect(filters.filter.text == "is:damaged is:unpicked-moment", "a term the filter has changes nothing")
        try await choose("label:re")
        #expect(filters.filter.text == "is:damaged is:unpicked-moment label:red")
        try await choose("label:blu")
        #expect(filters.filter.text == "is:damaged is:unpicked-moment label:blue", "in the label's place")
        filters.setText("rating>=3 OR flag:pick")
        try await choose("-is:dam")
        #expect(filters.filter.text == "(rating>=3 OR flag:pick) -is:damaged", "narrowing what the text finds")
        filters.clear()
    }
}
