import Foundation
import Testing
@testable import RedlampLibrary

/// Lightroom Classic's keyword-list text file, imported and exported without loss.
struct KeywordFileTests {
    /// A file as Lightroom writes one, with names that put the format to the test.
    static let file = [
        "[Animals]",
        "\tBirds",
        "\t\t{Aves}",
        "\t\tBlack-tailed Godwit",
        "\t\tGull",
        "\t\t\t{Larus}",
        "\t\t\t{Seagull}",
        "C:\\Photos\\Keep",
        "Music",
        "\tAC/DC",
        "\tFish, Chips & \"Peas\"",
        "\tGuns N' Roses",
        "[People]",
        "\t[[draft]]",
        "\t50% off",
        "\tAna (née Silva)",
        "\t\t{Ana Silva}",
        "\tJosé 🙂",
        "Places",
        "\t[{curly}]",
        "\tPortugal",
        "\t\tLisbon",
        "\t\t\t{Lisboa}",
        "\t\t\t{Lisbonne}",
        "\t\tPorto",
        "\tSpain",
        "\t\tMadrid {old}",
        "\tالقاهرة",
        "\t東京",
    ].map { $0 + "\n" }.joined()

    /// The same keywords as Redlamp writes them: each keyword's in the library's name order, Folders' own, which takes
    /// digits before brackets and braces after letters, where Lightroom puts them first.
    static let exported = [
        "[Animals]",
        "\tBirds",
        "\t\t{Aves}",
        "\t\tBlack-tailed Godwit",
        "\t\tGull",
        "\t\t\t{Larus}",
        "\t\t\t{Seagull}",
        "C:\\Photos\\Keep",
        "Music",
        "\tAC/DC",
        "\tFish, Chips & \"Peas\"",
        "\tGuns N' Roses",
        "[People]",
        "\t50% off",
        "\t[[draft]]",
        "\tAna (née Silva)",
        "\t\t{Ana Silva}",
        "\tJosé 🙂",
        "Places",
        "\tPortugal",
        "\t\tLisbon",
        "\t\t\t{Lisboa}",
        "\t\t\t{Lisbonne}",
        "\t\tPorto",
        "\tSpain",
        "\t\tMadrid {old}",
        "\t[{curly}]",
        "\tالقاهرة",
        "\t東京",
    ].map { $0 + "\n" }.joined()

    /// `keywords` by their paths, whatever their order.
    static func byPath(_ keywords: [LightroomKeywordFile.Keyword]) -> [String: LightroomKeywordFile.Keyword] {
        Dictionary(uniqueKeysWithValues: keywords.map { ($0.path.text, $0) })
    }

    @Test func `a keyword file reads back what it was written from, and writes the same file again`() throws {
        let keywords = LightroomKeywordFile.read(Self.file)
        let byPath = Dictionary(uniqueKeysWithValues: keywords.map { ($0.path, $0) })
        #expect(keywords.count == 23)
        #expect(byPath[kw("Animals")]?.includeOnExport == false)
        #expect(byPath[kw("Animals/Birds")]?.synonyms == ["Aves"])
        #expect(byPath[kw("Animals/Birds/Gull")]?.synonyms == ["Larus", "Seagull"])
        #expect(try byPath[#require(KeywordPath(names: ["Music", "AC/DC"]))] != nil)
        #expect(try byPath[#require(KeywordPath(names: ["Music", "Fish, Chips & \"Peas\""]))] != nil)
        #expect(try byPath[#require(KeywordPath(names: ["People", "[draft]"]))]?.includeOnExport == false)
        #expect(try byPath[#require(KeywordPath(names: ["People", "50% off"]))] != nil)
        #expect(try byPath[#require(KeywordPath(names: ["Places", "Spain", "Madrid {old}"]))]?.includeOnExport == true)
        #expect(try byPath[#require(KeywordPath(names: ["Places", "{curly}"]))]?.includeOnExport == false)
        #expect(try byPath[#require(KeywordPath(names: ["C:\\Photos\\Keep"]))] != nil)

        let export = LightroomKeywordFile.write(keywords)
        #expect(export.text == Self.exported)
        #expect(export.keywords == 23 && export.unrepresentable.isEmpty)
        #expect(try export.refusedByLightroom == [#require(KeywordPath(names: ["Music", "Fish, Chips & \"Peas\""]))])
        #expect(Self.byPath(LightroomKeywordFile.read(export.text)) == Self.byPath(keywords))
        #expect(LightroomKeywordFile.write(LightroomKeywordFile.read(export.text)).text == Self.exported)
    }

