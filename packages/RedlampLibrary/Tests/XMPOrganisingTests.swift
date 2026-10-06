import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Other apps' XMP for the fields LIB-15 and LIB-22 added to the sidecar: a custom label, IPTC Core's
/// creator, copyright and location beside the title and caption, read and written in each app's
/// conventions with other languages and other apps' elements kept; an empty keyword list written as
/// none; and the signature the index keeps of a photo's two `.xmp`.
struct XMPOrganisingTests {
    /// What every form below says.
    static let fields = XMPFields(
        customLabel: "Second Look", title: "Ribeira", caption: "Boats on the Douro.", creator: "Ana Sousa; Rui Lopes",
        copyright: "© 2025 Ana Sousa",
        location: PhotoLocation(
            country: "Portugal",
            state: "Porto",
            city: "Porto",
            sublocation: "Ribeira",
            countryCode: "PT",
        ),
    )

    static func xmp(_ attributes: String, _ elements: String = "") throws -> XMPPacket {
        try #require(XMPPacket(Data(MetadataIndexTests.packet(attributes, elements).utf8)))
    }

    /// The fields as each app writes them: Adobe's apps put the location in attributes, Capture One and
    /// Photo Mechanic in elements, and some apps write a creator or a copyright as plain text or a bag.
    static let forms: [(app: String, attributes: String, elements: String)] = [
        (
            "Lightroom Classic and Bridge",
            #"xmp:Label="Second Look" photoshop:City="Porto" photoshop:State="Porto" photoshop:Country="Portugal" "#
                + #"Iptc4xmpCore:Location="Ribeira" Iptc4xmpCore:CountryCode="PT""#,
            """
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Ribeira</rdf:li></rdf:Alt></dc:title>
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Boats on the Douro.</rdf:li></rdf:Alt></dc:description>
            <dc:creator><rdf:Seq><rdf:li>Ana Sousa</rdf:li><rdf:li>Rui Lopes</rdf:li></rdf:Seq></dc:creator>
            <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© 2025 Ana Sousa</rdf:li></rdf:Alt></dc:rights>
            """,
        ),
        (
            "Capture One and Photo Mechanic",
            #"xmp:Label="Second Look""#,
            """
            <photoshop:City>Porto</photoshop:City><photoshop:State>Porto</photoshop:State>
            <photoshop:Country>Portugal</photoshop:Country><Iptc4xmpCore:Location>Ribeira</Iptc4xmpCore:Location>
            <Iptc4xmpCore:CountryCode>PT</Iptc4xmpCore:CountryCode>
            <dc:title><rdf:Alt><rdf:li xml:lang="pt-PT">Ribeira</rdf:li></rdf:Alt></dc:title>
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default"> Boats on the Douro. </rdf:li></rdf:Alt></dc:description>
            <dc:creator><rdf:Seq><rdf:li>Ana Sousa</rdf:li><rdf:li>Rui Lopes</rdf:li></rdf:Seq></dc:creator>
            <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© 2025 Ana Sousa</rdf:li></rdf:Alt></dc:rights>
            """,
        ),
        (
            "tools that write plain text and bags",
            #"xmp:Label="Second Look" dc:rights="© 2025 Ana Sousa" photoshop:City="Porto" photoshop:State="Porto" "#
                + #"photoshop:Country="Portugal" Iptc4xmpCore:Location="Ribeira" Iptc4xmpCore:CountryCode="PT""#,
            """
            <dc:title>Ribeira</dc:title><dc:description>Boats on the Douro.</dc:description>
            <dc:creator><rdf:Bag><rdf:li>Ana Sousa</rdf:li><rdf:li>Rui Lopes</rdf:li></rdf:Bag></dc:creator>
            """,
        ),
    ]

    @Test(arguments: forms)
    func `each field reads the same in each app's form`(app: String, attributes: String, elements: String) throws {
        let read = try XMPFieldMappingTests.read(Self.xmp(attributes, elements))
        for field in XMPField.allCases {
            #expect(read.same(field, as: Self.fields), "\(app): \(field) is \(read)")
        }
        #expect(read.customLabel == "Second Look" && read.label == nil)
    }

