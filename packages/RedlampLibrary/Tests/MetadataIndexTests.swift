import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The index shows the organising fields the sidecar gained (LIB-15, LIB-22, LIB-23, LIB-28), merged
/// with other apps' as `LibraryXMP` merges them, and an index rebuilt from the sidecars has the same
/// collections and manual stacks.
struct MetadataIndexTests {
    static let lisbon = PhotoLocation(
        country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Graça", countryCode: "PT",
    )

    /// Another app's `.xmp` with every field: a custom label, IPTC Core's title, caption, creator,
    /// copyright and location.
    static let otherApp = packet(
        #"xmp:Rating="3" xmp:Label="Urgent" photoshop:City="Porto" photoshop:State="Porto" "#
            + #"photoshop:Country="Portugal" Iptc4xmpCore:CountryCode="PT""#,
        """
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Ribeira</rdf:li><rdf:li xml:lang="pt-PT">Ribeira à noite</rdf:li></rdf:Alt></dc:title>
        <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Boats on the Douro.</rdf:li></rdf:Alt></dc:description>
        <dc:creator><rdf:Seq><rdf:li>Ana Sousa</rdf:li><rdf:li>Rui Lopes</rdf:li></rdf:Seq></dc:creator>
        <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© 2025 Ana Sousa</rdf:li></rdf:Alt></dc:rights>
        <Iptc4xmpCore:Location>Ribeira</Iptc4xmpCore:Location>
        """,
    )

    static let theirs = XMPFields(
        rating: 3, customLabel: "Urgent", title: "Ribeira", caption: "Boats on the Douro.",
        creator: "Ana Sousa; Rui Lopes", copyright: "© 2025 Ana Sousa",
        location: PhotoLocation(
            country: "Portugal",
            state: "Porto",
            city: "Porto",
            sublocation: "Ribeira",
            countryCode: "PT",
        ),
    )

    @Test func `the index shows each field the sidecar holds`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.ARW")
        let stack = UUID()
        try sandbox.sidecar("IMG_0001.ARW", PhotoMetadata(
            rating: 2, customLabel: "Urgent", mark: true, title: "Tram 28", caption: "The tram climbing to Graça.",
            creator: "Ana Sousa;Rui Lopes", copyright: "© 2026 Ana Sousa", location: Self.lisbon,
            collections: ["Clients/Acme/Selects", "Best%2FWorst"], stack: PhotoStack(id: stack, top: true),
        ))
        try await sandbox.indexAll()