    @Test func `files from other systems and editors read the same`() throws {
        let crlf = Self.file.replacingOccurrences(of: "\n", with: "\r\n")
        let expected = LightroomKeywordFile.read(Self.file)
        #expect(LightroomKeywordFile.read(crlf) == expected)
        #expect(try LightroomKeywordFile.read(Data([0xEF, 0xBB, 0xBF]) + Data(Self.file.utf8)) == expected)
        #expect(try LightroomKeywordFile.read(#require(Self.file.data(using: .utf16))) == expected)
        let latin = try #require("Café\n\tCrème\n".data(using: .windowsCP1252))
        #expect(try LightroomKeywordFile.read(latin).map(\.path.text) == ["Café", "Café/Crème"])
        #expect(throws: KeywordError.unreadableFile) { try LightroomKeywordFile.read(Data([
            0x41,
            0x00,
            0xFF,
            0xFE,
            0x80,
        ])) }

        // Lines deeper than the one above by more than a tab, blank lines, a stray synonym and
        // spaces at a name's ends.
        let untidy = "{orphan}\nPlaces  \n\n\t\t\tLisbon\n\t\t\t\t{Lisboa}\n  \nPlaces\n\tPorto\n"
        let read = LightroomKeywordFile.read(untidy)
        #expect(read.map(\.path.text) == ["Places", "Places/Lisbon", "Places/Porto"])
        #expect(read[1].synonyms == ["Lisboa"])
    }

    @Test func `names the format would read as something else are listed, and the rest wrapped to read back`() throws {
        let keywords = try [
            LightroomKeywordFile.Keyword(path: #require(KeywordPath(names: ["{shown}"]))),
            LightroomKeywordFile.Keyword(path: #require(KeywordPath(names: ["[shown]"]))),
            LightroomKeywordFile.Keyword(path: #require(KeywordPath(names: ["[hidden]"])), includeOnExport: false),
            LightroomKeywordFile.Keyword(path: #require(KeywordPath(names: ["Ends*"])), synonyms: ["{s}"]),
        ]
        let export = LightroomKeywordFile.write(keywords)
        #expect(export.text == "[[hidden]]\n[shown]\nEnds*\n\t{{s}}\n{shown}\n")
        #expect(try export.unrepresentable == [
            #require(KeywordPath(names: ["[shown]"])),
            #require(KeywordPath(names: ["{shown}"])),
        ])
        #expect(try export.refusedByLightroom == [#require(KeywordPath(names: ["Ends*"]))])
        let read = LightroomKeywordFile.read(export.text)
        #expect(read.contains(keywords[2]) && read.contains(keywords[3]))
    }

    @Test func `importing a file keeps its keywords in the list in one step, and exporting gives it back`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("A.JPG", keywords: ["Places/Portugal/Lisbon"])
        try await sandbox.indexAll()
        let keywords = sandbox.keywords()
        let outcome = try await keywords.importLightroomFile(Data(Self.file.utf8))
        #expect(outcome.state == .finished && outcome.title == "Import 23 keywords")
        let list = try await keywords.list()
        #expect(list[kw("Places/Portugal/Lisbon")]?.count == 1)
        #expect(list[kw("Places/Portugal/Lisbon")]?.options.synonyms == ["Lisboa", "Lisbonne"])
        #expect(list[kw("Animals")]?.options.includeOnExport == false)
        #expect(try await keywords.exportLightroomFile().text == Self.exported)
        #expect(try await sandbox.search("kw:Lisbonne") == ["A.JPG"])

        try await keywords.undo()
        #expect(try await keywords.list().keywords.keys.sorted() == [
            kw("Places"), kw("Places/Portugal"), kw("Places/Portugal/Lisbon"),
        ])
    }
}
