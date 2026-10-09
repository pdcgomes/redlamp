import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Reads a file's ImageIO properties, as the decode service does for the app's exports.
private struct ImageIOFiles: FileInspecting {
    func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
        urls.map { _ in nil }
    }

    func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
        urls.map { _ in nil }
    }

    func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        urls.map { url in
            CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                .flatMap(ImageProperties.init)
        }
    }

    func haldImage(of _: URL) -> HaldImage? {
        nil
    }

    func embeddedMattes(in _: URL) -> Set<EmbeddedMatte> {
        []
    }

    func embeddedMatte(_: EmbeddedMatte, in _: URL) -> EmbeddedMatteImage? {
        nil
    }
}

/// What exports carry of a photo's own (LIB-22, LIB-21): its keywords as `Keywords.json` says each is
/// exported, and its fields as the library shows them, merged from its `.redlamp` and other apps'.
struct MetadataExportTests {
    static let definitions = KeywordDefinitions(keywords: [
        kw("Places"): KeywordOptions(isCategory: true),
        kw("Places/Portugal"): KeywordOptions(synonyms: ["PT"], exportSynonyms: false),
        kw("Places/Portugal/Lisbon"): KeywordOptions(synonyms: ["Lisboa"]),
        kw("Clients"): KeywordOptions(isPrivate: true),
        kw("People/Ana"): KeywordOptions(exportContainingKeywords: false, isPerson: true),
        kw("Draft"): KeywordOptions(includeOnExport: false),
        kw("Gear/Lenses"): KeywordOptions(includeOnExport: false),
    ])

    static let keywords = [
        "Places/Portugal/Lisbon", "Clients/Acme/Invoices", "People/Ana", "Draft", "Gear/Lenses/50mm", "Music/AC%2FDC",
    ]

    /// The XMP another app leaves beside a photo, giving it a caption.
    static let bridge = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Written in Bridge</rdf:li></rdf:Alt></dc:description>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// An export of `photo` with `fields`, as the app writes one, read back with ImageIO.
    static func export(_ photo: URL, fields: ExportMetadata.Fields?) throws -> (Data, [CFString: Any]) {
        let folder = try TemporaryFolder()
        var settings = ExportSettings()
        settings.destinationFolder = folder.url
        let url = ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles())
        let metadata = ExportMetadata.properties(
            from: photo, reading: ImageIOFiles(), policy: .all, recipe: EditRecipe(), fields: fields,
        )
        try ImageExporter.write(
            PhotoMetadataReaderTests.image(width: 16, height: 12), to: url, settings: settings, metadata: metadata,
            source: photo, reading: ImageIOFiles(),
        )
        let data = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (data, #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]))
    }

