import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// Exports carry the photo's own fields (LIB-22, LIB-21) in IPTC and in XMP, in place of what the source
/// says of them, under each metadata policy, beside the camera's fields and the embedded edit.
struct ExportFieldsTests {
    static let fields = ExportMetadata.Fields(
        title: "Tram 28 at dusk", caption: "The tram climbing to Graça.", creators: ["Pedro Gomes", "Ana Lima"],
        copyright: "© 2026 Pedro Gomes",
        location: PhotoLocation(
            country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Graça", countryCode: "PT",
        ),
        keywords: ["Lisbon", "Lisboa", "Portugal", "tram"], keywordPaths: [["Portugal", "Lisbon"], ["tram"]],
        rating: 5, label: "Green",
    )

    /// An export in `format` of `source` (`EmbeddedEditTests.source` when nil) with its edit and `fields`
    /// under `policy`, written to a file and read back.
    static func export(
        _ format: ExportFormat, policy: ExportMetadataPolicy = .all, fields: ExportMetadata.Fields? = fields,
        recipe: EditRecipe? = EmbeddedEditTests.recipe, source: URL? = nil,
    ) throws -> Data {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let source = try source ?? EmbeddedEditTests.source(in: folder)
        var settings = ExportSettings()
        settings.setFormat(format)
        settings.destinationFolder = folder
        let url = ExportDestination.url(for: source, settings: settings, reading: ImageIOFiles())
        let metadata = ExportMetadata.properties(
            from: source, reading: ImageIOFiles(), policy: policy, recipe: recipe, fields: fields,
        )
        try ImageExporter.write(
            ExportWriterTests.image(),
            to: url,
            settings: settings,
            metadata: metadata,
            source: source,
            reading: ImageIOFiles(),
        )
        return try Data(contentsOf: url)
    }

    static func dictionary(_ key: CFString, of data: Data) throws -> [CFString: Any] {
        try ExportWriterTests.properties(data)[key] as? [CFString: Any] ?? [:]
    }

