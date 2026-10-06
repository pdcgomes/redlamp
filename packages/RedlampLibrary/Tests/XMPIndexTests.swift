import Foundation
import ImageIO
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The index shows other apps' metadata as `LibraryXMP` takes it: each app's conventions read by the
/// same code, field by field from the `.xmp`, darktable's own and the photo's own XMP, with the
/// `.redlamp`'s fields standing where it holds them.
struct XMPIndexTests {
    /// A photo's organising fields as the index shows them, or as `LibraryXMP` would leave them.
    struct Shown: Equatable, CustomStringConvertible {
        var rating = 0
        var flag: PhotoFlag?
        var label: ColorLabel?
        var keywords: Set<String> = []
        var title: String?
        var caption: String?

        init(
            rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil, keywords: Set<String> = [],
            title: String? = nil, caption: String? = nil,
        ) {
            self.rating = rating
            self.flag = flag
            self.label = label
            self.keywords = keywords
            self.title = title
            self.caption = caption
        }

        init(_ fields: XMPFields) {
            self.init(
                rating: fields.rating ?? 0, flag: fields.flag, label: fields.label, keywords: Set(fields.keywords),
                title: fields.title, caption: fields.caption,
            )
        }

        /// What `LibraryXMP` leaves: the `.redlamp`'s fields once merged, its title and caption other
        /// apps' until the `.redlamp` holds them (LIB-22).
        init(_ synced: XMPPhotoSync) {
            var fields = synced.other
            for field in XMPField.held {
                fields.take(field, from: synced.merged)
            }
            self.init(fields)
        }

        var description: String {
            "\(rating) stars, \(flag?.rawValue ?? "no flag"), \(label?.rawValue ?? "no label"), \(keywords.sorted()), "
                + "title \(title ?? "none"), caption \(caption ?? "none")"
        }
    }

    /// One app's `.xmp` for a photo, as it writes them.
    struct App: Sendable, CustomTestStringConvertible {
        let name: String
        /// Named after the photo's whole name, as darktable names its own (`IMG_0001.ARW.xmp`), rather
        /// than after its name without the extension (`IMG_0001.xmp`).
        var ownName = false
        let xmp: String
        var conventions = XMPConventions()
        /// What it says, as `LibraryXMP` reads it.
        let fields: XMPFields

        var testDescription: String {
            name
        }
    }

