import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Keywords shared with other apps: their keywords merged into sidecars, and the sidecars' written to
/// `.xmp` when writing is on.
struct KeywordXMPTests {
    /// Lightroom's paths and flat keywords, a slash inside a keyword's name as it is.
    static func xmp(paths: [String], flat: [String]) -> String {
        let items = { (values: [String]) in values.map { "     <rdf:li>\($0)</rdf:li>" }.joined(separator: "\n") }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
           xmp:Rating="0">
           <dc:subject>
            <rdf:Bag>
        \(items(flat))
            </rdf:Bag>
           </dc:subject>
           <lr:hierarchicalSubject>
            <rdf:Bag>
        \(items(paths))
            </rdf:Bag>
           </lr:hierarchicalSubject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    @Test func `other apps' keywords merge into a sidecar that holds none, and the index follows`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.CR3")
        try sandbox.write(
            "IMG_0001.xmp",
            Self.xmp(
                paths: ["Places|Portugal|Lisbon", "Music|AC/DC"],
                flat: ["Places", "Portugal", "Lisbon", "AC/DC", "tram"],
            ),
            modified: -600,
        )
        try sandbox.sidecar("IMG_0001.CR3", PhotoMetadata(rating: 2))
        try await sandbox.indexAll()
        let report = try await sandbox.sync()
        #expect(report.photo("IMG_0001.CR3")?.taken == [.keywords])
        #expect(sandbox.metadata("IMG_0001.CR3")?.keywords == ["Places/Portugal/Lisbon", "Music/AC%2FDC", "tram"])
        #expect(sandbox.metadata("IMG_0001.CR3")?.rating == 2)
        let id = try await sandbox.id("IMG_0001.CR3")
        #expect(try await sandbox.index.read { try $0.keywords(forPhoto: id) } == [
            "Music/AC%2FDC", "Places/Portugal/Lisbon", "tram",
        ])

        // Later, the other app adds one, and it's taken.
        try sandbox.write(
            "IMG_0001.xmp", Self.xmp(paths: ["Places|Portugal|Lisbon", "Music|AC/DC", "Birds|Gulls"], flat: ["tram"]),
            modified: 60,
        )
        _ = try await sandbox.sync()
        #expect(sandbox.metadata("IMG_0001.CR3")?.keywords?.sorted() == [
            "Birds/Gulls", "Music/AC%2FDC", "Places/Portugal/Lisbon", "tram",
        ])
        // A sidecar that holds keywords keeps them the first time: they're Redlamp's to decide.
        try sandbox.photo("IMG_0002.CR3")
        try sandbox.write("IMG_0002.xmp", Self.xmp(paths: ["Theirs"], flat: []), modified: -600)
        try sandbox.sidecar("IMG_0002.CR3", PhotoMetadata(keywords: ["Mine"]))
        try await sandbox.indexAll()
        _ = try await sandbox.sync()
        #expect(sandbox.metadata("IMG_0002.CR3")?.keywords == ["Mine"])
    }

    @Test func `a sidecar's keywords go to the xmp Redlamp writes, as Lightroom's paths and flat names`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0003.ARW")
        try sandbox.sidecar(
            "IMG_0003.ARW", PhotoMetadata(rating: 3, keywords: ["Places/Portugal/Lisbon", "Music/AC%2FDC", "Places"]),
        )
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let report = try await sandbox.sync()
        #expect(report.photo("IMG_0003.ARW")?.written.contains(.keywords) == true)
        let packet = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0003.xmp"))))
        #expect(packet.items(XMPNamespace.hierarchicalSubject) == ["Places|Portugal|Lisbon", "Music|AC/DC", "Places"])
        #expect(packet.items(XMPNamespace.subject) == ["Places", "Portugal", "Lisbon", "Music", "AC/DC"])
        #expect(try XMPSource(xmp: Data(contentsOf: sandbox.url("IMG_0003.xmp")))?.fields.keywords.sorted() == [
            "Music/AC%2FDC", "Places", "Places/Portugal/Lisbon",
        ])

        // Taken off in Redlamp, they come off the xmp.
        var sidecar = try #require(SidecarStore().load(for: sandbox.url("IMG_0003.ARW")))
        sidecar.metadata?.keywords = ["Places"]
        try SidecarStore().save(sidecar, for: sandbox.url("IMG_0003.ARW"))
        _ = try await sandbox.sync()
        let rewritten = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0003.xmp"))))
        #expect(rewritten.items(XMPNamespace.hierarchicalSubject) == ["Places"])
    }

    @Test func `exports carry each keyword as its options say`() {
        let counts: [KeywordPath: KeywordCount] = [
            kw("Places/Portugal/Lisbon"): KeywordCount(photos: 1, count: 1),
            kw("Clients/Acme/Invoices"): KeywordCount(photos: 1, count: 1),
            kw("People/Ana"): KeywordCount(photos: 1, count: 1),
            kw("Draft"): KeywordCount(photos: 1, count: 1),
        ]
        let definitions = KeywordDefinitions(keywords: [
            kw("Places"): KeywordOptions(isCategory: true),
            kw("Places/Portugal/Lisbon"): KeywordOptions(synonyms: ["Lisboa"]),
            kw("Places/Portugal"): KeywordOptions(synonyms: ["PT"], exportSynonyms: false),
            kw("Clients"): KeywordOptions(isPrivate: true),
            kw("People/Ana"): KeywordOptions(exportContainingKeywords: false, isPerson: true),
            kw("Draft"): KeywordOptions(includeOnExport: false),
        ])
        let list = KeywordList(counts: counts, definitions: definitions)
        let all = [kw("Places/Portugal/Lisbon"), kw("Clients/Acme/Invoices"), kw("People/Ana"), kw("Draft")]
        let exported = list.exported(all)
        #expect(exported.names == ["Lisbon", "Lisboa", "Portugal", "Ana"])
        #expect(exported.paths == [kw("Portugal/Lisbon"), kw("People/Ana")])
        #expect(list.exported(all, people: false).names == ["Lisbon", "Lisboa", "Portugal"])
    }
}