    /// The items of `name` (`lr:hierarchicalSubject`) in the XMP the file holds.
    static func items(_ name: String, in data: Data) throws -> [String] {
        guard let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8), in: start.lowerBound ..< data.endIndex),
              let metadata = CGImageMetadataCreateFromXMPData(data[start.lowerBound ..< end.upperBound] as CFData),
              let tag = CGImageMetadataCopyTagWithPath(metadata, nil, name as CFString)
        else { return [] }
        let value = CGImageMetadataTagCopyValue(tag)
        return (value as? [CGImageMetadataTag])?.compactMap { CGImageMetadataTagCopyValue($0) as? String }
            ?? (value as? String).map { [$0] } ?? []
    }

    // MARK: - Keywords

    @Test func `keywords are exported as Keywords.json's flags and synonyms say, as Lightroom Classic exports them`() {
        let keywords = KeywordPath.paths(Self.keywords)
        let exported = Self.definitions.exported(keywords)
        #expect(exported.names == ["Lisbon", "Lisboa", "Portugal", "Ana", "50mm", "Gear", "AC/DC", "Music"])
        #expect(exported.paths == [kw("Portugal/Lisbon"), kw("People/Ana"), kw("Gear/50mm"), kw("Music/AC%2FDC")])
        #expect(Self.definitions.exported(keywords, people: false).names == [
            "Lisbon", "Lisboa", "Portugal", "50mm", "Gear", "AC/DC", "Music",
        ])
        let counts = Dictionary(uniqueKeysWithValues: keywords.map { ($0, KeywordCount(photos: 1, count: 1)) })
        #expect(KeywordList(counts: counts, definitions: Self.definitions).exported(keywords) == exported)
        #expect(KeywordDefinitions().exported([kw("Places/Portugal/Lisbon")]).names == ["Lisbon", "Places", "Portugal"])
    }

    @Test func `a photo's keywords go into its export flat and as Lightroom's paths, as their flags say`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 08:30:00")
        try sandbox.sidecar("A.JPG", PhotoMetadata(keywords: Self.keywords))
        try FileManager.default.createDirectory(at: sandbox.paths.definitions, withIntermediateDirectories: true)
        try Self.definitions.save(to: KeywordDefinitions.url(in: sandbox.paths))
        try await sandbox.indexAll()
        let id = try await sandbox.id("A.JPG")
        let exported = try await sandbox.keywords().exported(ofPhoto: id)
        #expect(exported == Self.definitions.exported(KeywordPath.paths(Self.keywords).sorted()), "by path")

        let fields = try #require(try await LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
            .exportFields(for: sandbox.url("A.JPG")))
        let (data, properties) = try Self.export(sandbox.url("A.JPG"), fields: fields)
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == exported.names)
        #expect(try Self.items("dc:subject", in: data) == exported.names)
        #expect(try Self.items("lr:hierarchicalSubject", in: data) == [
            "Gear|50mm", "Music|AC/DC", "People|Ana", "Portugal|Lisbon",
        ])
    }

    // MARK: - Fields

    @Test func `an export's fields are the photo's as the library shows them, other apps' merged in`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 08:30:00", offset: "+01:00")
        try sandbox.sidecar("A.JPG", PhotoMetadata(
            rating: 4, flag: .pick, label: .green, keywords: ["Places/Portugal/Lisbon"], mark: true,
            title: "Tram 28", creator: "Pedro Gomes;  Ana Lima ", copyright: "© 2024 Pedro Gomes",
            location: PhotoLocation(country: "Portugal", city: "Lisbon", sublocation: "Graça", countryCode: "PT"),
        ))
        try Data(Self.bridge.utf8).write(to: sandbox.url("A.xmp"))
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)

        let fields = try #require(try await metadata.exportFields(for: sandbox.url("A.JPG")))
        #expect(fields == ExportMetadata.Fields(
            title: "Tram 28", caption: "Written in Bridge", creators: ["Pedro Gomes", "Ana Lima"],
            copyright: "© 2024 Pedro Gomes",
            location: PhotoLocation(country: "Portugal", city: "Lisbon", sublocation: "Graça", countryCode: "PT"),
            keywords: ["Lisbon", "Places", "Portugal"], keywordPaths: [["Places", "Portugal", "Lisbon"]], rating: 4,
            label: "Green",
        ))
        try await LibraryXMP(index: sandbox.index)
            .setSettings(XMPSettings(conventions: XMPConventions(labels: .bridge)))
        #expect(try await metadata.exportFields(for: sandbox.url("A.JPG"))?.label == "Approved")
        #expect(try await metadata.exportFields(for: sandbox.url("Missing.JPG")) == nil)

        let (data, properties) = try Self.export(sandbox.url("A.JPG"), fields: fields)
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == "Written in Bridge")
        #expect(iptc?[kCGImagePropertyIPTCStarRating] as? Int == 4)
        #expect(try Self.items("xmp:Label", in: data) == ["Green"])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:06:01 08:30:00", "the camera's")
    }

    @Test func `a shifted capture time, or the camera given a zone, goes into the export`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.shot("A.JPG", at: "2024:06:01 23:30:00", subsec: "25", offset: "+01:00")
        try sandbox.shot("B.JPG", at: "2024:06:01 23:30:00")
        try await sandbox.indexAll()
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let (a, b) = try await (sandbox.id("A.JPG"), sandbox.id("B.JPG"))
        #expect(try await metadata.exportFields(ofPhoto: a)?.captured == nil)

        try await metadata.apply(.shift([a, b], by: 5400))
        #expect(try await metadata.exportFields(ofPhoto: a)?.captured == ExportMetadata.CaptureTime(
            time: cameraClock("2024-06-02 01:00:00", plus: 0.25), offset: 3600,
        ))
        #expect(try await metadata.exportFields(ofPhoto: b)?.captured == ExportMetadata.CaptureTime(
            time: cameraClock("2024-06-02 01:00:00"),
        ))
        let (data, properties) = try await Self.export(
            sandbox.url("A.JPG"), fields: metadata.exportFields(ofPhoto: a),
        )
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:06:02 01:00:00")
        #expect(exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+01:00")
        #expect(try Self.items("photoshop:DateCreated", in: data) == ["2024-06-02T01:00:00.25+01:00"])

        try await metadata.apply(.zone([b], offset: -4 * 3600))
        #expect(try await metadata.exportFields(ofPhoto: b)?.captured == ExportMetadata.CaptureTime(
            time: cameraClock("2024-06-02 01:00:00"), offset: -4 * 3600,
        ))
        try await metadata.apply(.shift([a], by: -5400))
        #expect(try await metadata.exportFields(ofPhoto: a)?.captured == nil)
    }
}
