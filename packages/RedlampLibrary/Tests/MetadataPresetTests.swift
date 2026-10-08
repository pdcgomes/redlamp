import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Metadata presets (LIB-22), as Photo Mechanic's templates: the ticked fields alone, each replacing,
/// appending to or prefixing what a photo shows; code replacements expanded in their texts; and the
/// presets kept in the library's definitions.
struct MetadataPresetTests {
    static let codes = CodeReplacements(text: """
    lx\tLisbon\tLisboa
    ana\tAna Sousa
    WED\tthe wedding of Ana and Rui

    no tab here
    """)

    @Test func `codes expand where they're known, by column, and are left as written where they aren't`() {
        let codes = Self.codes
        #expect(codes.expanded(#"Trams in \lx\ (\lx#2\)"#) == "Trams in Lisbon (Lisboa)")
        #expect(codes.expanded(#"© \ANA\, \wed\"#) == "© Ana Sousa, the wedding of Ana and Rui")
        #expect(codes.expanded(#"\nope\ \lx#3\ C:\Photos \lx"#) == #"\nope\ \lx#3\ C:\Photos \lx"#)
        #expect(codes.codes.count == 3)
        #expect(CodeReplacements().expanded(#"\lx\"#) == #"\lx\"#)
    }

    @Test func `a preset replaces, appends and prefixes the fields it ticks, and leaves the rest`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        // One photo's caption is its own, one's another app's, one has none.
        for photo in ["A.NEF", "B.NEF", "C.NEF"] {
            try sandbox.photo(photo)
        }
        try sandbox.sidecar(
            "A.NEF",
            PhotoMetadata(caption: "Trams", creator: "Rui Lopes", location: PhotoLocation(country: "Portugal")),
        )
        try sandbox.write("B.xmp", MetadataIndexTests.otherApp, modified: -600)
        try await sandbox.indexAll()
        let preset = MetadataPreset(name: "Lisbon trip", fields: [
            .caption: .init(#"in \lx\"#, mode: .append),
            .title: .init("Day one:", mode: .prefix),
            .creator: .init(#"\ana\"#, mode: .append),
            .city: .init(#"\lx\"#),
            .copyright: .init(""),
        ])
        let metadata = LibraryMetadata(index: sandbox.index)
        let ids = try await [sandbox.id("A.NEF"), sandbox.id("B.NEF"), sandbox.id("C.NEF")]
        let outcome = try await metadata.apply(.preset(preset, to: ids, codes: Self.codes))
        #expect(outcome.title == "Apply “Lisbon trip” to 3 photos" && outcome.written == 3)

        let a = try #require(sandbox.metadata("A.NEF"))
        #expect(a.caption == "Trams in Lisbon" && a.title == "Day one:" && a.creator == "Rui Lopes; Ana Sousa")
        #expect(a.location == PhotoLocation(country: "Portugal", city: "Lisbon") && a.copyright == "")
        // Another app's fields are what's added to, and the location it doesn't tick stays whole.
        let b = try #require(sandbox.metadata("B.NEF"))
        #expect(b.caption == "Boats on the Douro. in Lisbon" && b.title == "Day one: Ribeira")
        #expect(b.creator == "Ana Sousa; Rui Lopes; Ana Sousa")
        #expect(b.location == PhotoLocation(
            country: "Portugal", state: "Porto", city: "Lisbon", sublocation: "Ribeira", countryCode: "PT",
        ))
        let c = try #require(sandbox.metadata("C.NEF"))
        #expect(c.caption == "in Lisbon" && c.title == "Day one:" && c.creator == "Ana Sousa")
        #expect(c.location == PhotoLocation(city: "Lisbon") && c.rating == 0)
        let row = try await sandbox.row("B.NEF")
        #expect(row.caption == "Boats on the Douro. in Lisbon" && row.copyright == nil && row.rating == 3)

        try await metadata.undo()
        #expect(sandbox.metadata("A.NEF") == PhotoMetadata(
            caption: "Trams", creator: "Rui Lopes", location: PhotoLocation(country: "Portugal"),
        ))
        #expect(sandbox.metadata("B.NEF") == nil && sandbox.metadata("C.NEF") == nil)
        #expect(try await sandbox.row("B.NEF").caption == "Boats on the Douro.")
    }

    @Test func `presets are kept in the definitions, with what a newer Redlamp wrote`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let preset = MetadataPreset(name: "Wedding", fields: [
            .caption: .init(#"\wed\"#, mode: .prefix), .city: .init("Sintra"),
        ])
        try await metadata.save(preset)
        try await metadata.save(MetadataPreset(name: "Studio", fields: [.creator: .init("Ana Sousa")]))
        #expect(try await metadata.presets().presets.map(\.name) == ["Wedding", "Studio"])
        #expect(try await metadata.presets()["Wedding"] == preset)

        let url = metadata.presetsURL
        var json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case var .object(object) = json, case var .array(presets) = object["presets"],
              case var .object(first) = presets[0], case var .object(fields) = first["fields"]
        else {
            Issue.record("the presets file isn't as written")
            return
        }
        #expect(fields["caption"] == .object(["text": .string(#"\wed\"#), "mode": .string("prefix")]))
        #expect(fields["city"] == .object(["text": .string("Sintra")]))
        fields["keywords"] = .object(["text": .string("Wedding")])
        first["fields"] = .object(fields)
        first["shortcut"] = .string("⌥1")
        presets[0] = .object(first)
        object["presets"] = .array(presets)
        object["folders"] = .array([])
        json = .object(object)
        try JSONEncoder().encode(json).write(to: url)

        try await metadata.save(MetadataPreset(name: "Studio", fields: [.creator: .init("Rui Lopes")]))
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue
        #expect(saved?["folders"] == .array([]))
        let wedding = (saved?["presets"]).flatMap { value -> [String: JSONValue]? in
            guard case let .array(values) = value else { return nil }
            return values.first?.objectValue
        }
        #expect(wedding?["shortcut"] == JSONValue.string("⌥1"))
        #expect(wedding?["fields"]?.objectValue?["keywords"] == JSONValue.object(["text": .string("Wedding")]))
        #expect(try await metadata.presets()["Studio"]?.fields[.creator]?.text == "Rui Lopes")
    }

    @Test func `the library's code replacements are kept as they're written, and expanded`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        #expect(try await metadata.codeReplacementsText() == "" && metadata.codesURL.lastPathComponent
            == "Code Replacements.txt")
        let text = "# Lisbon, 2026\r\nlx\tLisbon\tLisboa\r\n\r\nana\tAna Sousa\r\nlx\tLeixões\r\n\tno code\r\n"
        try await metadata.saveCodeReplacements(text)
        #expect(try Data(contentsOf: metadata.codesURL) == Data(text.utf8), "kept byte for byte")
        #expect(try await metadata.codeReplacementsText() == text)
        let codes = try await metadata.codeReplacements()
        #expect(codes.expanded(#"\ana\ in \lx\ (\lx#2\)"#) == "Ana Sousa in Lisbon (Lisboa)")
        #expect(CodeReplacements.ignoredLines(in: text) == [1, 5, 6], "no tab, a code an earlier line has, no code")

        let macRoman = try #require("café\tCafé Nicola\n".data(using: .macOSRoman))
        try macRoman.write(to: metadata.codesURL)
        #expect(try await metadata.codeReplacements().expanded(#"\café\"#) == "Café Nicola", "as older files are")
        try await metadata.saveCodeReplacements(" \n")
        #expect(!FileManager.default.fileExists(atPath: metadata.codesURL.path), "no codes, no file")
    }
}
