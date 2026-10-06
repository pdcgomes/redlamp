import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// A photo's keywords in its sidecar, as full paths, and how a slash inside a keyword is written.
struct KeywordSidecarTests {
    @Test func `a sidecar's keywords are written as full paths and read back as they were written`() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "IMG_0001.ARW")
        let store = SidecarStore()
        let keywords = ["Places/Portugal/Lisbon", "Music/AC%2FDC", "Sale/50%25 off", "tram"]
        try store.save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: keywords)), for: image)

        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(root) = written, case let .object(metadata)? = root["metadata"] else {
            Issue.record("no metadata in \(written)")
            return
        }
        #expect(metadata["keywords"] == .array(keywords.map(JSONValue.string)))
        #expect(store.load(for: image)?.metadata?.keywords == keywords)
        #expect(store.protection(for: image) == nil)

        // An empty list is no keywords, and keeps the sidecar; no list leaves them to the photo.
        try store.saveOrRemove(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: [])), for: image)
        #expect(store.load(for: image)?.metadata?.keywords == [])
        #expect(store.protection(for: image) == nil)
        try store.saveOrRemove(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata()), for: image)
        #expect(store.load(for: image) == nil)
    }

    @Test func `a sidecar's keywords are kept as written, odd ones too, so the sidecar stays editable`() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "IMG_0002.ARW")
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"#
            + #""metadata":{"rating":2,"keywords":["Places//Lisbon ","Cafe\u0301","Places//Lisbon "]}}"#
        try Data(json.utf8).write(to: store.url(for: image))
        #expect(store.protection(for: image) == nil)
        var sidecar = try #require(store.load(for: image))
        #expect(sidecar.metadata?.keywords == ["Places//Lisbon ", "Cafe\u{301}", "Places//Lisbon "])
        sidecar.metadata?.rating = 3
        try store.save(sidecar, for: image)
        #expect(store.load(for: image)?.metadata?.keywords == ["Places//Lisbon ", "Cafe\u{301}", "Places//Lisbon "])
        // As paths, they're tidied: no empty levels or spaces at the ends, composed, each once.
        #expect(KeywordPath.texts(sidecar.metadata?.keywords ?? []) == ["Places/Lisbon", "Café"])
    }

    /// The previous build's `PhotoMetadata` decoding: the keys it knows, and everything else kept as a
    /// field it doesn't know, written back unchanged.
    private struct PreviousMetadata: Codable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case rating, flag, label, originalName
        }

        var rating: Int
        var flag: String?
        var label: String?
        var originalName: String?
        var unknownFields: [String: JSONValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rating = try container.decode(Int.self, forKey: .rating)
            flag = try container.decodeIfPresent(String.self, forKey: .flag)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
            unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
                .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
        }

        func encode(to encoder: Encoder) throws {
            var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
            try unknown.encode(unknownFields)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rating, forKey: .rating)
            try container.encodeIfPresent(flag, forKey: .flag)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(originalName, forKey: .originalName)
        }
    }

    @Test func `builds from before keywords keep them as a field they don't know`() throws {
        let metadata = PhotoMetadata(rating: 4, flag: .pick, keywords: ["Places/Portugal/Lisbon", "Music/AC%2FDC"])
        let written = try JSONEncoder().encode(metadata)
        var previous = try JSONDecoder().decode(PreviousMetadata.self, from: written)
        #expect(previous.unknownFields["keywords"] == .array([
            .string("Places/Portugal/Lisbon"),
            .string("Music/AC%2FDC"),
        ]))
        previous.rating = 2
        let rewritten = try JSONEncoder().encode(previous)
        let read = try JSONDecoder().decode(PhotoMetadata.self, from: rewritten)
        #expect(read.keywords == metadata.keywords && read.rating == 2 && read.flag == .pick)
        #expect(read.unknownFields.isEmpty)
    }

    @Test func `a slash inside a keyword is written %2F and a percent sign %25, and nothing else changes`() throws {
        let cases: [([String], String)] = [
            (["Places", "Portugal", "Lisbon"], "Places/Portugal/Lisbon"),
            (["Music", "AC/DC"], "Music/AC%2FDC"),
            (["Sale", "50% off"], "Sale/50%25 off"),
            (["%2F"], "%252F"),
            (["/"], "%2F"),
            (["a/b%c", "d"], "a%2Fb%25c/d"),
            (["東京", "Café 🙂", "Fish, Chips & \"Peas\""], "東京/Café 🙂/Fish, Chips & \"Peas\""),
        ]
        for (names, text) in cases {
            let path = try #require(KeywordPath(names: names))
            #expect(path.text == text, "\(names)")
            #expect(KeywordPath(text) == path && KeywordPath(text)?.names == names, "\(text)")
        }
        // A percent sign that starts no escape reads as itself, and escapes read in either case.
        #expect(KeywordPath("100%/a%2fb%41")?.names == ["100%", "a/b%41"])
        // Names are tidied: spaces at the ends and empty levels go, control characters become spaces.
        #expect(KeywordPath("  Places // Portugal\t/ Lisbon ")?.names == ["Places", "Portugal", "Lisbon"])
        #expect(KeywordPath(names: ["Line\nbreak", " "])?.names == ["Line break"])
        #expect(KeywordPath("Cafe\u{301}")?.text == "Café")
        #expect(KeywordPath("//") == nil && KeywordPath(names: ["  "]) == nil)
    }

    @Test func `paths know their parents, depth and what they're inside`() {
        let lisbon = kw("Places/Portugal/Lisbon")
        #expect(lisbon.name == "Lisbon" && lisbon.depth == 2 && lisbon.parent == kw("Places/Portugal"))
        #expect(lisbon.ancestors == [kw("Places"), kw("Places/Portugal")])
        #expect(lisbon.isWithin(kw("Places")) && lisbon.isWithin(lisbon) && !kw("Places").isWithin(lisbon))
        #expect(!kw("Places/Portugalia").isWithin(kw("Places/Portugal")))
        #expect(lisbon.replacingPrefix(kw("Places/Portugal"), with: kw("Cities")) == kw("Cities/Lisbon"))
        #expect(kw("Music").appending("AC/DC")?.text == "Music/AC%2FDC")
        #expect([kw("B"), kw("A/B"), kw("A")].sorted() == [kw("A"), kw("A/B"), kw("B")])
    }
}