    @Test(arguments: forms)
    func `each field written over an app's own is read back, its form and everything else kept`(
        app: String, attributes: String, elements: String,
    ) throws {
        let own = try Self.xmp(
            attributes + #" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.35""#,
            elements + "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li></rdf:Seq></crs:ToneCurvePV2012>",
        )
        let changed = XMPFields(
            customLabel: "Client Pick", title: "Douro", caption: "Ferries at dusk.", creator: "Rui Lopes",
            copyright: "© 2026 Rui Lopes", location: PhotoLocation(country: "Portugal", city: "Gaia"),
        )
        let fields: Set<XMPField> = [.label, .title, .caption, .creator, .copyright, .location]
        let written = try XMPFieldMappingTests.write(changed, fields, into: own)
        let read = XMPFieldMappingTests.read(written)
        for field in fields {
            #expect(read.same(field, as: changed), "\(app): \(field) is \(read)")
        }
        #expect(written.text(XMPProperty("http://ns.adobe.com/camera-raw-settings/1.0/", "Exposure2012")) == "+0.35")
        #expect(written
            .items(XMPProperty("http://ns.adobe.com/camera-raw-settings/1.0/", "ToneCurvePV2012")) == ["0, 0"])
        #expect(!written.has(XMPNamespace.state) && !written.has(XMPNamespace.sublocation))
        #expect(!written.has(XMPNamespace.countryCode))
        // A creator written over a bag stays a bag; Redlamp's own are sequences.
        let kind = try #require(written.places(XMPNamespace.creator).first.flatMap { place -> XMPPacket.ArrayKind? in
            guard case let .element(id) = place else { return nil }
            return written.array(in: id)?.kind
        })
        #expect(kind == (elements.contains("rdf:Bag><rdf:li>Ana") ? .bag : .seq))
        // Nothing changes when the fields are as written.
        #expect(changed.changes(fields, to: written, conventions: XMPConventions(), now: XMPFieldMappingTests.now)
            .isEmpty)
    }

    @Test func `a title, caption or copyright in other languages keeps them`() throws {
        let title = """
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Tram</rdf:li><rdf:li xml:lang="pt-PT">Eléctrico</rdf:li></rdf:Alt></dc:title>
        <dc:rights><rdf:Alt><rdf:li xml:lang="pt-PT">© Ana Sousa</rdf:li></rdf:Alt></dc:rights>
        """
        let packet = try Self.xmp("", title)
        let renamed = try XMPFieldMappingTests.write(
            XMPFields(title: "Tram 28", copyright: "© 2026 Ana Sousa"),
            [.title, .copyright],
            into: packet,
        )
        #expect(XMPFieldMappingTests.read(renamed).title == "Tram 28")
        #expect(XMPFieldMappingTests.read(renamed).copyright == "© 2026 Ana Sousa")
        let text = String(decoding: renamed.data, as: UTF8.self)
        #expect(text.contains(#"<rdf:li xml:lang="pt-PT">Eléctrico</rdf:li>"#))
        #expect(text.contains(#"<rdf:li xml:lang="pt-PT">© Ana Sousa</rdf:li>"#))

        // Cleared, the default goes empty and the others stay: no title reads back, and Portuguese is kept.
        let cleared = try XMPFieldMappingTests.write(XMPFields(title: ""), [.title], into: renamed)
        #expect(XMPFieldMappingTests.read(cleared).title == nil)
        #expect(String(decoding: cleared.data, as: UTF8.self).contains(#"<rdf:li xml:lang="pt-PT">Eléctrico</rdf:li>"#))
        // A caption in the default language alone is removed whole.
        let captioned = try XMPFieldMappingTests.write(XMPFields(caption: "Ferries"), [.caption], into: packet)
        let uncaptioned = try XMPFieldMappingTests.write(XMPFields(), [.caption], into: captioned)
        #expect(!uncaptioned.has(XMPNamespace.description))
    }

    @Test func `the sidecar's empty keyword list is held, and the xmp written then carries none`() async throws {
        #expect(XMPFields(PhotoMetadata(keywords: [])).holds(.keywords))
        #expect(!XMPFields(PhotoMetadata()).holds(.keywords))
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.ARW")
        try sandbox.write("IMG_0001.xmp", OtherApps.lightroom(rating: 2, keywords: ["Places/Porto"]), modified: -600)
        try sandbox.sidecar("IMG_0001.ARW", PhotoMetadata(keywords: []))
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0001.ARW") == XMPIndexTests.Shown(rating: 2))

        let report = try await sandbox.sync(writing: true)
        let photo = try #require(report.photo("IMG_0001.ARW"))
        #expect(photo.written.contains(.keywords) && !photo.taken.contains(.keywords))
        let written = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0001.xmp"))))
        #expect(!written.has(XMPNamespace.subject) && !written.has(XMPNamespace.hierarchicalSubject))
        #expect(written.text(XMPNamespace.rating) == "2")
        #expect(sandbox.metadata("IMG_0001.ARW")?.keywords == [])
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0001.ARW") == XMPIndexTests.Shown(rating: 2))
    }

    @Test func `a change only the sidecar has keeps other apps' fields without reading the photo again`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0001.ARW")
        try sandbox.write("IMG_0001.xmp", MetadataIndexTests.otherApp, modified: -600)
        try sandbox.sidecar("IMG_0001.ARW", PhotoMetadata(caption: "Ours"))
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        func index() async {
            let run = await IndexerRun.collect(indexer.index([sandbox.root]))
            #expect(run.failures.isEmpty, "\(run.failures)")
        }
        await index()
        var expected = MetadataIndexTests.theirs
        expected.caption = "Ours"
        func shown() async throws -> XMPFields {
            try await LibraryIndexer.Run.fields(of: sandbox.row("IMG_0001.ARW"))
        }
        for field in XMPField.allCases where field != .keywords {
            #expect(try await shown().same(field, as: expected), "\(field)")
        }

        // A keyword added elsewhere: the .redlamp alone changed, and still leaves the other fields open.
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.keywords = ["Places/Porto"]
        sidecar.modified = Date()
        try SidecarStore().save(sidecar, for: photo)
        try sandbox.setModified("IMG_0001.ARW.redlamp", 60)
        await index()
        #expect(files.counts.reads[LibraryIndexer.path(photo)] == 1)
        for field in XMPField.allCases where field != .keywords {
            #expect(try await shown().same(field, as: expected), "\(field) after the sidecar changed")
        }
        #expect(try await sandbox.shown("IMG_0001.ARW").keywords == ["Places/Porto"])
        #expect(try await sandbox.row("IMG_0001.ARW").otherFields == XMPField.held.subtracting([
            .flag, .keywords, .caption,
        ]))

        // Its own caption cleared: the row's caption was the .redlamp's, so the photo is read again.
        sidecar.metadata?.caption = nil
        try SidecarStore().save(sidecar, for: photo)
        try sandbox.setModified("IMG_0001.ARW.redlamp", 120)
        await index()
        #expect(files.counts.reads[LibraryIndexer.path(photo)] == 2)
        #expect(try await shown().caption == "Boats on the Douro.")
    }

    @Test func `the signature changes whenever either xmp does, even when their dates' sum doesn't`() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func stamp(_ size: Int64, _ offset: TimeInterval) -> XMPFileStamp {
            XMPFileStamp(size: size, modified: now.addingTimeInterval(offset))
        }
        let both = XMPFileStamp.signature(shared: stamp(900, 0), darktable: stamp(1200, 60))
        let variants = [
            XMPFileStamp.signature(shared: stamp(900, 10), darktable: stamp(1200, 50)),
            XMPFileStamp.signature(shared: stamp(901, 0), darktable: stamp(1200, 60)),
            XMPFileStamp.signature(shared: stamp(900, 0), darktable: stamp(1199, 60)),
            XMPFileStamp.signature(shared: stamp(900, 0), darktable: nil),
            XMPFileStamp.signature(shared: nil, darktable: stamp(1200, 60)),
            XMPFileStamp.signature(shared: stamp(1200, 60), darktable: stamp(900, 0)),
        ]
        #expect(both != nil && !variants.contains(both))
        #expect(Set(variants).count == variants.count)
        #expect(XMPFileStamp.signature(shared: stamp(900, 0), darktable: stamp(1200, 60)) == both)
        #expect(XMPFileStamp.signature(shared: nil, darktable: nil) == nil)
    }

    @Test func `the index sees a change to either xmp that keeps their dates' sum`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0004.ARW")
        let shared = XMPIndexTests.packet(#"xmp:Rating="2""#)
        try sandbox.write("IMG_0004.xmp", shared, modified: -600)
        try sandbox.write("IMG_0004.ARW.xmp", XMPIndexTests.packet(#"xmp:Rating="5" xmp:Label="Red""#), modified: -500)
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0004.ARW") == XMPIndexTests.Shown(rating: 2, label: .red))
        let before = try await sandbox.row("IMG_0004.ARW")

        // darktable's changes, of the same size, and the shared one's date moves back as far.
        try sandbox.write("IMG_0004.ARW.xmp", XMPIndexTests.packet(#"xmp:Rating="5" xmp:Label="Blu""#), modified: -400)
        try sandbox.write("IMG_0004.xmp", shared, modified: -700)
        try await sandbox.indexAll()
        let after = try await sandbox.row("IMG_0004.ARW")
        #expect(after.xmpSignature != before.xmpSignature)
        #expect(try await sandbox.shown("IMG_0004.ARW") == XMPIndexTests.Shown(rating: 2))
        #expect(try await sandbox.row("IMG_0004.ARW").customLabel == "Blu")
    }
}