    /// The XMP packet the file holds, as it was written: each top-level property by `prefix:name`, with
    /// its text or its items' (a language alternative's default first).
    static func packet(_ data: Data) throws -> [String: [String]] {
        guard let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8), in: start.lowerBound ..< data.endIndex)
        else { return [:] }
        let metadata =
            try #require(CGImageMetadataCreateFromXMPData(data[start.lowerBound ..< end.upperBound] as CFData))
        var properties: [String: [String]] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            let name = "\(CGImageMetadataTagCopyPrefix(tag) ?? "" as CFString):\(CGImageMetadataTagCopyName(tag) ?? "" as CFString)"
            let value = CGImageMetadataTagCopyValue(tag)
            if let text = value as? String {
                properties[name] = [text]
            } else if let items = value as? [CGImageMetadataTag] {
                properties[name] = items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
            }
            return true
        }
        return properties
    }

    /// A camera JPEG taken at noon by its clock in UTC+01:00, a quarter of a second in.
    static func shot(in folder: URL) throws -> URL {
        let url = folder.appending(path: "IMG_0002.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
                kCGImagePropertyExifSubsecTimeOriginal: "25",
                kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
                kCGImagePropertyExifFNumber: 2.8,
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon", kCGImagePropertyTIFFModel: "Z 8"],
        ]
        CGImageDestinationAddImage(
            destination,
            ExportWriterTests.image(width: 64, height: 48),
            properties as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// `2026-10-01 13:30:00` by a camera's clock, as the library keeps it: read as UTC.
    static func clock(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try #require(formatter.date(from: text))
    }

    // MARK: - Under each policy

    @Test(arguments: ExportFormat.allCases)
    func `exporting All carries every field in IPTC and XMP, beside the edit`(format: ExportFormat) throws {
        let data = try Self.export(format)
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
        #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Tram 28 at dusk")
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == "The tram climbing to Graça.")
        #expect(iptc[kCGImagePropertyIPTCByline] as? [String] == ["Pedro Gomes", "Ana Lima"])
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String == "© 2026 Pedro Gomes")
        #expect(iptc[kCGImagePropertyIPTCSubLocation] as? String == "Graça")
        #expect(iptc[kCGImagePropertyIPTCCity] as? String == "Lisbon")
        #expect(iptc[kCGImagePropertyIPTCProvinceState] as? String == "Lisboa")
        #expect(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName] as? String == "Portugal")
        #expect(iptc[kCGImagePropertyIPTCCountryPrimaryLocationCode] as? String == "PT")
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["Lisbon", "Lisboa", "Portugal", "tram"])
        #expect(iptc[kCGImagePropertyIPTCStarRating] as? Int == 5)

        let packet = try Self.packet(data)
        #expect(packet["dc:title"] == ["Tram 28 at dusk"])
        #expect(packet["dc:description"] == ["The tram climbing to Graça."])
        #expect(packet["dc:creator"] == ["Pedro Gomes", "Ana Lima"])
        #expect(packet["dc:rights"] == ["© 2026 Pedro Gomes"])
        #expect(packet["Iptc4xmpCore:Location"] == ["Graça"])
        #expect(packet["photoshop:City"] == ["Lisbon"])
        #expect(packet["photoshop:State"] == ["Lisboa"])
        #expect(packet["photoshop:Country"] == ["Portugal"])
        #expect(packet["Iptc4xmpCore:CountryCode"] == ["PT"])
        #expect(packet["dc:subject"] == ["Lisbon", "Lisboa", "Portugal", "tram"])
        #expect(packet["lr:hierarchicalSubject"] == ["Portugal|Lisbon", "tram"])
        #expect(packet["xmp:Rating"] == ["5"])
        #expect(packet["xmp:Label"] == ["Green"])
        #expect(EmbeddedEdit.read(data)?.recipe == EmbeddedEditTests.recipe)

        let tiff = try Self.dictionary(kCGImagePropertyTIFFDictionary, of: data)
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "Z 8")
        #expect(tiff[kCGImagePropertyTIFFSoftware] as? String == "Redlamp")
    }

    @Test(arguments: ExportFormat.allCases)
    func `exporting All Except Location leaves out the location fields as it leaves out GPS`(
        format: ExportFormat,
    ) throws {
        let data = try Self.export(format, policy: .allExceptLocation)
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
        for key in [
            kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        ] {
            #expect(iptc[key] == nil, "\(key)")
        }
        #expect(try ExportWriterTests.properties(data)[kCGImagePropertyGPSDictionary] == nil)
        let packet = try Self.packet(data)
        for name in ["Iptc4xmpCore:Location", "photoshop:City", "photoshop:State", "photoshop:Country"] {
            #expect(packet[name] == nil, "\(name)")
        }
        #expect(packet["Iptc4xmpCore:CountryCode"] == nil)
        #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Tram 28 at dusk")
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["Lisbon", "Lisboa", "Portugal", "tram"])
        #expect(packet["lr:hierarchicalSubject"] == ["Portugal|Lisbon", "tram"])
        #expect(packet["xmp:Label"] == ["Green"])
        #expect(EmbeddedEdit.read(data)?.recipe == EmbeddedEditTests.recipe)
    }

    @Test(arguments: ExportFormat.allCases)
    func `exporting None writes none of the fields`(format: ExportFormat) throws {
        let data = try Self.export(format, policy: .none)
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
        #expect(iptc[kCGImagePropertyIPTCObjectName] == nil)
        #expect(iptc[kCGImagePropertyIPTCKeywords] == nil)
        #expect(iptc[kCGImagePropertyIPTCCity] == nil)
        let packet = try Self.packet(data)
        for name in ["dc:title", "dc:subject", "lr:hierarchicalSubject", "xmp:Label", "xmp:Rating", "dc:rights"] {
            #expect(packet[name] == nil, "\(name)")
        }
        let tiff = try Self.dictionary(kCGImagePropertyTIFFDictionary, of: data)
        #expect(tiff[kCGImagePropertyTIFFArtist] == nil && tiff[kCGImagePropertyTIFFCopyright] == nil)
        #expect(EmbeddedEdit.read(data) == nil)
    }

    // MARK: - In place of the source's

    @Test(arguments: ExportFormat.allCases)
    func `the photo's fields take the place of the source's, and none of them takes it away`(
        format: ExportFormat,
    ) throws {
        var fields = Self.fields
        fields.location = nil
        fields.rating = nil
        fields.caption = ""
        let data = try Self.export(format, fields: fields)
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
        #expect(iptc[kCGImagePropertyIPTCCity] == nil, "the source's Lisbon")
        #expect(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName] == nil, "the source's Portugal")
        #expect(iptc[kCGImagePropertyIPTCStarRating] == nil, "the source's 4 stars")
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] == nil)
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["Lisbon", "Lisboa", "Portugal", "tram"])
        let packet = try Self.packet(data)
        #expect(packet["xmp:Rating"] == nil && packet["photoshop:City"] == nil && packet["dc:description"] == nil)
        #expect(!(packet["dc:subject"] ?? []).contains("harbour"))
    }

    /// EXIF's Artist, Copyright and ImageDescription are where ImageIO reads a creator, copyright and
    /// caption first, and it writes `dc:rights` over EXIF's Copyright.
    @Test(arguments: ExportFormat.allCases)
    func `EXIF's creator, copyright and caption follow the photo's`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let source = try EmbeddedEditTests.source(in: folder, exifCopyright: "© Someone else")
        let data = try Self.export(format, source: source)
        let tiff = try Self.dictionary(kCGImagePropertyTIFFDictionary, of: data)
        #expect(tiff[kCGImagePropertyTIFFCopyright] as? String == "© 2026 Pedro Gomes")
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String == "© 2026 Pedro Gomes")
        #expect(iptc[kCGImagePropertyIPTCByline] as? [String] == ["Pedro Gomes", "Ana Lima"])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == "The tram climbing to Graça.")
        if format == .tiff || format == .heic || format == .avif {
            #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Pedro Gomes; Ana Lima")
            #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == "The tram climbing to Graça.")
        }
        #expect(try Self.packet(data)["dc:rights"] == ["© 2026 Pedro Gomes"])
    }

    // MARK: - Beside the camera's fields and the edit

    @Test(arguments: ExportFormat.allCases)
    func `the camera's fields read back as they do without the photo's`(format: ExportFormat) throws {
        let with = try ExportWriterTests.properties(Self.export(format))
        let without = try ExportWriterTests.properties(Self.export(format, fields: nil))
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary] {
            #expect(
                (with[key] as? NSDictionary) == (without[key] as? NSDictionary), "\(key)",
            )
        }
        let tiff = { (properties: [CFString: Any]) in properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] }
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware] {
            #expect(tiff(with)?[key] as? String == tiff(without)?[key] as? String, "\(key)")
        }
    }

    @Test(.enabled(if: !EmbeddedEditTests.rawFixtures.isEmpty))
    func `camera metadata from raw files comes through with the photo's fields and the edit`() throws {
        for raw in EmbeddedEditTests.rawFixtures {
            for format in ExportFormat.allCases {
                let with = try Self.export(format, source: raw)
                let without = try Self.export(format, fields: nil, source: raw)
                let label = "\(raw.lastPathComponent) \(format)"
                #expect(EmbeddedEdit.read(with)?.recipe == EmbeddedEditTests.recipe, "\(label)")
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary] {
                    #expect(
                        try (ExportWriterTests.properties(with)[key] as? NSDictionary)
                            == (ExportWriterTests.properties(without)[key] as? NSDictionary),
                        "\(label) \(key)",
                    )
                }
                #expect(try Self.packet(with)["lr:hierarchicalSubject"] == ["Portugal|Lisbon", "tram"], "\(label)")
                let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: with)
                #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Tram 28 at dusk", "\(label)")
            }
        }
    }

    // MARK: - The capture time

    @Test(arguments: ExportFormat.allCases)
    func `a shifted capture time is the export's EXIF and XMP capture time`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        var fields = Self.fields
        fields.captured = try ExportMetadata.CaptureTime(time: Self.clock("2026-10-01 13:30:00"), offset: 7200)
        let data = try Self.export(format, fields: fields, source: Self.shot(in: folder))
        let exif = try Self.dictionary(kCGImagePropertyExifDictionary, of: data)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:01 13:30:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+02:00")
        #expect(exif[kCGImagePropertyExifSubsecTimeOriginal] as? String == "25")
        #expect(exif[kCGImagePropertyExifFNumber] as? Double == 2.8)
        let packet = try Self.packet(data)
        #expect(packet["photoshop:DateCreated"] == ["2026-10-01T13:30:00.25+02:00"])
        if format == .png {
            #expect(packet["exif:DateTimeOriginal"] == ["2026-10-01T13:30:00.25+02:00"])
        }
        if format == .jpeg || format == .tiff {
            let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: data)
            #expect(iptc[kCGImagePropertyIPTCDateCreated] as? String == "20261001")
        }
        #expect(EmbeddedEdit.read(data)?.recipe == EmbeddedEditTests.recipe)
    }

    @Test(arguments: ExportFormat.allCases)
    func `without a shift the camera's capture time stands`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let data = try Self.export(format, source: Self.shot(in: folder))
        let exif = try Self.dictionary(kCGImagePropertyExifDictionary, of: data)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:01 12:00:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+01:00")
    }

    @Test func `a zone west of UTC, and none, are written as EXIF, IPTC and XMP write them`() throws {
        let time = try Self.clock("2026-01-31 23:05:09")
        let west = ExportMetadata.CaptureTime(time: time, offset: -(3 * 3600 + 30 * 60))
        #expect(west.exifTime == "2026:01:31 23:05:09" && west.exifOffset == "-03:30")
        #expect(west.iptcDate == "20260131" && west.iptcTime == "230509-0330")
        #expect(west.xmpTime(subseconds: nil) == "2026-01-31T23:05:09-03:30")
        let unknown = ExportMetadata.CaptureTime(time: time)
        #expect(unknown.exifOffset == nil && unknown.iptcTime == "230509")
        #expect(unknown.xmpTime(subseconds: "5 ") == "2026-01-31T23:05:09.5")
        #expect(unknown.xmpTime(subseconds: "x") == "2026-01-31T23:05:09")
    }

    // MARK: - Without fields

    @Test(arguments: ExportFormat.allCases, ExportMetadataPolicy.allCases)
    func `an export without fields is as it was`(format: ExportFormat, policy: ExportMetadataPolicy) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let source = try EmbeddedEditTests.source(in: folder)
        let before = ExportMetadata.properties(
            from: source, reading: ImageIOFiles(), policy: policy, recipe: EmbeddedEditTests.recipe,
        )
        let after = ExportMetadata.properties(
            from: source, reading: ImageIOFiles(), policy: policy, recipe: EmbeddedEditTests.recipe, fields: nil,
        )
        #expect(NSDictionary(dictionary: before) == NSDictionary(dictionary: after))
        #expect(before[ExportMetadata.Fields.propertyKey] == nil)
        var settings = ExportSettings()
        settings.setFormat(format)
        let image = ExportWriterTests.image()
        let was = try ImageExporter.encode(image, settings: settings, metadata: before)
        let now = try ImageExporter.encode(image, settings: settings, metadata: after)
        #expect(try EmbeddedEditTests.properties(was) == EmbeddedEditTests.properties(now))
        #expect(try Self.packet(was) == Self.packet(now))
        let iptc = try Self.dictionary(kCGImagePropertyIPTCDictionary, of: now)
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == (policy == .none ? nil : ["harbour", "dusk"]))
    }
}