    static let apps: [App] = [
        App(
            name: "Lightroom Classic",
            xmp: packet(
                #"xmp:Rating="4" xmp:Label="Green" xmpDM:good="True""#,
                bag("lr:hierarchicalSubject", ["Places|Portugal|Lisbon", "Music|AC/DC"])
                    + bag("dc:subject", ["Places", "Portugal", "Lisbon", "Music", "AC/DC", "tram"])
                    + alt("dc:title", "Tram 28") + alt("dc:description", "The tram climbing to Graça."),
            ),
            fields: XMPFields(
                rating: 4, flag: .pick, label: .green, keywords: ["Places/Portugal/Lisbon", "Music/AC%2FDC", "tram"],
                title: "Tram 28", caption: "The tram climbing to Graça.",
            ),
        ),
        App(
            name: "Lightroom Classic, its label named in another language beside its colour",
            xmp: packet(#"xmp:Rating="2" xmp:Label="Grün" xmp:LabelColor="green""#),
            fields: XMPFields(rating: 2, label: .green),
        ),
        App(
            name: "Lightroom Classic's Review Status labels",
            xmp: packet(#"xmp:Label="Retouching Needed""#),
            fields: XMPFields(label: .blue),
        ),
        App(
            name: "Bridge",
            xmp: packet(#"xmp:Rating="-1" xmp:Label="Second""#, alt("dc:title", "Ferries")),
            fields: XMPFields(flag: .reject, label: .yellow, title: "Ferries"),
        ),
        App(
            name: "Capture One",
            xmp: packet(#"xmp:Rating="3" xmp:Label="Orange""#, bag("dc:subject", ["harbour", "dusk"])),
            fields: XMPFields(rating: 3, customLabel: "Orange", keywords: ["harbour", "dusk"]),
        ),
        App(
            name: "Photo Mechanic, with Urgency read as labels",
            xmp: packet(#"xmp:Rating="5" photoshop:Urgency="2""#),
            conventions: XMPConventions(urgency: true),
            fields: XMPFields(rating: 5, label: .red),
        ),
        App(
            name: "darktable",
            ownName: true,
            xmp: packet(
                #"xmp:Rating="1""#,
                seq("darktable:colorlabels", ["3"])
                    + bag("dc:subject", ["darktable|format|ARW", "gull"])
                    + bag("lr:hierarchicalSubject", ["darktable|format|ARW", "Birds|Gulls"]),
            ),
            fields: XMPFields(rating: 1, label: .blue, keywords: ["Birds/Gulls", "gull"]),
        ),
    ]

    @Test(arguments: apps)
    func `the index's rating, flag, label, keywords, title and caption are LibraryXMP's in each app's conventions`(
        _ app: App,
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try await sandbox.xmp.setSettings(XMPSettings(conventions: app.conventions))
        let photos = ["IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.ARW"]
        for photo in photos {
            try sandbox.photo(photo)
            try sandbox.write(app.ownName ? photo + ".xmp" : Self.shared(photo), app.xmp, modified: -600)
        }
        // An edit without organising fields, and one with a rating and a label of its own.
        try sandbox.sidecar("IMG_0002.ARW", PhotoMetadata())
        try sandbox.sidecar("IMG_0003.ARW", PhotoMetadata(rating: 1, label: .purple))
        try await sandbox.indexAll()

        let report = try await sandbox.sync(dryRun: true)
        for photo in photos {
            let synced = try #require(report.photo(photo))
            #expect(try await sandbox.shown(photo) == Shown(synced), "\(photo)")
        }
        #expect(try await sandbox.shown("IMG_0001.ARW") == Shown(app.fields))
        #expect(try await sandbox.shown("IMG_0002.ARW") == Shown(app.fields))
        var own = app.fields
        own.rating = 1
        own.label = .purple
        #expect(try await sandbox.shown("IMG_0003.ARW") == Shown(own))
    }

    @Test(arguments: apps)
    func `XMP in a photo, as ImageIO reads it, means what the same XMP means in an .xmp`(_ app: App) throws {
        let data = Data(app.xmp.utf8)
        let metadata = try #require(CGImageMetadataCreateFromXMPData(data as CFData))
        let embedded = XMPSource(packet: XMPImageProperties(metadata), conventions: app.conventions)
        #expect(embedded == XMPSource(xmp: data, conventions: app.conventions))
        #expect(embedded.fields == app.fields)
    }

    @Test func `a title in several languages reads its default, else its first, wherever it's read`() throws {
        let titles = [
            #"<rdf:li xml:lang="pt-PT">Eléctrico</rdf:li><rdf:li xml:lang="x-default">Tram</rdf:li>"#,
            #"<rdf:li xml:lang="pt-PT">Eléctrico</rdf:li><rdf:li xml:lang="en-GB">Tram</rdf:li>"#,
        ]
        for (title, expected) in zip(titles, ["Tram", "Eléctrico"]) {
            let data = Data(Self.packet("", "<dc:title><rdf:Alt>\(title)</rdf:Alt></dc:title>").utf8)
            let metadata = try #require(CGImageMetadataCreateFromXMPData(data as CFData))
            #expect(XMPSource(packet: XMPImageProperties(metadata), conventions: XMPConventions()).fields
                .title == expected)
            #expect(XMPSource(xmp: data)?.fields.title == expected)
        }
    }

    @Test func `an edited .redlamp without organising metadata no longer hides another app's rating`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0001.NEF")
        try sandbox.write("IMG_0001.xmp", OtherApps.lightroom(rating: 3, label: "Red"), modified: -600)
        try sandbox.sidecar("IMG_0001.NEF", PhotoMetadata())
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0001.NEF") == Shown(rating: 3, label: .red))
        #expect(try await sandbox.row("IMG_0001.NEF").edited)

        // Edited again: the .redlamp alone changed, and still holds no rating.
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.recipe[.exposure] = 0.7
        try SidecarStore().save(sidecar, for: photo)
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0001.NEF") == Shown(rating: 3, label: .red))

        // Rated in Redlamp: its rating stands, the other app's label still shows.
        sidecar.metadata = PhotoMetadata(rating: 5)
        try SidecarStore().save(sidecar, for: photo)
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0001.NEF") == Shown(rating: 5, label: .red))
    }

    @Test func `Bridge's and Review Status's labels, Lightroom's label colours and picks, and flat keywords are indexed`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let xmps = [
            ("A.CR3", Self.packet(#"xmp:Label="Approved""#)),
            ("B.CR3", Self.packet(#"xmp:Label="To Print""#)),
            ("C.CR3", Self.packet(#"xmp:Label="Rot" xmp:LabelColor="red""#)),
            ("D.CR3", Self.packet(#"xmp:Rating="2" xmpDM:good="True""#)),
            ("E.CR3", Self.packet("", Self.bag("dc:subject", ["harbour", "AC/DC"]))),
        ]
        for (photo, xmp) in xmps {
            try sandbox.photo(photo)
            try sandbox.write(Self.shared(photo), xmp)
        }
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("A.CR3") == Shown(label: .green))
        #expect(try await sandbox.shown("B.CR3") == Shown(label: .purple))
        #expect(try await sandbox.shown("C.CR3") == Shown(label: .red))
        #expect(try await sandbox.shown("D.CR3") == Shown(rating: 2, flag: .pick))
        #expect(try await sandbox.shown("E.CR3") == Shown(keywords: ["harbour", "AC%2FDC"]))
    }

    @Test func `a photo's name.xmp and darktable's name.ext.xmp are read together, and a change to either is seen`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0004.ARW")
        try sandbox.write(
            "IMG_0004.xmp", Self.packet(#"xmp:Rating="2""#, Self.bag("lr:hierarchicalSubject", ["Trips|Porto"])),
            modified: -600,
        )
        try sandbox.write(
            "IMG_0004.ARW.xmp", Self.packet(#"xmp:Rating="5""#, Self.seq("darktable:colorlabels", ["3"])),
            modified: -500,
        )
        let files = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
        func index() async {
            let run = await IndexerRun.collect(indexer.index([sandbox.root]))
            #expect(run.failures.isEmpty, "\(run.failures)")
        }
        await index()
        // The .xmp the photos of its name share first, then darktable's, field by field.
        #expect(try await sandbox.shown("IMG_0004.ARW") == Shown(rating: 2, label: .blue, keywords: ["Trips/Porto"]))
        let synced = try #require(try await sandbox.sync(dryRun: true).photo("IMG_0004.ARW"))
        #expect(try await sandbox.shown("IMG_0004.ARW") == Shown(synced))
        for name in ["IMG_0004.xmp", "IMG_0004.ARW.xmp"] {
            #expect(files.counts.reads[LibraryIndexer.path(sandbox.url(name))] == 1, "\(name)")
        }
        // Another photo in the folder: it's compared again, and the photo with both isn't read again.
        try sandbox.photo("IMG_0010.ARW")
        await index()
        #expect(files.counts.reads[LibraryIndexer.path(sandbox.url("IMG_0004.ARW"))] == 1)

        try sandbox.write(
            "IMG_0004.ARW.xmp", Self.packet(#"xmp:Rating="5""#, Self.seq("darktable:colorlabels", ["0"])),
            modified: -400,
        )
        await index()
        #expect(try await sandbox.shown("IMG_0004.ARW") == Shown(rating: 2, label: .red, keywords: ["Trips/Porto"]))

        try FileManager.default.removeItem(at: sandbox.url("IMG_0004.xmp"))
        await index()
        #expect(try await sandbox.shown("IMG_0004.ARW") == Shown(rating: 5, label: .red))

        try FileManager.default.removeItem(at: sandbox.url("IMG_0004.ARW.xmp"))
        await index()
        #expect(try await sandbox.shown("IMG_0004.ARW") == Shown())
        #expect(try await sandbox.row("IMG_0004.ARW").xmpModified == nil)
    }

    @Test func `Music|AC/DC in Lightroom's keyword paths is two levels, the second AC/DC`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0006.ARW")
        try sandbox.write(
            "IMG_0006.xmp", Self.packet("", Self.bag("lr:hierarchicalSubject", ["Music|AC/DC"])), modified: -600,
        )
        try await sandbox.indexAll()
        let id = try await sandbox.id("IMG_0006.ARW")
        #expect(try await sandbox.index.read { try $0.keywords(forPhoto: id) } == ["Music/AC%2FDC"])
        let keywords = try await sandbox.index.read { try $0.keywordCounts() }.keys
        #expect(Set(keywords.map(\.names)) == [["Music"], ["Music", "AC/DC"]])
    }

    @Test func `a photo's own XMP is read from the head read for the rest of it, as LibraryXMP reads it`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let xmp = CGImageMetadataCreateMutable()
        for (namespace, prefix) in [
            ("http://ns.adobe.com/lightroom/1.0/", "lr"), ("http://ns.adobe.com/xmp/1.0/DynamicMedia/", "xmpDM"),
        ] {
            #expect(CGImageMetadataRegisterNamespaceForPrefix(xmp, namespace as CFString, prefix as CFString, nil))
        }
        let values: [(String, CFTypeRef)] = [
            ("xmp:Rating", "3" as CFString),
            ("xmp:Label", "Approved" as CFString),
            ("xmpDM:good", "True" as CFString),
            ("lr:hierarchicalSubject", ["Places|Lisbon", "Music|AC/DC"] as CFArray),
            ("dc:subject", ["Lisbon", "tram"] as CFArray),
            ("dc:title", "Tram 28" as CFString),
        ]
        for (path, value) in values {
            #expect(CGImageMetadataSetValueWithPath(xmp, nil, path as CFString, value), "\(path)")
        }
        let jpeg = try PhotoMetadataReaderTests.encode(
            PhotoMetadataReaderTests.image(), properties: PhotoMetadataReaderTests.cameraProperties, xmp: xmp,
        )
        try jpeg.write(to: sandbox.url("IMG_0007.jpg"))
        // A .redlamp of edits alone, so that LibraryXMP reads the photo's own XMP.
        try sandbox.sidecar("IMG_0007.jpg", PhotoMetadata())
        let files = CountingFileSystem()
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty, "\(run.failures)")

        let expected = Shown(
            rating: 3, flag: .pick, label: .green, keywords: ["Places/Lisbon", "Music/AC%2FDC", "tram"],
            title: "Tram 28",
        )
        #expect(try await sandbox.shown("IMG_0007.jpg") == expected)
        #expect(try Shown(#require(XMPSource.embedded(in: sandbox.url("IMG_0007.jpg"))).fields) == expected)
        let synced = try #require(try await sandbox.sync(dryRun: true).photo("IMG_0007.jpg"))
        #expect(Shown(synced) == expected)
        #expect(files.counts.heads == 1)
        #expect(files.counts.reads[LibraryIndexer.path(sandbox.url("IMG_0007.jpg"))] == 1)
    }

    @Test func `once LibraryXMP has merged a photo, the index keeps what it decided`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0005.ARW")
        try sandbox.write("IMG_0005.xmp", OtherApps.lightroom(rating: 3), modified: -600)
        try sandbox.sidecar("IMG_0005.ARW", PhotoMetadata())
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0005.ARW").rating == 3)
        #expect(try await sandbox.sync().photo("IMG_0005.ARW")?.taken == [.rating])

        // Cleared in Redlamp; the .xmp still says 3, a change taken already.
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.rating = 0
        try SidecarStore().save(sidecar, for: photo)
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0005.ARW").rating == 0)
        #expect(try await sandbox.sync(dryRun: true).photo("IMG_0005.ARW")?.merged.rating == nil)

        // Rated again in Lightroom, later: its change is taken.
        try sandbox.write("IMG_0005.xmp", OtherApps.lightroom(rating: 5), modified: 60)
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0005.ARW").rating == 5)
        #expect(try await sandbox.sync(dryRun: true).photo("IMG_0005.ARW")?.merged.rating == 5)
    }

    @Test func `a .redlamp's empty keyword list is no keywords, and no list lets other apps' show`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let lists: [(String, [String]?)] = [("IMG_0008.ARW", []), ("IMG_0009.ARW", nil)]
        for (photo, keywords) in lists {
            try sandbox.photo(photo)
            try sandbox.write(
                Self.shared(photo), OtherApps.lightroom(rating: 2, keywords: ["Places/Porto"]), modified: -600,
            )
            try sandbox.sidecar(photo, PhotoMetadata(keywords: keywords))
        }
        try await sandbox.indexAll()
        #expect(try await sandbox.shown("IMG_0008.ARW") == Shown(rating: 2))
        #expect(try await sandbox.shown("IMG_0009.ARW") == Shown(rating: 2, keywords: ["Places/Porto"]))
    }
}

// MARK: - Writing other apps' XMP

extension XMPIndexTests {
    /// The `.xmp` the photos named like `photo` share: `IMG_0001.xmp` for `IMG_0001.ARW`.
    static func shared(_ photo: String) -> String {
        (photo as NSString).deletingPathExtension + ".xmp"
    }

    /// One description with `attributes` and `elements`, every namespace these tests use declared.
    static func packet(_ attributes: String, _ elements: String = "") -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmlns:darktable="http://darktable.sf.net/"
           \(attributes)>
           \(elements)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    static func bag(_ name: String, _ items: [String]) -> String {
        "<\(name)><rdf:Bag>" + items.map { "<rdf:li>\($0)</rdf:li>" }.joined() + "</rdf:Bag></\(name)>\n"
    }

    static func seq(_ name: String, _ items: [String]) -> String {
        "<\(name)><rdf:Seq>" + items.map { "<rdf:li>\($0)</rdf:li>" }.joined() + "</rdf:Seq></\(name)>\n"
    }

    static func alt(_ name: String, _ text: String) -> String {
        "<\(name)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(text)</rdf:li></rdf:Alt></\(name)>\n"
    }
}

extension XMPSandbox {
    func row(_ path: String) async throws -> PhotoRecord {
        let id = try await id(path)
        return try #require(try await index.read { try $0.photo(id: id) })
    }

    /// What the index shows of the photo at `path`.
    func shown(_ path: String) async throws -> XMPIndexTests.Shown {
        let row = try await row(path)
        let id = row.id
        let keywords = try await index.read { try $0.keywords(forPhoto: id) }
        return XMPIndexTests.Shown(
            rating: row.rating, flag: row.flag, label: row.label, keywords: Set(keywords), title: row.title,
            caption: row.caption,
        )
    }
}
