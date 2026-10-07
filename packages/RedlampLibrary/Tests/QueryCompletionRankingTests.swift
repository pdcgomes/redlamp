import Foundation
import Testing
@testable import RedlampLibrary

/// Completion ranked (LIB-18), as the palette ranks the library's names too (LIB-19): by where the
/// text matches, then by its letters in order within a floor of the best match, then by a word a
/// typo away, folded as the language folds text.
struct QueryCompletionRankingTests {
    /// The values `NameRanking` ranks first for `text` among `names`, over their fields in the order
    /// they first come.
    private func ranked(_ text: String, _ names: [RankedName], fields: [LibraryQuery.Field]? = nil) -> [String] {
        matches(text, names, fields: fields).map(\.value)
    }

    private func matches(_ text: String, _ names: [RankedName], fields: [LibraryQuery.Field]? = nil) -> [RankedMatch] {
        var order: [LibraryQuery.Field] = []
        for name in names where !order.contains(name.field) {
            order.append(name.field)
        }
        return NameRanking.rank(text, in: [NameTable(names)], fields: fields ?? order, limit: 8)
    }

    private func keywords(_ paths: String...) -> [RankedName] {
        paths.map { RankedName.levels(.keyword, path: $0) }
    }

    // MARK: - Where the text matches

    @Test func `a name the text starts comes first, then one a word of which it starts, then one it's inside`() {
        let names = keywords("Snowed In", "Our Wedding", "Wedding", "Wild Edge")
        let found = matches("wed", names)
        #expect(found.map(\.value) == ["Wedding", "Our Wedding", "Snowed In", "Wild Edge"])
        #expect(found.map(\.match) == [.start, .word, .inside, .inOrder])
    }