        let row = try await sandbox.row("IMG_0001.ARW")
        #expect(row.rating == 2 && row.label == nil && row.customLabel == "Urgent" && row.marked)
        #expect(row.title == "Tram 28" && row.caption == "The tram climbing to Graça.")
        #expect(row.creator == "Ana Sousa; Rui Lopes" && row.copyright == "© 2026 Ana Sousa")
        #expect(row.location == Self.lisbon && row.stack == PhotoStack(id: stack, top: true))
        #expect(row.otherFields.isEmpty)
        let id = row.id
        let (collections, kinds) = try await sandbox.index.read { reader in
            try (
                reader.collections(ofPhoto: id).map(\.text),
                reader.collections().values.map { ($0.path.text, $0.kind) },
            )
        }
        #expect(collections == ["Best%2FWorst", "Clients/Acme/Selects"])
        #expect(Dictionary(uniqueKeysWithValues: kinds) == [
            "Best%2FWorst": .collection, "Clients": .set, "Clients/Acme": .set, "Clients/Acme/Selects": .collection,
        ])
    }

    @Test func `each field is other apps' until the sidecar holds it, as LibraryXMP merges it`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photos = ["A.NEF", "B.NEF", "C.NEF", "D.NEF"]
        for photo in photos {
            try sandbox.photo(photo)
            try sandbox.write(XMPIndexTests.shared(photo), Self.otherApp, modified: -600)
        }
        try sandbox.sidecar("B.NEF", PhotoMetadata())
        try sandbox.sidecar("C.NEF", PhotoMetadata(
            label: .green, title: "Tram 28", creator: "Rui Lopes", location: PhotoLocation(city: "Lisbon"),
        ))
        try sandbox.sidecar("D.NEF", PhotoMetadata(title: "", copyright: "", location: PhotoLocation()))
        try await sandbox.indexAll()

        var own = Self.theirs
        own.label = .green
        own.customLabel = nil
        own.title = "Tram 28"
        own.creator = "Rui Lopes"
        own.location = PhotoLocation(city: "Lisbon")
        var cleared = Self.theirs
        cleared.title = nil
        cleared.copyright = nil
        cleared.location = nil
        let expected = ["A.NEF": Self.theirs, "B.NEF": Self.theirs, "C.NEF": own, "D.NEF": cleared]
        let report = try await sandbox.sync(dryRun: true)
        for photo in photos {
            let shown = try await LibraryIndexer.Run.fields(of: sandbox.row(photo))
            let synced = try #require(report.photo(photo)).merged
            for field in XMPField.allCases where field != .keywords {
                #expect(try shown.same(field, as: #require(expected[photo])), "\(photo) \(field): \(shown)")
                #expect(shown.same(field, as: synced), "\(photo) \(field) as LibraryXMP has it: \(synced)")
            }
        }
        #expect(try await sandbox.row("A.NEF").otherFields == Set(XMPField.allCases).subtracting([.keywords, .flag]))
        #expect(try await sandbox.row("C.NEF").otherFields == [.rating, .caption, .copyright])
    }

    @Test func `an index rebuilt from the sidecars has the same collections and manual stacks`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let id = UUID()
        for photo in ["Day 1/A.NEF", "Day 1/A.JPG", "Day 2/B.NEF", "Day 2/C.NEF", "Day 2/D.NEF"] {
            try sandbox.photo(photo)
        }
        for pair in ["Day 1/A.NEF", "Day 1/A.JPG"] {
            try sandbox.sidecar(
                pair,
                PhotoMetadata(collections: ["Portfolio/Best"], stack: PhotoStack(id: id, top: true)),
            )
        }
        try sandbox.sidecar("Day 2/B.NEF", PhotoMetadata(
            collections: ["Portfolio/Best", "Clients/Acme"], stack: PhotoStack(id: id),
        ))
        try sandbox.sidecar("Day 2/C.NEF", PhotoMetadata(stack: PhotoStack(top: true)))
        try await sandbox.indexAll()
        let first = try await Self.organisation(of: sandbox.index)
        #expect(first == [
            "Day 1/A.JPG": "Portfolio/Best; \(id.uuidString) top",
            "Day 1/A.NEF": "Portfolio/Best; \(id.uuidString) top",
            "Day 2/B.NEF": "Clients/Acme, Portfolio/Best; \(id.uuidString)", "Day 2/C.NEF": "; top",
            "Day 2/D.NEF": "; ",
        ])

        let library = try TemporaryFolder()
        let rebuilt = try await LibraryIndex.open(at: library.url.appending(path: "Index.sqlite"), readers: 2)
        defer { rebuilt.closeAndWait() }
        let run = await IndexerRun
            .collect(LibraryIndexer(index: rebuilt, configuration: .testing()).index([sandbox.root]))
        #expect(run.failures.isEmpty)
        #expect(try await Self.organisation(of: rebuilt) == first)

        for index in [sandbox.index, rebuilt] {
            let engine = QueryEngine(index: index)
            try await engine.load()
            let stacks = try await StackFinder.find(in: index, store: #require(engine.store))
            let names = try await index.read { reader in
                try stacks.photos(.manual).map { try $0.compactMap { try reader.photo(id: $0)?.name } }
            }
            #expect(names == [["A.NEF", "B.NEF"]])
        }
    }

    /// Each photo's collections and stack choice in `index`, by its path below the root: what a rebuild
    /// must find again, whatever IDs it gives the photos.
    static func organisation(of index: LibraryIndex) async throws -> [String: String] {
        try await index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            let choices = try StackChoices(reader)
            var found: [String: String] = [:]
            for (id, path) in try reader.photoPaths(ids) {
                let components = path.split(separator: "/").suffix(2).joined(separator: "/")
                let collections = try reader.collections(ofPhoto: id).map(\.text).joined(separator: ", ")
                let choice = choices[id].map { [$0.id?.uuidString, $0.top ? "top" : nil].compactMap(\.self) } ?? []
                found[components] = collections + "; " + choice.joined(separator: " ")
            }
            return found
        }
    }

    /// One description with `attributes` and `elements`, the namespaces of every field declared.
    static func packet(_ attributes: String, _ elements: String = "") -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
           \(attributes)>
           \(elements)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }
}
