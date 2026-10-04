import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// Exports carry the edit that made them in their XMP, and the rest of their metadata reads back
/// as it did without it.
struct EmbeddedEditTests {
    static let recipe = SidecarSamples.everything.recipe

    static let rawFixtures: [URL] = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isRaw).sorted { $0.path < $1.path }
    }()

    /// A camera JPEG with every kind of metadata an export copies: EXIF, lens details (which
    /// ImageIO keeps in XMP), TIFF fields, a location, and IPTC fields with a city and a rating.
    static func source(in folder: URL, exifCopyright: String = "© Pedro") throws -> URL {
        let url = folder.appending(path: "IMG_0001.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
                kCGImagePropertyExifFNumber: 2.8,
            ],
            kCGImagePropertyExifAuxDictionary: [
                kCGImagePropertyExifAuxLensModel: "NIKKOR Z 24-70mm f/2.8 S",
                kCGImagePropertyExifAuxSerialNumber: "3012345",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Nikon",
                kCGImagePropertyTIFFModel: "Z 8",
                kCGImagePropertyTIFFArtist: "Pedro",
                kCGImagePropertyTIFFCopyright: exifCopyright,
            ],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Lisbon",
                kCGImagePropertyIPTCCountryPrimaryLocationName: "Portugal",
                kCGImagePropertyIPTCCopyrightNotice: "© Pedro",
                kCGImagePropertyIPTCKeywords: ["harbour", "dusk"],
                kCGImagePropertyIPTCStarRating: 4,
            ],
        ]
        CGImageDestinationAddImage(
            destination,
            ExportWriterTests.image(width: 64, height: 48),
            properties as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// An export of a test image in `format`, with the metadata of `source` (or of `source(in:)`)
    /// under `policy`, and `recipe` unless it is nil.
    static func export(
        _ format: ExportFormat,
        policy: ExportMetadataPolicy = .all,
        recipe: EditRecipe? = recipe,
        bits: Int = 8,
        source: URL? = nil,
        configure: (inout ExportSettings) -> Void = { _ in },
    ) throws -> Data {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        var settings = ExportSettings()
        settings.setFormat(format)
        configure(&settings)
        let metadata = try ExportMetadata.properties(
            from: source ?? Self.source(in: folder),
            policy: policy,
            recipe: recipe,
        )
        return try ImageExporter.encode(ExportWriterTests.image(bits: bits), settings: settings, metadata: metadata)
    }

    static func properties(_ data: Data) throws -> NSDictionary {
        try NSDictionary(dictionary: ExportWriterTests.properties(data))
    }

    /// Every XMP property ImageIO reads from the file, with its value, by path; the edit's apart.
    static func xmp(_ data: Data) throws -> (other: [String: String], edit: [String: String]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        var other: [String: String] = [:]
        var edit: [String: String] = [:]
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return (other, edit) }
        let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { path, tag in
            let value = (CGImageMetadataTagCopyValue(tag) as? String) ?? "(\(CGImageMetadataTagGetType(tag).rawValue))"
            if CGImageMetadataTagCopyNamespace(tag) as String? == EmbeddedEdit.namespace {
                edit[CGImageMetadataTagCopyName(tag).map { $0 as String } ?? ""] = value
            } else {
                other[path as String] = value
            }
            return true
        }
        return (other, edit)
    }

    /// A JPEG with these properties, as `prefix:name`, in the edit's namespace.
    static func jpeg(withEdit properties: [(name: String, value: String)], prefix: String = "redlamp") throws -> Data {
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataRegisterNamespaceForPrefix(
            metadata, EmbeddedEdit.namespace as CFString, prefix as CFString, nil,
        ))
        for (name, value) in properties {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, "\(prefix):\(name)" as CFString, value as CFString))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil,
        ))
        CGImageDestinationAddImageAndMetadata(destination, ExportWriterTests.image(), metadata, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// An edit with one brush stroke of `count` points.
    static func brushed(points count: Int) -> EditRecipe {
        var recipe = EditRecipe()
        let points = (0 ..< count).map { ImagePoint(x: Double($0) / 7919, y: Double($0 % 97) / 97) }
        let stroke = BrushStroke(points: points, size: 0.01)
        recipe.masks = [MaskLayer(
            name: "Sky",
            components: [MaskComponent(shape: .brush(BrushMask(strokes: [stroke])))],
        )]
        return recipe
    }

    // MARK: - Writing

    @Test(arguments: ExportFormat.allCases, [8, 16])
    func `the edit comes back from every format`(format: ExportFormat, bits: Int) throws {
        let data = try Self.export(format, bits: bits)
        let edit = try #require(EmbeddedEdit.read(data))
        #expect(edit.recipe == Self.recipe)
        #expect(edit.formatVersion == EditRecipe.formatVersion)
        #expect(!edit.isWrittenByNewerVersion)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == format.typeIdentifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 256 && image.height == 192)
    }

    @Test(arguments: ExportFormat.allCases, [ExportMetadataPolicy.all, .allExceptLocation])
    func `the rest of the metadata reads back as it did without the edit`(
        format: ExportFormat,
        policy: ExportMetadataPolicy,
    ) throws {
        let with = try Self.export(format, policy: policy)
        let without = try Self.export(format, policy: policy, recipe: nil)
        #expect(try Self.properties(with) == Self.properties(without))
        let (other, edit) = try Self.xmp(with)
        #expect(try other == Self.xmp(without).other)
        #expect(edit["Recipe"] != nil)
        let exifAux = try Self.properties(with)[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        #expect(exifAux?[kCGImagePropertyExifAuxSerialNumber] as? String == "3012345")
        let iptc = try Self.properties(with)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCStarRating] as? Int == 4)
        #expect(iptc?[kCGImagePropertyIPTCCity] as? String == (policy == .all ? "Lisbon" : nil))
    }

    @Test(arguments: ExportFormat.allCases)
    func `metadata None embeds no edit`(format: ExportFormat) throws {
        let data = try Self.export(format, policy: .none)
        #expect(EmbeddedEdit.read(data) == nil)
        #expect(try Self.xmp(data).edit.isEmpty)
    }

    @Test func `the XMP holds the recipe as edit.json does, and its versions`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = try Self.source(in: folder)
        let store = SidecarStore()
        try store.save(Sidecar(recipe: Self.recipe), for: photo)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.editURL(for: photo)))
        let written = try #require((saved as? [String: Any])?["recipe"] as? [String: Any])

        let edit = try Self.xmp(Self.export(.jpeg)).edit
        let json = try #require(edit["Recipe"])
        let embedded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(NSDictionary(dictionary: written).isEqual(embedded))
        #expect(!json.contains("\n"))
        #expect(edit["FormatVersion"] == String(EditRecipe.formatVersion))
        #expect(edit["ProcessVersion"] == String(Self.recipe.processVersion))
        let bitmap = try #require(Self.recipe.maskBitmaps.first)
        #expect(bitmap.png != nil)
        #expect(json.contains(bitmap.sha256))
    }

    @Test(arguments: ExportFormat.allCases)
    func `an exported file carries the edit`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let source = try Self.source(in: folder)
        var settings = ExportSettings()
        settings.setFormat(format)
        let url = ExportDestination.url(for: source, settings: settings)
        let metadata = ExportMetadata.properties(from: source, policy: .all, recipe: Self.recipe)
        try ImageExporter.write(
            ExportWriterTests.image(),
            to: url,
            settings: settings,
            metadata: metadata,
            source: source,
        )
        #expect(EmbeddedEdit.read(url)?.recipe == Self.recipe)
        #expect(ExportMetadata.isExport(url))
    }

    @Test func `a size-limited export carries the edit within the limit`() throws {
        let data = try Self.export(.jpeg) { settings in
            settings.limitsFileSize = true
            settings.fileSizeLimitKB = 40
        }
        #expect(data.count <= 40000)
        #expect(EmbeddedEdit.read(data)?.recipe == Self.recipe)
    }

    @Test(arguments: ExportFormat.allCases)
    func `an edit too big to embed is left out, not cut short`(format: ExportFormat) throws {
        let recipe = Self.brushed(points: 8000)
        #expect(EmbeddedEdit.xmp(for: recipe) == nil)
        let data = try Self.export(format, recipe: recipe)
        #expect(EmbeddedEdit.read(data) == nil)
        #expect(try Self.xmp(data).edit.isEmpty)
        #expect(try Self.properties(data) == Self.properties(Self.export(format, recipe: nil)))
    }

    @Test func `an edit too big for one JPEG XMP segment comes back whole`() throws {
        let recipe = Self.brushed(points: 2200)
        let size = try #require(EmbeddedEdit.xmp(for: recipe)?.count)
        #expect(size > 70000 && size <= EmbeddedEdit.maximumSize)
        let data = try Self.export(.jpeg, recipe: recipe)
        #expect(EmbeddedEdit.read(data)?.recipe == recipe)

        var extensions = 0
        let bytes = [UInt8](data)
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] != 0xDA {
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let payload = Data(bytes[(offset + 4) ..< min(offset + 2 + length, bytes.count)])
            if bytes[offset + 1] == 0xE1, payload.starts(with: Data("http://ns.adobe.com/xmp/extension/\0".utf8)) {
                extensions += 1
            }
            offset += 2 + length
        }
        #expect(extensions >= 2)
    }

    /// Given XMP holding `dc:rights`, ImageIO writes it over the EXIF copyright.
    @Test(arguments: ExportFormat.allCases)
    func `a photo whose copyright fields disagree keeps them`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let source = try Self.source(in: folder, exifCopyright: "© Someone else")
        let with = try Self.export(format, source: source)
        let without = try Self.export(format, recipe: nil, source: source)
        #expect(EmbeddedEdit.read(with)?.recipe == Self.recipe)
        #expect(try Self.properties(with) == Self.properties(without))
        let tiff = try Self.properties(with)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFCopyright] as? String == "© Someone else")
    }

    @Test(.enabled(if: !EmbeddedEditTests.rawFixtures.isEmpty))
    func `camera metadata from raw files comes through with the edit`() throws {
        for raw in Self.rawFixtures {
            for format in ExportFormat.allCases {
                let with = try Self.export(format, source: raw)
                let without = try Self.export(format, recipe: nil, source: raw)
                #expect(EmbeddedEdit.read(with)?.recipe == Self.recipe, "\(raw.lastPathComponent) \(format)")
                #expect(try Self.properties(with) == Self.properties(without), "\(raw.lastPathComponent) \(format)")
            }
        }
    }

    // MARK: - Reading

    @Test func `a file without an edit reads as none`() throws {
        #expect(try EmbeddedEdit.read(Self.export(.jpeg, recipe: nil)) == nil)
        #expect(EmbeddedEdit.read(Data("not an image".utf8)) == nil)
        #expect(EmbeddedEdit.read(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) == nil)
    }

    @Test func `an unreadable recipe reads as none`() throws {
        #expect(try EmbeddedEdit.read(Self.jpeg(withEdit: [("Recipe", #"{"version":3,"treatment":"sepia"}"#)])) == nil)
        #expect(try EmbeddedEdit.read(Self.jpeg(withEdit: [("Recipe", "{")])) == nil)
    }

    @Test(arguments: [
        (#"{"version":4,"processVersion":9}"#, 4, 9),
        (#"{"version":3,"processVersion":99}"#, 3, 99),
    ])
    func `an edit from a newer Redlamp reads, marked newer`(json: String, format: Int, process: Int) throws {
        let edit = try #require(EmbeddedEdit.read(Self.jpeg(withEdit: [("Recipe", json)])))
        #expect(edit.formatVersion == format)
        #expect(edit.recipe.processVersion == process)
        #expect(edit.isWrittenByNewerVersion)
    }

    @Test func `the recipe is found by its namespace, whatever the prefix`() throws {
        let data = try Self.jpeg(withEdit: [("Recipe", #"{"version":3,"processVersion":7}"#)], prefix: "rl")
        let edit = try #require(EmbeddedEdit.read(data))
        #expect(edit.recipe.processVersion == 7)
        #expect(!edit.isWrittenByNewerVersion)
    }
}