    @Test func `a keyword's own name and a folder's name start it, as its whole text does`() {
        let names = keywords("Places/Lisbon Area/Belém", "Places/Portugal/Lisbon")
            + [.folder("/Volumes/Photos/2024/Lisbon Trip")]
        let found = matches("lis", names)
        #expect(found.map(\.value) == [
            "Places/Portugal/Lisbon", "/Volumes/Photos/2024/Lisbon Trip", "Places/Lisbon Area/Belém",
        ])
        #expect(found.map(\.match) == [.start, .start, .word])
        #expect(ranked("places/port", names) == ["Places/Portugal/Lisbon"], "its levels from the top")
    }

    @Test func `ties go to the shorter name, then the field asked for first`() {
        let names = [
            RankedName(.camera, "Lisbon"), RankedName(.city, "Lisbon"), RankedName(.city, "Lisbon Coast"),
        ]
        #expect(ranked("lis", names, fields: [.city, .camera]) == ["Lisbon", "Lisbon", "Lisbon Coast"])
        #expect(matches("lis", names, fields: [.city, .camera]).map(\.field) == [.city, .camera, .city])
        #expect(matches("lis", names, fields: [.camera, .city]).map(\.field) == [.camera, .city, .city])
        #expect(ranked("lis", names, fields: [.camera]) == ["Lisbon"], "only the fields asked for")
    }

    @Test func `a word starts after a space, a slash or a hyphen, and where letters and digits meet`() {
        let names = [RankedName(.lens, "XF16-55mmF2.8"), RankedName(.lens, "RF24-70mm"), RankedName(.lens, "Summilux")]
        #expect(matches("55", names).map(\.match) == [.word])
        let millimetres = matches("mm", names)
        #expect(millimetres.map(\.value) == ["RF24-70mm", "XF16-55mmF2.8", "Summilux"])
        #expect(millimetres.map(\.match) == [.word, .word, .inside])
        #expect(matches("mil", names).map(\.match) == [.inside])
    }

    @Test func `a keyword's synonym finds it, once, however many of its names match`() {
        let names = [RankedName.levels(.keyword, path: "Places/Lisbon", others: ["Lisboa", "Olisipo"])]
        #expect(ranked("lisb", names) == ["Places/Lisbon"])
        #expect(ranked("olisi", names) == ["Places/Lisbon"])
    }

    // MARK: - Folding

    @Test func `case, accents and width are folded as the language folds them`() {
        let names = [
            RankedName(.city, "São Paulo"), RankedName(.city, "Zürich"), RankedName(.camera, "ＳＯＮＹ Ａ７"),
            RankedName(.city, "LISBOA"),
        ]
        #expect(ranked("sao", names) == ["São Paulo"])
        #expect(ranked("ZURICH", names) == ["Zürich"])
        #expect(ranked("sony", names) == ["ＳＯＮＹ Ａ７"])
        #expect(ranked("ｓａｏ ｐ", names) == ["São Paulo"], "full-width text as typed")
        #expect(ranked("lisboa", names) == ["LISBOA"])
    }

    @Test func `a match never starts or ends inside a character`() {
        let names = [RankedName(.city, "Straße"), RankedName(.keyword, "ガイド")]
        #expect(ranked("strasse", names) == ["Straße"])
        #expect(ranked("stras", names).isEmpty, "an s isn't found inside the ss of a ß")
        #expect(ranked("ガイ", names) == ["ガイド"])
        #expect(ranked("カ", names).isEmpty, "カ isn't found in ガ, written カ and a mark")
    }

    // MARK: - Letters in order and the floor

    @Test func `letters in order find a name, the best placed first`() {
        let names = [
            RankedName(.camera, "NIKON Z 8"), RankedName(.lens, "XF35mm T5"), RankedName(.camera, "X-T5"),
        ]
        let found = matches("xt5", names)
        #expect(found.map(\.value) == ["X-T5", "XF35mm T5"])
        #expect(found.allSatisfy { $0.match == .inOrder })
        #expect(ranked("nz8", names) == ["NIKON Z 8"])
    }

    @Test func `the quality floor leaves out letters scattered across a name`() {
        let names = keywords("Wedding", "Wild Edge", "Wind over the Lake and Dunes")
        #expect(ranked("wed", names) == ["Wedding", "Wild Edge"])
        let lenses = [RankedName(.camera, "NIKON Z 8"), RankedName(.lens, "NIKKOR Z 24-70mm f/2.8 S")]
        #expect(ranked("nz8", lenses) == ["NIKON Z 8"], "the lens's 8 is its aperture's")
        #expect(
            ranked("wnd", keywords("Waterfront and Docks", "Wind Farm")) == ["Wind Farm"],
            "letters in order set the floor when nothing holds the text",
        )
    }

    @Test func `landscpae finds Landscapes ahead of names that only share its letters`() {
        let names = keywords(
            "Lisbon and Douro/Scenic Places", "Subjects/landscape/black and white", "Landscapes", "Lands",
        )
        let found = matches("landscpae", names)
        #expect(found.map(\.value) == ["Landscapes", "Subjects/landscape/black and white"])
        #expect(found.map(\.match) == [.typo, .typo] && found.map(\.typos) == [1, 1])
        #expect(found.first?.twin == "landscape", "scored as landscape, its correctly spelt twin")
    }

    // MARK: - Typos

    @Test func `a word one typo away is found after every name that holds the text as typed`() {
        let names = [RankedName(.city, "Lisbon"), RankedName(.keyword, "Lisbomb Records"), RankedName(.city, "Lisboa")]
        let found = matches("lisbom", names)
        #expect(found.map(\.value) == ["Lisbomb Records", "Lisboa", "Lisbon"])
        #expect(found.map(\.match) == [.start, .typo, .typo])
        #expect(ranked("portgual", [RankedName(.country, "Portugal")]) == ["Portugal"], "a swapped letter")
        #expect(ranked("fujiflim", [RankedName(.camera, "FUJIFILM GFX100S")]) == ["FUJIFILM GFX100S"])
        #expect(ranked("rime", [RankedName(.city, "Rome")]) == ["Rome"], "a wrong letter")
        #expect(ranked("nikkon", [RankedName(.camera, "NIKON Z 8")]) == ["NIKON Z 8"], "an extra letter")
        #expect(ranked("wedidng", keywords("Weddings")) == ["Weddings"], "a plural's s aside")
    }

    @Test func `a word's first letter is never the typo`() {
        let names = [RankedName(.city, "Lisbon"), RankedName(.city, "Rome")]
        #expect(ranked("kisbon", names).isEmpty)
        #expect(ranked("ilsbon", names).isEmpty, "nor swapped with the second")
        #expect(ranked("xlisbon", names).isEmpty, "nor one put before it")
        #expect(ranked("lisbin", names) == ["Lisbon"])
    }

    @Test func `text under four letters, or with more than letters, has no typos`() {
        let names = [RankedName(.city, "Rome"), RankedName(.city, "Lisbon")]
        #expect(ranked("rim", names).isEmpty)
        #expect(ranked("rime", names) == ["Rome"])
        #expect(ranked("lisb0n", names).isEmpty, "a digit")
        #expect(ranked("lis-bom", names).isEmpty, "a hyphen")
    }

    @Test func `two typos are allowed only from eight letters`() {
        let names = [RankedName(.country, "Portugal")]
        let two = matches("protugla", names)
        #expect(two.map(\.value) == ["Portugal"] && two.first?.typos == 2)
        #expect(ranked("potrgal", names).isEmpty, "seven letters, two typos")
        #expect(matches("potrugal", names).first?.typos == 1)
    }

    // MARK: - Over the index

    @Test func `the engine completes the index's names and the photos' places alike`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let montreal = await engine.completions("montreal", field: nil)
        #expect(montreal.map(\.term).first == "city:Montréal")
        #expect(montreal.map(\.field) == [.city, .folder], "the city, then the folder a word of which it starts")
        let typo = await engine.completions("lisbom", field: nil)
        #expect(typo.map(\.field) == [.city, .state, .keyword, .folder] && typo.allSatisfy { $0.typos == 1 })
        #expect(typo.first?.value == "Lisboa" && typo.last?.value.hasSuffix("/2024/Lisbon Trip") == true)
        #expect(await engine.completions("alfa", field: .sublocation).map(\.term) == ["sublocation:Alfama"])
        let names = await engine.completions("port", fields: [.country, .collection, .city])
        #expect(names.map(\.term) == [
            "city:Porto",
            "country:Portugal",
            "collection:Portfolio",
            "collection:Portfolio/2024",
        ])
    }
}
